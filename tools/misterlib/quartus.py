from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from .util import atomic_write_json, utc_now


NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
RESOURCE_PATTERNS = {
    "logic_elements": [
        re.compile(r"Total logic elements\s*[:;]\s*([\d,]+)", re.I),
        re.compile(r"Logic utilization.*?([\d,]+)\s*/", re.I),
    ],
    "registers": [
        re.compile(r"Total registers\s*[:;]\s*([\d,]+)", re.I),
        re.compile(r"Dedicated logic registers\s*[:;]\s*([\d,]+)", re.I),
    ],
    "memory_bits": [re.compile(r"Total block memory bits\s*[:;]\s*([\d,]+)", re.I)],
    "ram_blocks": [
        re.compile(r"Total RAM Blocks\s*[:;]\s*([\d,]+)", re.I),
        re.compile(r"M10K blocks\s*[:;]\s*([\d,]+)", re.I),
    ],
    "dsp_blocks": [re.compile(r"Total DSP Blocks\s*[:;]\s*([\d,]+)", re.I)],
    "plls": [re.compile(r"Total PLLs\s*[:;]\s*([\d,]+)", re.I)],
}
SETUP_PATTERNS = [
    re.compile(r"(?:Worst-case setup slack|Setup slack)\s*[:;]\s*(%s)" % NUMBER, re.I),
    re.compile(r"Setup Summary.*?Slack.*?\n.*?(%s)" % NUMBER, re.I | re.S),
]
HOLD_PATTERNS = [
    re.compile(r"(?:Worst-case hold slack|Hold slack)\s*[:;]\s*(%s)" % NUMBER, re.I),
    re.compile(r"Hold Summary.*?Slack.*?\n.*?(%s)" % NUMBER, re.I | re.S),
]
ERROR_RE = re.compile(r"^\s*Error\s*(?:\(\d+\))?\s*:\s*(.+)$", re.I | re.M)
CRITICAL_RE = re.compile(r"^\s*Critical Warning\s*(?:\(\d+\))?\s*:\s*(.+)$", re.I | re.M)
UNCONSTRAINED_COUNT_PATTERNS = [
    re.compile(r"(?:number|total)\s+of\s+unconstrained\s+paths\s*[:;=]\s*(\d+)", re.I),
    re.compile(r"unconstrained\s+paths\s*[:;=]\s*(\d+)", re.I),
    re.compile(r"(?:found|there\s+are)\s+(\d+)\s+unconstrained\s+paths", re.I),
    re.compile(r"(\d+)\s+unconstrained\s+paths", re.I),
]


def _read_reports(report_dir: Path) -> list[tuple[Path, str]]:
    reports: list[tuple[Path, str]] = []
    if not report_dir.exists():
        return reports
    for path in sorted(report_dir.glob("**/*")):
        if path.is_file() and path.suffix.lower() in {".rpt", ".summary", ".log"}:
            try:
                reports.append((path, path.read_text(encoding="utf-8", errors="replace")))
            except OSError:
                pass
    return reports


def _extract_first(patterns: list[re.Pattern[str]], reports: list[tuple[Path, str]]) -> tuple[float | None, str | None]:
    for path, text in reports:
        for pattern in patterns:
            match = pattern.search(text)
            if match:
                try:
                    return float(match.group(1).replace(",", "")), str(path)
                except ValueError:
                    continue
    return None, None


def _unique_message_count(pattern: re.Pattern[str], reports: list[tuple[Path, str]]) -> int:
    messages: set[str] = set()
    for _, text in reports:
        for match in pattern.finditer(text):
            messages.add(" ".join(match.group(1).split()).lower())
    return len(messages)


