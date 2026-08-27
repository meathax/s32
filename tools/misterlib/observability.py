from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable

from . import SCHEMA_VERSION
from .config import OBS_REL
from .util import load_json


class ObservabilityError(ValueError):
    pass


REQUIRED_NATIVE_FIELDS = {
    "address_unit_bytes",
    "width_bits",
    "data_encoding",
    "lane_to_canonical",
    "byte_enable_polarity",
    "phase",
    "evidence",
}
ALLOWED_DATA_ENCODINGS = {"lane_numeric"}
ALLOWED_BE_POLARITY = {"active_high", "active_low"}
ALLOWED_ORDERINGS = {"domain_seq", "canonical_time"}
ALLOWED_INPUT_TIMEBASES = {"canonical_event", "video_position", "reset_anchor"}


def load_contract(root: Path) -> dict[str, Any]:
    path = root / OBS_REL
    data = load_json(path)
    if data is None:
        raise ObservabilityError(f"Missing {OBS_REL.as_posix()}.")
    if not isinstance(data, dict):
        raise ObservabilityError("Observability contract must be a JSON object.")
    return data


def validate_contract(
    contract: dict[str, Any],
    domains: Iterable[str] | None = None,
    *,
    require_strict: bool = True,
) -> dict[str, list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    if contract.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"Observability schema_version must be {SCHEMA_VERSION}.")
    if contract.get("raw_event_schema") not in {None, "mister-raw-trace-v4"}:
        errors.append("raw_event_schema must be 'mister-raw-trace-v4'.")
    if contract.get("canonical_event_schema") not in {None, "mister-canonical-trace-v4"}:
        errors.append("canonical_event_schema must be 'mister-canonical-trace-v4'.")

    all_domains = contract.get("domains")
    if not isinstance(all_domains, dict) or not all_domains:
        errors.append("Observability contract must define at least one domain.")
        return {"errors": errors, "warnings": warnings}

    selected = list(domains) if domains is not None else sorted(all_domains)
    if len(set(selected)) != len(selected):
        errors.append("Selected domains contain duplicates.")
    for domain_name in selected:
        domain = all_domains.get(domain_name)
        prefix = f"domains.{domain_name}"
        if not isinstance(domain_name, str) or not domain_name:
            errors.append("Domain names must be non-empty strings.")
            continue
        if not isinstance(domain, dict):
            errors.append(f"{prefix} is missing or invalid.")
            continue
        if require_strict and domain.get("strict") is not True:
            errors.append(f"{prefix}.strict must be true before differential comparison.")
        ordering = domain.get("ordering")
        if ordering not in ALLOWED_ORDERINGS:
            errors.append(f"{prefix}.ordering must be one of {sorted(ALLOWED_ORDERINGS)}.")
        if ordering == "canonical_time" and domain.get("global_order_proven") is not True:
            errors.append(f"{prefix} requests canonical_time ordering without global_order_proven=true.")

        meaning = domain.get("meaning")
        if not isinstance(meaning, str) or not meaning.strip() or meaning.strip().upper().startswith("AUTO"):
            warnings.append(f"{prefix}.meaning is unresolved.")

        canonical = domain.get("canonical")
        if not isinstance(canonical, dict):
            errors.append(f"{prefix}.canonical is required.")
            canonical = {}
        canonical_width = canonical.get("width_bits")
        if isinstance(canonical_width, bool) or not isinstance(canonical_width, int) or canonical_width <= 0 or canonical_width % 8:
            errors.append(f"{prefix}.canonical.width_bits must be a positive multiple of 8.")
        canonical_phase = canonical.get("phase")
        if not isinstance(canonical_phase, str) or not canonical_phase:
            errors.append(f"{prefix}.canonical.phase is required.")

        for side in ("mame", "rtl"):
            native = domain.get(side)
            if not isinstance(native, dict):
                errors.append(f"{prefix}.{side} is required.")
                continue
            missing = sorted(REQUIRED_NATIVE_FIELDS - set(native))
            for field in missing:
                errors.append(f"{prefix}.{side}.{field} is required.")
            aub = native.get("address_unit_bytes")
            if isinstance(aub, bool) or not isinstance(aub, int) or aub <= 0:
                errors.append(f"{prefix}.{side}.address_unit_bytes must be a positive integer.")
            bias = native.get("address_bias_bytes", 0)
            if isinstance(bias, bool) or not isinstance(bias, int):
                errors.append(f"{prefix}.{side}.address_bias_bytes must be an integer when present.")
            width = native.get("width_bits")
            if isinstance(width, bool) or not isinstance(width, int) or width <= 0 or width % 8:
                errors.append(f"{prefix}.{side}.width_bits must be a positive multiple of 8.")
            elif isinstance(canonical_width, int) and width != canonical_width:
                errors.append(
                    f"{prefix}.{side}.width_bits ({width}) differs from canonical width "
                    f"({canonical_width}); split the domain or add an explicit adapter."
                )
            if native.get("data_encoding") not in ALLOWED_DATA_ENCODINGS:
                errors.append(
                    f"{prefix}.{side}.data_encoding must be 'lane_numeric'; implicit endian interpretation is rejected."
                )
            lane_map = native.get("lane_to_canonical")
            lanes = width // 8 if isinstance(width, int) and not isinstance(width, bool) and width > 0 and width % 8 == 0 else 0
            if not isinstance(lane_map, list) or len(lane_map) != lanes:
                errors.append(f"{prefix}.{side}.lane_to_canonical must contain exactly {lanes} entries.")
            elif any(isinstance(item, bool) or not isinstance(item, int) for item in lane_map) or sorted(lane_map) != list(range(lanes)):
                errors.append(f"{prefix}.{side}.lane_to_canonical must be a permutation of 0..{lanes - 1}.")
            if native.get("byte_enable_polarity") not in ALLOWED_BE_POLARITY:
                errors.append(f"{prefix}.{side}.byte_enable_polarity must be active_high or active_low.")
            if native.get("phase") != canonical_phase:
                errors.append(
                    f"{prefix}.{side}.phase ({native.get('phase')!r}) does not equal the canonical phase "
                    f"({canonical_phase!r}). Phase conversion is never assumed."
                )
            evidence = native.get("evidence")
            if not isinstance(evidence, str) or not evidence.strip() or evidence.strip().upper().startswith("AUTO"):
                if require_strict:
                    errors.append(f"{prefix}.{side}.evidence must cite the proven observation boundary.")
                else:
                    warnings.append(f"{prefix}.{side}.evidence is unresolved.")

        optional = domain.get("comparable_optional_fields", [])
        if not isinstance(optional, list) or any(not isinstance(item, str) or not item for item in optional):
            errors.append(f"{prefix}.comparable_optional_fields must be an array of non-empty strings.")
        elif len(set(optional)) != len(optional):
            errors.append(f"{prefix}.comparable_optional_fields must not contain duplicates.")
        forbidden = {"domain", "seq", "schema", "address_bytes", "data", "width_bits", "byte_enable", "rw", "phase", "event"}
        if isinstance(optional, list) and forbidden.intersection(optional):
            errors.append(f"{prefix}.comparable_optional_fields contains reserved canonical fields.")

    return {"errors": errors, "warnings": warnings}


