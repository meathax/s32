from __future__ import annotations

import json
import os
import shutil
import tempfile
from collections import defaultdict, deque
from contextlib import ExitStack
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence

from .observability import ObservabilityError, canonicalize_event
from .util import atomic_write_json, atomic_write_text, sha256_file, stable_hash, utc_now


class TraceError(ValueError):
    pass


COMPARE_BASE_FIELDS = (
    "event",
    "phase",
    "rw",
    "address_bytes",
    "data",
    "width_bits",
    "byte_enable",
)
CANONICAL_SCHEMA = "mister-canonical-event-v4"


def _require_int(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise TraceError(f"{field} must be an integer >= {minimum}.")
    return value


def _validate_canonical_event(event: dict[str, Any], *, location: str) -> None:
    """Fail closed on hand-written, truncated or schema-invalid canonical rows."""

    if event.get("schema") != CANONICAL_SCHEMA:
        raise TraceError(f"{location}: not a canonical v4 event.")
    domain = event.get("domain")
    if not isinstance(domain, str) or not domain.strip():
        raise TraceError(f"{location}: domain must be a non-empty string.")
    _require_int(event.get("seq"), f"{location}: seq")
    kind = event.get("event")
    phase = event.get("phase")
    if not isinstance(kind, str) or not kind:
        raise TraceError(f"{location}: event must be a non-empty string.")
    if not isinstance(phase, str) or not phase:
        raise TraceError(f"{location}: phase must be a non-empty string.")
    rw = event.get("rw")
    if rw not in {"R", "W"}:
        raise TraceError(f"{location}: rw must be 'R' or 'W'.")
    _require_int(event.get("address_bytes"), f"{location}: address_bytes")
    data = _require_int(event.get("data"), f"{location}: data")
    width = _require_int(event.get("width_bits"), f"{location}: width_bits", minimum=8)
    if width % 8:
        raise TraceError(f"{location}: width_bits must be a positive multiple of 8.")
    if data >= (1 << width):
        raise TraceError(f"{location}: data does not fit width_bits={width}.")
    byte_enable = _require_int(event.get("byte_enable"), f"{location}: byte_enable", minimum=1)
    lane_mask = (1 << (width // 8)) - 1
    if byte_enable & ~lane_mask:
        raise TraceError(f"{location}: byte_enable selects lanes outside width_bits={width}.")
    if "canonical_time" in event:
        _require_int(event.get("canonical_time"), f"{location}: canonical_time")


def iter_jsonl(path: Path, *, max_bytes: int | None = None) -> Iterator[tuple[int, dict[str, Any]]]:
    if not path.exists():
        raise TraceError(f"Trace file does not exist: {path}")
    if not path.is_file():
        raise TraceError(f"Trace path is not a file: {path}")
    size = path.stat().st_size
    if max_bytes is not None and size > max_bytes:
        raise TraceError(f"Trace file is {size} bytes; configured maximum is {max_bytes}: {path}")
    with path.open("r", encoding="utf-8-sig") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                raise TraceError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(item, dict):
                raise TraceError(f"{path}:{line_number}: event must be a JSON object.")
            yield line_number, item


def write_jsonl(path: Path, events: Iterable[dict[str, Any]]) -> None:
    """Atomically stream JSONL without constructing the whole trace in memory."""

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            for event in events:
                handle.write(json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def _meta_path(path: Path) -> Path:
    return path.with_name(path.name + ".meta.json")


def _write_normalized_metadata(
    output_path: Path,
    *,
    raw_path: Path,
    side: str,
    counts: dict[str, int],
    contract: dict[str, Any],
) -> dict[str, Any]:
    metadata = {
        "schema": "mister-normalized-trace-metadata-v4",
        "created_utc": utc_now(),
        "complete": True,
        "side": side,
        "input": str(raw_path),
        "input_size": raw_path.stat().st_size,
        "input_sha256": sha256_file(raw_path),
        "output": str(output_path),
        "output_size": output_path.stat().st_size,
        "output_sha256": sha256_file(output_path),
        "event_count": sum(counts.values()),
        "domains": dict(sorted(counts.items())),
        "observability_sha256": stable_hash(contract),
    }
    atomic_write_json(_meta_path(output_path), metadata)
    return metadata


def normalize_trace(
    raw_path: Path,
    output_path: Path,
    *,
    side: str,
    contract: dict[str, Any],
    selected_domains: Iterable[str] | None = None,
    max_bytes: int | None = None,
    write_sidecar: bool = True,
) -> dict[str, Any]:
    """Strictly canonicalize a raw trace with bounded memory.

    Raw domains may be interleaved. Events are spooled per domain and the final canonical
    file is grouped by domain so comparison can stream one domain at a time.
    """

    selected_list = list(selected_domains) if selected_domains is not None else None
    if selected_list is not None and len(set(selected_list)) != len(selected_list):
        raise TraceError("selected_domains contains duplicates.")
    selected = set(selected_list) if selected_list is not None else None
    expected_seq: dict[str, int] = defaultdict(int)
    counts: dict[str, int] = defaultdict(int)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".mister-normalize-", dir=str(output_path.parent)) as td:
        spool_root = Path(td)
        paths: dict[str, Path] = {}
        with ExitStack() as stack:
            handles: dict[str, Any] = {}
            for line_number, raw in iter_jsonl(raw_path, max_bytes=max_bytes):
                domain = raw.get("domain")
                if selected is not None and domain not in selected:
                    continue
                try:
                    event = canonicalize_event(raw, side=side, contract=contract)
                except ObservabilityError as exc:
                    raise TraceError(f"{raw_path}:{line_number}: {exc}") from exc
                name = event["domain"]
                expected = expected_seq[name]
                if event["seq"] != expected:
                    raise TraceError(
                        f"{raw_path}:{line_number}: domain {name!r} seq is {event['seq']}; expected {expected}. "
                        "Missing, duplicated, filtered or reordered events are fatal."
                    )
                expected_seq[name] = expected + 1
                counts[name] += 1
                if name not in handles:
                    part = spool_root / f"{len(handles):04d}.jsonl"
                    paths[name] = part
                    handles[name] = stack.enter_context(part.open("w", encoding="utf-8", newline="\n"))
                handles[name].write(json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")

        if not counts:
            raise TraceError(f"No selected events were found in {raw_path}.")
        if selected_list is not None:
            missing = [domain for domain in selected_list if counts.get(domain, 0) == 0]
            if missing:
                raise TraceError(f"Selected trace domains emitted no events: {', '.join(missing)}")
            order = selected_list
        else:
            order = sorted(paths)

        fd, tmp_name = tempfile.mkstemp(prefix=f".{output_path.name}.", suffix=".tmp", dir=str(output_path.parent))
        try:
            with os.fdopen(fd, "wb") as out:
                for domain in order:
                    with paths[domain].open("rb") as part:
                        shutil.copyfileobj(part, out, length=1024 * 1024)
                out.flush()
                os.fsync(out.fileno())
            os.replace(tmp_name, output_path)
        finally:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass

    metadata = None
    if write_sidecar:
        metadata = _write_normalized_metadata(
            output_path, raw_path=raw_path, side=side, counts=dict(counts), contract=contract
        )
    return {
        "schema": "mister-normalize-report-v4",
        "created_utc": utc_now(),
        "side": side,
        "input": str(raw_path),
        "output": str(output_path),
        "output_sha256": sha256_file(output_path),
        "event_count": sum(counts.values()),
        "domains": dict(sorted(counts.items())),
        "metadata": str(_meta_path(output_path)) if metadata is not None else None,
    }


def _validate_sidecar(path: Path) -> dict[str, Any] | None:
    meta_path = _meta_path(path)
    if not meta_path.exists():
        return None
    try:
        metadata = json.loads(meta_path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise TraceError(f"Cannot read normalized trace metadata {meta_path}: {exc}") from exc
    if not isinstance(metadata, dict) or metadata.get("schema") != "mister-normalized-trace-metadata-v4":
        raise TraceError(f"Invalid normalized trace metadata: {meta_path}")
    if metadata.get("complete") is not True:
        raise TraceError(f"Normalized trace is marked incomplete: {meta_path}")
    actual_size = path.stat().st_size
    actual_hash = sha256_file(path)
    if metadata.get("output_size") != actual_size or metadata.get("output_sha256") != actual_hash:
        raise TraceError(f"Normalized trace changed after completion or is truncated: {path}")
    return metadata


def _scan_normalized(path: Path) -> tuple[list[str], dict[str, dict[str, int]], dict[str, Any] | None]:
    if not path.exists() or not path.is_file():
        raise TraceError(f"Normalized trace does not exist: {path}")
    metadata = _validate_sidecar(path)
    order: list[str] = []
    index: dict[str, dict[str, int]] = {}
    current_domain: str | None = None
    closed: set[str] = set()
    expected = 0
    last_canonical_time: int | None = None
    domain_uses_time: bool | None = None
    total_events = 0
    with path.open("rb") as handle:
        line_number = 0
        while True:
            start = handle.tell()
            raw = handle.readline()
            if not raw:
                break
            line_number += 1
            if not raw.strip():
                continue
            try:
                event = json.loads(raw.decode("utf-8-sig" if line_number == 1 else "utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise TraceError(f"{path}:{line_number}: invalid canonical JSON: {exc}") from exc
            if not isinstance(event, dict):
                raise TraceError(f"{path}:{line_number}: canonical event must be an object.")
            _validate_canonical_event(event, location=f"{path}:{line_number}")
            domain = event["domain"]
            seq = event["seq"]
            if domain != current_domain:
                if current_domain is not None:
                    index[current_domain]["end"] = start
                    closed.add(current_domain)
                if domain in closed:
                    raise TraceError(
                        f"{path}:{line_number}: domain {domain!r} reappeared after another domain. "
                        "Canonical traces must be grouped by domain."
                    )
                current_domain = domain
                order.append(domain)
                index[domain] = {"start": start, "end": 0, "count": 0}
                expected = 0
                last_canonical_time = None
                domain_uses_time = None
            if seq != expected:
                raise TraceError(f"{path}:{line_number}: domain {domain!r} seq {seq}; expected {expected}.")
            has_time = "canonical_time" in event
            if domain_uses_time is None:
                domain_uses_time = has_time
            elif domain_uses_time != has_time:
                raise TraceError(
                    f"{path}:{line_number}: canonical_time is present for only part of domain {domain!r}."
                )
            if has_time:
                current_time = event["canonical_time"]
                if last_canonical_time is not None and current_time < last_canonical_time:
                    raise TraceError(
                        f"{path}:{line_number}: canonical_time moved backward in domain {domain!r}: "
                        f"{current_time} < {last_canonical_time}."
                    )
                last_canonical_time = current_time
            expected += 1
            total_events += 1
            index[domain]["count"] += 1
        if current_domain is not None:
            index[current_domain]["end"] = handle.tell()
    if not order:
        raise TraceError(f"No events in normalized trace: {path}")
    if metadata is not None:
        expected_counts = metadata.get("domains")
        actual_counts = {domain: info["count"] for domain, info in sorted(index.items())}
        if expected_counts != actual_counts:
            raise TraceError(f"Normalized trace metadata counts do not match the file: {path}")
        if metadata.get("event_count") != total_events:
            raise TraceError(f"Normalized trace metadata event_count does not match the file: {path}")
    return order, index, metadata


def _iter_domain(path: Path, info: dict[str, int]) -> Iterator[dict[str, Any]]:
    with path.open("rb") as handle:
        handle.seek(info["start"])
        while handle.tell() < info["end"]:
            raw = handle.readline()
            if not raw:
                break
            if not raw.strip():
                continue
            event = json.loads(raw.decode("utf-8"))
            yield event


def load_normalized(path: Path) -> dict[str, list[dict[str, Any]]]:
    """Compatibility helper for small traces; main comparison is streaming."""

    order, index, _ = _scan_normalized(path)
    return {domain: list(_iter_domain(path, index[domain])) for domain in order}


def _fields_for_domain(contract: dict[str, Any] | None, domain: str) -> tuple[str, ...]:
    fields = list(COMPARE_BASE_FIELDS)
    if contract:
        entry = contract.get("domains", {}).get(domain, {})
        optional = entry.get("comparable_optional_fields", [])
        if isinstance(optional, list):
            fields.extend(optional)
        if entry.get("ordering") == "canonical_time":
            fields.insert(0, "canonical_time")
    return tuple(dict.fromkeys(fields))


def _events_equal(left: dict[str, Any], right: dict[str, Any], fields: Sequence[str]) -> tuple[bool, list[str]]:
    mismatches = [field for field in fields if left.get(field) != right.get(field)]
    return not mismatches, mismatches


def _read_ahead(iterator: Iterator[dict[str, Any]], count: int) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for _ in range(count):
        try:
            out.append(next(iterator))
        except StopIteration:
            break
    return out


def _diagnostic_resync(
    left_window: Sequence[dict[str, Any]],
    right_window: Sequence[dict[str, Any]],
    fields: Sequence[str],
    *,
    base_index: int,
) -> list[dict[str, int]]:
    candidates: list[dict[str, int]] = []
    for li, left in enumerate(left_window):
        for ri, right in enumerate(right_window):
            if li == 0 and ri == 0:
                continue
            equal, _ = _events_equal(left, right, fields)
            if equal:
                candidates.append({"left_index": base_index + li, "right_index": base_index + ri})
                if len(candidates) >= 8:
                    return candidates
    return candidates


def compare_normalized(
    left_path: Path,
    right_path: Path,
    *,
    domains: Iterable[str] | None = None,
    contract: dict[str, Any] | None = None,
    context_events: int = 8,
    resync_window: int = 0,
) -> dict[str, Any]:
    if context_events < 1:
        raise TraceError("context_events must be at least 1.")
    if resync_window < 0:
        raise TraceError("resync_window may not be negative.")
    left_order, left_index, left_meta = _scan_normalized(left_path)
    right_order, right_index, right_meta = _scan_normalized(right_path)

    if contract is not None:
        contract_hash = stable_hash(contract)
        for label, metadata in (("left", left_meta), ("right", right_meta)):
            if metadata is not None and metadata.get("observability_sha256") != contract_hash:
                raise TraceError(
                    f"The {label} normalized trace was produced with a different observability contract."
                )
    elif left_meta is not None and right_meta is not None:
        if left_meta.get("observability_sha256") != right_meta.get("observability_sha256"):
            raise TraceError("Normalized traces were produced with different observability contracts.")

    if domains is not None:
        selected = list(domains)
        if not selected:
            raise TraceError("domains may not be an empty selection.")
    else:
        selected = sorted(set(left_order) | set(right_order))
    if len(set(selected)) != len(selected):
        raise TraceError("domains contains duplicates.")
    if contract is not None:
        contract_domains = contract.get("domains", {})
        unknown = [domain for domain in selected if domain not in contract_domains]
        if unknown:
            raise TraceError(f"Selected domains are absent from the observability contract: {', '.join(unknown)}")
    if domains is not None:
        missing_left = [domain for domain in selected if domain not in left_index]
        missing_right = [domain for domain in selected if domain not in right_index]
        if missing_left or missing_right:
            details = []
            if missing_left:
                details.append("left missing " + ", ".join(missing_left))
            if missing_right:
                details.append("right missing " + ", ".join(missing_right))
            raise TraceError("Selected comparison domains are incomplete: " + "; ".join(details))

    report: dict[str, Any] = {
        "schema": "mister-diff-report-v4",
        "created_utc": utc_now(),
        "left": str(left_path),
        "right": str(right_path),
        "left_sha256": sha256_file(left_path),
        "right_sha256": sha256_file(right_path),
        "left_metadata": left_meta,
        "right_metadata": right_meta,
        "status": "MATCH",
        "domains": {},
        "first_divergence": None,
        "diagnostic_resync": None,
        "cross_domain_ordering_note": (
            "Domains are compared independently. The reported first domain/index does not imply a "
            "cross-clock chronological ordering unless the observability contract proves one."
        ),
    }
    global_first: tuple[int, int, dict[str, Any]] | None = None

    for domain_order, domain in enumerate(selected):
        l_info = left_index.get(domain, {"start": 0, "end": 0, "count": 0})
        r_info = right_index.get(domain, {"start": 0, "end": 0, "count": 0})
        fields = _fields_for_domain(contract, domain)
        domain_result: dict[str, Any] = {
            "status": "MATCH",
            "left_count": l_info["count"],
            "right_count": r_info["count"],
            "fields": list(fields),
            "first_index": None,
        }

        left_iter = _iter_domain(left_path, l_info) if l_info["count"] else iter(())
        right_iter = _iter_domain(right_path, r_info) if r_info["count"] else iter(())
        prior_left: deque[dict[str, Any]] = deque(maxlen=context_events)
        prior_right: deque[dict[str, Any]] = deque(maxlen=context_events)
        mismatch_index: int | None = None
        mismatch_fields: list[str] = []
        left_event: dict[str, Any] | None = None
        right_event: dict[str, Any] | None = None
        index_value = 0
        while True:
            try:
                left_event = next(left_iter)
            except StopIteration:
                left_event = None
            try:
                right_event = next(right_iter)
            except StopIteration:
                right_event = None
            if left_event is None and right_event is None:
                break
            if left_event is None or right_event is None:
                mismatch_index = index_value
                mismatch_fields = ["<event_count>"]
                break
            equal, mismatch_fields = _events_equal(left_event, right_event, fields)
            if not equal:
                mismatch_index = index_value
                break
            prior_left.append(left_event)
            prior_right.append(right_event)
            index_value += 1

        if mismatch_index is not None:
            domain_result["status"] = "DIVERGED"
            domain_result["first_index"] = mismatch_index
            read_count = max(context_events, resync_window)
            left_after = _read_ahead(left_iter, read_count)
            right_after = _read_ahead(right_iter, read_count)
            left_window = ([left_event] if left_event is not None else []) + left_after
            right_window = ([right_event] if right_event is not None else []) + right_after
            divergence = {
                "domain": domain,
                "index": mismatch_index,
                "mismatch_fields": mismatch_fields,
                "left_event": left_event,
                "right_event": right_event,
                "last_match": prior_left[-1] if prior_left else None,
                "left_context": list(prior_left) + left_window[:context_events],
                "right_context": list(prior_right) + right_window[:context_events],
            }
            domain_result["divergence"] = divergence
            order_key = (domain_order, mismatch_index)
            if global_first is None or order_key < (global_first[0], global_first[1]):
                global_first = (domain_order, mismatch_index, divergence)
            if resync_window > 0 and left_event is not None and right_event is not None:
                left_diag = left_window[: resync_window + 1]
                right_diag = right_window[: resync_window + 1]
                candidates = _diagnostic_resync(
                    left_diag, right_diag, fields, base_index=mismatch_index
                )
                if candidates:
                    domain_result["diagnostic_resync"] = candidates

        report["domains"][domain] = domain_result

    if global_first is not None:
        report["status"] = "DIVERGED"
        report["first_divergence"] = global_first[2]
        diagnostics = {
            domain: value.get("diagnostic_resync")
            for domain, value in report["domains"].items()
            if value.get("diagnostic_resync")
        }
        if diagnostics:
            report["diagnostic_resync"] = diagnostics
            report["note"] = (
                "A diagnostic re-synchronization candidate never converts this result into a pass. "
                "Dropped, inserted or reordered events remain a divergence."
            )
    return report


def render_diff_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# MAME vs RTL differential report",
        "",
        f"**Status:** `{report.get('status')}`",
        f"**Created:** {report.get('created_utc')}",
        "",
        report.get("cross_domain_ordering_note", ""),
        "",
    ]
    if report.get("status") == "MATCH":
        lines.extend(["All selected canonical event streams match exactly.", ""])
    else:
        div = report.get("first_divergence") or {}
        lines.extend([
            "## First meaningful divergence",
            "",
            f"- Domain: `{div.get('domain')}`",
            f"- Domain event index: `{div.get('index')}`",
            f"- Differing fields: `{', '.join(div.get('mismatch_fields', []))}`",
            "",
            "### Last matching event",
            "",
            "```json",
            json.dumps(div.get("last_match"), indent=2, sort_keys=True),
            "```",
            "",
            "### MAME/reference event",
            "",
            "```json",
            json.dumps(div.get("left_event"), indent=2, sort_keys=True),
            "```",
            "",
            "### RTL event",
            "",
            "```json",
            json.dumps(div.get("right_event"), indent=2, sort_keys=True),
            "```",
            "",
            "The mismatch is a localization point, not automatically the root cause. Trace backward "
            "to the earliest producer that made the RTL event inevitable.",
            "",
        ])
    lines.extend([
        "## Domain results",
        "",
        "| Domain | Status | Reference events | RTL events | First index |",
        "| --- | --- | ---: | ---: | ---: |",
    ])
    for domain, result in report.get("domains", {}).items():
        lines.append(
            f"| {domain} | {result.get('status')} | {result.get('left_count')} | "
            f"{result.get('right_count')} | {result.get('first_index')} |"
        )
    lines.append("")
    if report.get("diagnostic_resync"):
        lines.extend([
            "## Diagnostic re-synchronization",
            "",
            "Candidates were found, but they are diagnostic only. A shifted match is not a pass.",
            "",
        ])
    return "\n".join(lines)


def write_diff_report(report: dict[str, Any], json_path: Path, md_path: Path) -> None:
    atomic_write_json(json_path, report)
    atomic_write_text(md_path, render_diff_markdown(report) + "\n")