def _unconstrained_summary(reports: list[tuple[Path, str]]) -> tuple[int, int]:
    """Return (explicit path count, ambiguous mentions).

    A line saying "0 unconstrained paths" must not fail a release. An ambiguous
    mention with no numeric result is retained as a fail-closed warning/gate.
    """

    explicit_counts: list[int] = []
    ambiguous = 0
    for _, text in reports:
        consumed_spans: list[tuple[int, int]] = []
        for pattern in UNCONSTRAINED_COUNT_PATTERNS:
            for match in pattern.finditer(text):
                try:
                    explicit_counts.append(int(match.group(1)))
                    consumed_spans.append(match.span())
                except ValueError:
                    pass
        lowered = text.lower()
        for match in re.finditer(r"^.*unconstrained.*$", lowered, re.M):
            line = match.group(0)
            if any(start <= match.start() < end or match.start() <= start < match.end() for start, end in consumed_spans):
                continue
            if re.search(r"\b(?:no|zero)\s+unconstrained\s+paths\b", line):
                continue
            if re.search(r"\b0\s+unconstrained\s+paths\b", line):
                continue
            if "unconstrained" in line:
                ambiguous += 1
    return (max(explicit_counts, default=0), ambiguous)


def parse_quartus_reports(
    report_dir: Path,
    *,
    build_started_ns: int | None = None,
    gates: dict[str, Any] | None = None,
) -> dict[str, Any]:
    report_dir = report_dir.resolve()
    all_reports = _read_reports(report_dir)
    stale = []
    reports = all_reports
    if build_started_ns is not None:
        reports = []
        for path, text in all_reports:
            try:
                fresh = path.stat().st_mtime_ns >= build_started_ns
            except OSError:
                fresh = False
            if fresh:
                reports.append((path, text))
            else:
                stale.append(str(path))

    resources: dict[str, Any] = {}
    sources: dict[str, str] = {}
    for key, patterns in RESOURCE_PATTERNS.items():
        for path, text in reports:
            value: int | None = None
            for pattern in patterns:
                match = pattern.search(text)
                if match:
                    try:
                        value = int(match.group(1).replace(",", ""))
                    except ValueError:
                        pass
                    break
            if value is not None:
                resources[key] = value
                sources[key] = str(path)
                break

    setup, setup_source = _extract_first(SETUP_PATTERNS, reports)
    hold, hold_source = _extract_first(HOLD_PATTERNS, reports)
    errors = _unique_message_count(ERROR_RE, reports)
    critical = _unique_message_count(CRITICAL_RE, reports)
    unconstrained_paths, ambiguous_unconstrained_mentions = _unconstrained_summary(reports)

    result: dict[str, Any] = {
        "schema": "mister-quartus-report-v4",
        "created_utc": utc_now(),
        "report_dir": str(report_dir),
        "report_count": len(reports),
        "all_report_count": len(all_reports),
        "resources": resources,
        "resource_sources": sources,
        "timing": {
            "setup_slack_ns": setup,
            "setup_source": setup_source,
            "hold_slack_ns": hold,
            "hold_source": hold_source,
        },
        "errors": errors,
        "critical_warnings": critical,
        "unconstrained_paths": unconstrained_paths,
        "ambiguous_unconstrained_mentions": ambiguous_unconstrained_mentions,
        "unconstrained_mentions": unconstrained_paths + ambiguous_unconstrained_mentions,
        "stale_reports": stale,
        "gates": {},
        "status": "UNKNOWN",
    }
    if gates is not None:
        gate_results: dict[str, bool] = {}
        gate_results["reports_present"] = bool(reports)
        gate_results["fresh_reports"] = bool(reports) if gates.get("require_fresh_reports", True) else True
        gate_results["errors"] = errors <= int(gates.get("max_errors", 0))
        gate_results["critical_warnings"] = critical <= int(gates.get("max_critical_warnings", 0))
        min_setup = float(gates.get("min_setup_slack_ns", 0.0))
        min_hold = float(gates.get("min_hold_slack_ns", 0.0))
        gate_results["setup_slack"] = setup is not None and setup >= min_setup
        gate_results["hold_slack"] = hold is not None and hold >= min_hold
        allow_unconstrained = bool(gates.get("allow_unconstrained_paths", False))
        gate_results["unconstrained_paths"] = allow_unconstrained or (
            unconstrained_paths == 0 and ambiguous_unconstrained_mentions == 0
        )
        result["gates"] = gate_results
        result["status"] = "PASS" if all(gate_results.values()) else "FAIL"
    return result


def write_quartus_report(root: Path, report: dict[str, Any]) -> Path:
    path = root / ".mister/reports/quartus.json"
    atomic_write_json(path, report)
    return path