def _parse_int(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise ObservabilityError(f"{field} may not be boolean.")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        text = value.strip().lower().replace("_", "")
        try:
            return int(text, 0)
        except ValueError as exc:
            raise ObservabilityError(f"{field} is not an integer: {value!r}") from exc
    raise ObservabilityError(f"{field} is not an integer: {value!r}")


def _map_lanes(value: int, width_bits: int, lane_map: list[int]) -> int:
    lanes = width_bits // 8
    mask = (1 << width_bits) - 1
    if value < 0 or value > mask:
        raise ObservabilityError(f"data value 0x{value:x} does not fit the declared {width_bits}-bit bus.")
    out = 0
    for native_lane in range(lanes):
        byte_value = (value >> (8 * native_lane)) & 0xFF
        canonical_lane = lane_map[native_lane]
        out |= byte_value << (8 * canonical_lane)
    return out


def _map_byte_enable(value: int, width_bits: int, lane_map: list[int], polarity: str) -> int:
    lanes = width_bits // 8
    lane_mask = (1 << lanes) - 1
    if value < 0 or value > lane_mask:
        raise ObservabilityError(f"byte_enable 0x{value:x} is outside the {lanes}-lane mask.")
    active = value if polarity == "active_high" else (~value & lane_mask)
    out = 0
    for native_lane in range(lanes):
        if active & (1 << native_lane):
            out |= 1 << lane_map[native_lane]
    if out == 0:
        raise ObservabilityError("An accepted bus event may not have a zero active byte-enable mask.")
    return out


def canonicalize_event(event: dict[str, Any], *, side: str, contract: dict[str, Any]) -> dict[str, Any]:
    if side not in {"mame", "rtl"}:
        raise ObservabilityError("side must be 'mame' or 'rtl'.")
    if not isinstance(event, dict):
        raise ObservabilityError("Trace event must be an object.")
    domain_name = event.get("domain")
    if not isinstance(domain_name, str) or not domain_name:
        raise ObservabilityError("event.domain is required.")
    domain = contract.get("domains", {}).get(domain_name)
    if not isinstance(domain, dict):
        raise ObservabilityError(f"Domain {domain_name!r} is not defined in the observability contract.")
    checked = validate_contract(
        {
            "schema_version": SCHEMA_VERSION,
            "raw_event_schema": "mister-raw-trace-v4",
            "canonical_event_schema": "mister-canonical-trace-v4",
            "domains": {domain_name: domain},
        },
        [domain_name],
        require_strict=True,
    )
    if checked["errors"]:
        raise ObservabilityError("; ".join(checked["errors"]))

    native = domain[side]
    canonical = domain["canonical"]
    width_bits = int(native["width_bits"])
    lanes = width_bits // 8
    seq = _parse_int(event.get("seq"), "seq")
    if seq < 0:
        raise ObservabilityError("seq must be non-negative.")
    phase = event.get("phase")
    if phase != native["phase"]:
        raise ObservabilityError(f"event phase {phase!r} does not match {side} contract phase {native['phase']!r}.")
    rw = str(event.get("rw", "")).upper()
    if rw not in {"R", "W"}:
        raise ObservabilityError("rw must be R or W.")
    event_kind = event.get("event")
    if not isinstance(event_kind, str) or not event_kind:
        raise ObservabilityError("event must be a non-empty string.")
    address_native = _parse_int(event.get("address"), "address")
    if address_native < 0:
        raise ObservabilityError("address must be non-negative.")
    address_bytes = address_native * int(native["address_unit_bytes"]) + int(native.get("address_bias_bytes", 0))
    if address_bytes < 0:
        raise ObservabilityError("canonical byte address may not be negative.")
    data = _map_lanes(_parse_int(event.get("data"), "data"), width_bits, list(native["lane_to_canonical"]))
    be_default = (1 << lanes) - 1 if native["byte_enable_polarity"] == "active_high" else 0
    byte_enable = _map_byte_enable(
        _parse_int(event.get("byte_enable", be_default), "byte_enable"),
        width_bits,
        list(native["lane_to_canonical"]),
        str(native["byte_enable_polarity"]),
    )

    output: dict[str, Any] = {
        "schema": "mister-canonical-event-v4",
        "domain": domain_name,
        "seq": seq,
        "event": event_kind,
        "phase": str(canonical["phase"]),
        "rw": rw,
        "address_bytes": address_bytes,
        "data": data,
        "width_bits": int(canonical["width_bits"]),
        "byte_enable": byte_enable,
    }
    if domain["ordering"] == "canonical_time":
        canonical_time = _parse_int(event.get("canonical_time"), "canonical_time")
        if canonical_time < 0:
            raise ObservabilityError("canonical_time must be non-negative.")
        output["canonical_time"] = canonical_time
    for field in domain.get("comparable_optional_fields", []):
        if field not in event:
            raise ObservabilityError(
                f"Comparable optional field {field!r} is absent from {side} event {domain_name}:{seq}."
            )
        output[field] = event[field]
    return output


def validate_input_events(path: Path) -> dict[str, list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    if not path.exists():
        return {"errors": [f"Input file does not exist: {path}"], "warnings": []}
    seen_seq = -1
    with path.open("r", encoding="utf-8-sig") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as exc:
                errors.append(f"{path}:{line_number}: invalid JSON: {exc}")
                continue
            if not isinstance(event, dict):
                errors.append(f"{path}:{line_number}: input event must be an object.")
                continue
            unknown = set(event) - {"seq", "at", "clock_mapping_proven", "action"}
            if unknown:
                errors.append(f"{path}:{line_number}: unknown fields: {', '.join(sorted(unknown))}")
            seq = event.get("seq")
            if isinstance(seq, bool) or not isinstance(seq, int) or seq != seen_seq + 1:
                errors.append(f"{path}:{line_number}: seq must be contiguous from 0; expected {seen_seq + 1}.")
            else:
                seen_seq = seq
            at = event.get("at")
            if not isinstance(at, dict):
                errors.append(f"{path}:{line_number}: at object is required.")
                continue
            timebase = at.get("timebase")
            if timebase not in ALLOWED_INPUT_TIMEBASES:
                errors.append(
                    f"{path}:{line_number}: timebase {timebase!r} is not allowed. Raw MAME or RTL cycle "
                    "counts are incomparable unless converted by an explicit adapter."
                )
            if timebase == "canonical_event":
                if not isinstance(at.get("domain"), str) or not at.get("domain") or isinstance(at.get("seq"), bool) or not isinstance(at.get("seq"), int) or at.get("seq", -1) < 0:
                    errors.append(f"{path}:{line_number}: canonical_event requires domain and non-negative integer seq.")
            elif timebase == "video_position":
                for field in ("frame", "scanline", "hpos"):
                    value = at.get(field)
                    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                        errors.append(f"{path}:{line_number}: video_position requires non-negative integer {field}.")
            elif timebase == "reset_anchor":
                value = at.get("offset_reference_ticks")
                if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                    errors.append(f"{path}:{line_number}: reset_anchor requires non-negative offset_reference_ticks.")
                if event.get("clock_mapping_proven") is not True:
                    errors.append(f"{path}:{line_number}: reset_anchor offsets require clock_mapping_proven=true.")
            action = event.get("action")
            if not isinstance(action, dict) or not isinstance(action.get("control"), str) or not action.get("control"):
                errors.append(f"{path}:{line_number}: action.control is required.")
            else:
                value = action.get("value")
                if not isinstance(value, (int, float, bool)):
                    errors.append(f"{path}:{line_number}: action.value must be numeric or boolean.")
    if seen_seq < 0:
        warnings.append(f"{path}: input file is empty; this is valid for a no-input scenario.")
    return {"errors": errors, "warnings": warnings}
