#!/usr/bin/env python3
"""Compare deterministic GA2 PLAYER SELECT MAME and Verilator memtraces.

The two simulators need not use the same absolute frame numbers.  This tool
compares ordered V60 PC/address/data/lane events plus the coinage and credit
state transitions that select the PLAYER SELECT title stream.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


MEMTRACE_RE = re.compile(
    r"\[memtrace\]\s+f=(?P<frame>\d+)\s+pc=(?P<pc>[0-9a-f]+)\s+"
    r"a=(?P<addr>[0-9a-f]+)\s+d=(?P<data>[0-9a-f]+)\s+"
    r"(?:(?:mask=(?P<mask>[0-9a-f]+))|(?:be=(?P<be>[01]{2})))",
    re.IGNORECASE,
)
STATE_RE = re.compile(
    r"\[state\]\s+ac7a=(?P<ac7a>[0-9a-f]+)\s+"
    r"ac7c=(?P<ac7c>[0-9a-f]+)\s+ac7e=(?P<ac7e>[0-9a-f]+)\s+"
    r"ac80=(?P<ac80>[0-9a-f]+)\s+palette=(?P<palette>[0-9a-f]+)\s+"
    r"stream_lo=(?P<stream_lo>[0-9a-f]+)\s+"
    r"stream_hi=(?P<stream_hi>[0-9a-f]+)",
    re.IGNORECASE,
)

STATE_WORDS = {
    0x20AC7A: 0x0100,
    0x20AC7C: 0x0101,
    0x20AC7E: 0x0001,
    0x20AC80: 0x0000,
}
STATE_MARKER_EXPECTED = {
    "ac7a": 0x0100,
    "ac7c": 0x0101,
    "ac7e": 0x0001,
    "ac80": 0x0000,
    "palette": 0x0191,
    "stream_lo": 0x20C5,
    "stream_hi": 0x0010,
}

# (PC, aligned address, data, lane mask)
COINAGE_SETF_EXPECTED = [
    (0x1331A9, 0x20AC7A, 0x0100, 0xFF00),
    (0x1331BD, 0x20AC7A, 0x0000, 0x00FF),
]
CONTROLLER_EXPECTED = [
    (0x101EAC, 0x204AD0, 0x0000, 0xFF00),
    (0x101F23, 0x204ACC, 0x0000, 0xFFFF),
    (0x101F56, 0x204AA6, 0x20C5, 0xFFFF),
    (0x101F56, 0x204AA8, 0x0010, 0xFFFF),
    (0x102097, 0x204A76, 0x0191, 0xFFFF),
]


@dataclass(frozen=True)
class Event:
    ordinal: int
    frame: int
    pc: int
    addr: int
    data: int
    lane_mask: int

    @property
    def signature(self) -> tuple[int, int, int, int]:
        return (self.pc, self.addr, self.data, self.lane_mask)


@dataclass(frozen=True)
class Check:
    name: str
    passed: bool
    detail: str


@dataclass
class Trace:
    events: list[Event]
    states: list[dict[str, int]]


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    if b"\x00" in raw:
        raise ValueError(f"{path}: contains NUL bytes")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"{path}: is not valid UTF-8/ASCII: {exc}") from exc


def be_to_mask(be: int) -> int:
    return (0x00FF if be & 0b01 else 0) | (0xFF00 if be & 0b10 else 0)


def parse_trace_text(text: str, *, source: str) -> Trace:
    events: list[Event] = []
    states: list[dict[str, int]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = MEMTRACE_RE.search(line)
        if match:
            mask_text = match.group("mask")
            be_text = match.group("be")
            if source == "mame" and mask_text is None:
                raise ValueError(f"line {line_number}: MAME memtrace is missing mask=")
            if source == "rtl" and be_text is None:
                raise ValueError(f"line {line_number}: RTL memtrace is missing be=")
            lane_mask = (
                int(mask_text, 16)
                if mask_text is not None
                else be_to_mask(int(be_text, 2))
            )
            events.append(
                Event(
                    ordinal=len(events),
                    frame=int(match.group("frame"), 10),
                    pc=int(match.group("pc"), 16) & 0xFFFFFF,
                    addr=int(match.group("addr"), 16) & 0xFFFFFE,
                    data=int(match.group("data"), 16) & 0xFFFF,
                    lane_mask=lane_mask & 0xFFFF,
                )
            )
        state_match = STATE_RE.search(line)
        if state_match:
            states.append(
                {name: int(state_match.group(name), 16) for name in STATE_MARKER_EXPECTED}
            )
    if not events:
        raise ValueError(f"{source}: no [memtrace] records found")
    return Trace(events=events, states=states)


def parse_trace(path: Path, *, source: str) -> Trace:
    return parse_trace_text(read_text(path), source=source)


def apply_event(value: int, event: Event) -> int:
    return ((value & ~event.lane_mask) | (event.data & event.lane_mask)) & 0xFFFF


def replay_word(events: Iterable[Event], addr: int) -> int:
    value = 0
    for event in events:
        if event.addr == addr:
            value = apply_event(value, event)
    return value


def compress(values: Iterable[int]) -> list[int]:
    result: list[int] = []
    for value in values:
        if not result or result[-1] != value:
            result.append(value)
    return result


def credit_lifecycle(events: Iterable[Event]) -> list[int]:
    word = 0
    values = [0]
    for event in events:
        if event.addr == 0x20AC80:
            word = apply_event(word, event)
            values.append((word >> 8) & 0xFF)
    return compress(values)


def matching_signatures(events: Iterable[Event], expected: list[tuple[int, int, int, int]]) -> list[Event]:
    pcs = {item[0] for item in expected}
    return [event for event in events if event.pc in pcs]


def first_sequence_window(
    events: Iterable[Event], expected: list[tuple[int, int, int, int]]
) -> list[Event]:
    """Return the first candidate transition, ignoring later periodic repeats.

    Once the first expected event is seen, every write from one of the PCs in
    the expected transition is significant until the expected sequence length
    is reached. This still exposes the old SETF expansion as extra events
    inside the window, while allowing later title/palette refreshes.
    """
    relevant = matching_signatures(events, expected)
    first = expected[0]
    for index, event in enumerate(relevant):
        if event.signature == first:
            return relevant[index : index + len(expected)]
    return relevant


def format_signature(item: tuple[int, int, int, int]) -> str:
    pc, addr, data, mask = item
    return f"pc={pc:06X} a={addr:06X} d={data:04X} lanes={mask:04X}"


def format_events(events: Iterable[Event]) -> str:
    items = [format_signature(event.signature) for event in events]
    return "; ".join(items) if items else "none"


def add_exact_sequence_check(
    checks: list[Check], name: str, events: list[Event], expected: list[tuple[int, int, int, int]]
) -> None:
    actual = first_sequence_window(events, expected)
    signatures = [event.signature for event in actual]
    checks.append(
        Check(
            name=name,
            passed=signatures == expected,
            detail=f"expected {len(expected)} ordered event(s); got {format_events(actual)}",
        )
    )


def compare(mame: Trace, rtl_state: Trace, rtl_object: Trace) -> list[Check]:
    checks: list[Check] = []

    add_exact_sequence_check(
        checks, "MAME coinage SETF byte lanes", mame.events, COINAGE_SETF_EXPECTED
    )
    add_exact_sequence_check(
        checks, "RTL coinage SETF byte lanes", rtl_state.events, COINAGE_SETF_EXPECTED
    )
    add_exact_sequence_check(
        checks, "MAME PLAYER SELECT controller", mame.events, CONTROLLER_EXPECTED
    )
    add_exact_sequence_check(
        checks, "RTL PLAYER SELECT controller", rtl_object.events, CONTROLLER_EXPECTED
    )

    for label, events in (("MAME", mame.events), ("RTL", rtl_state.events)):
        actual_words = {addr: replay_word(events, addr) for addr in STATE_WORDS}
        checks.append(
            Check(
                name=f"{label} final coinage/player state",
                passed=actual_words == STATE_WORDS,
                detail=", ".join(
                    f"{addr:06X}={actual_words[addr]:04X}" for addr in STATE_WORDS
                ),
            )
        )
        credits = credit_lifecycle(events)
        checks.append(
            Check(
                name=f"{label} credit lifecycle",
                passed=credits == [0, 1, 0],
                detail=" -> ".join(f"{value:02X}" for value in credits),
            )
        )

    checks.append(
        Check(
            name="MAME final state marker count",
            passed=len(mame.states) == 1,
            detail=f"found {len(mame.states)} [state] record(s)",
        )
    )
    if mame.states:
        checks.append(
            Check(
                name="MAME final state marker values",
                passed=mame.states[-1] == STATE_MARKER_EXPECTED,
                detail=", ".join(
                    f"{name}={mame.states[-1][name]:04X}" for name in STATE_MARKER_EXPECTED
                ),
            )
        )

    mame_controller = first_sequence_window(mame.events, CONTROLLER_EXPECTED)
    rtl_controller = first_sequence_window(rtl_object.events, CONTROLLER_EXPECTED)
    checks.append(
        Check(
            name="MAME/RTL normalized controller equality",
            passed=[event.signature for event in mame_controller]
            == [event.signature for event in rtl_controller],
            detail=f"MAME {len(mame_controller)} event(s), RTL {len(rtl_controller)} event(s)",
        )
    )
    return checks


MAME_SELF_TEST = """\
[memtrace] f=4 pc=0013053a a=20ac7a d=0000 mask=ffff
[memtrace] f=4 pc=0013053d a=20ac7c d=0000 mask=ffff
[memtrace] f=4 pc=0013053d a=20ac7e d=0000 mask=ffff
[memtrace] f=4 pc=00130534 a=20ac80 d=0000 mask=ffff
[memtrace] f=5 pc=00133189 a=20ac7c d=0001 mask=00ff
[memtrace] f=5 pc=00133191 a=20ac7c d=0100 mask=ff00
[memtrace] f=5 pc=00133199 a=20ac7e d=0001 mask=00ff
[memtrace] f=5 pc=001331a9 a=20ac7a d=0100 mask=ff00
[memtrace] f=5 pc=001331af a=20ac7e d=0000 mask=ff00
[memtrace] f=5 pc=001331bd a=20ac7a d=0000 mask=00ff
[memtrace] f=90 pc=0006030d a=20ac80 d=0100 mask=ff00
[memtrace] f=125 pc=00060341 a=20ac80 d=0000 mask=ff00
[memtrace] f=125 pc=00101eac a=204ad0 d=0000 mask=ff00
[memtrace] f=125 pc=00101f23 a=204acc d=0000 mask=ffff
[memtrace] f=125 pc=00101f56 a=204aa6 d=20c5 mask=ffff
[memtrace] f=125 pc=00101f56 a=204aa8 d=0010 mask=ffff
[memtrace] f=125 pc=00102097 a=204a76 d=0191 mask=ffff
[memtrace] f=190 pc=00102097 a=204a76 d=0191 mask=ffff
[state] ac7a=0100 ac7c=0101 ac7e=0001 ac80=0000 palette=0191 stream_lo=20c5 stream_hi=0010
"""

RTL_STATE_SELF_TEST = """\
[memtrace] f=1 pc=0013053a a=20ac7a d=0000 be=11 op=2d st=14
[memtrace] f=1 pc=0013053d a=20ac7c d=0000 be=11 op=2d st=14
[memtrace] f=1 pc=0013053d a=20ac7e d=0000 be=11 op=2d st=14
[memtrace] f=1 pc=00130534 a=20ac80 d=0000 be=11 op=2d st=14
[memtrace] f=4 pc=00133189 a=20ac7c d=0001 be=01 op=09 st=14
[memtrace] f=4 pc=00133191 a=20ac7c d=0100 be=10 op=09 st=14
[memtrace] f=4 pc=00133199 a=20ac7e d=0001 be=01 op=09 st=14
[memtrace] f=4 pc=001331a9 a=20ac7a d=0100 be=10 op=47 st=14
[memtrace] f=4 pc=001331af a=20ac7e d=0000 be=10 op=47 st=14
[memtrace] f=4 pc=001331bd a=20ac7a d=0000 be=01 op=47 st=14
[memtrace] f=45 pc=0006030d a=20ac80 d=0100 be=10 op=89 st=14
[memtrace] f=52 pc=00060341 a=20ac80 d=0000 be=10 op=89 st=14
"""

RTL_OBJECT_SELF_TEST = """\
[memtrace] f=59 pc=00101eac a=204ad0 d=0000 be=10 op=47 st=14
[memtrace] f=59 pc=00101f23 a=204acc d=0000 be=11 op=1b st=14
[memtrace] f=59 pc=00101f56 a=204aa6 d=20c5 be=11 op=2d st=14
[memtrace] f=59 pc=00101f56 a=204aa8 d=0010 be=11 op=2d st=14
[memtrace] f=59 pc=00102097 a=204a76 d=0191 be=11 op=1b st=14
"""


def self_test() -> None:
    good_checks = compare(
        parse_trace_text(MAME_SELF_TEST, source="mame"),
        parse_trace_text(RTL_STATE_SELF_TEST, source="rtl"),
        parse_trace_text(RTL_OBJECT_SELF_TEST, source="rtl"),
    )
    assert all(check.passed for check in good_checks), good_checks

    bad_object = RTL_OBJECT_SELF_TEST.replace(
        "[memtrace] f=59 pc=00101f23",
        "[memtrace] f=59 pc=00101eac a=204ad2 d=0000 be=11 op=47 st=14\n"
        "[memtrace] f=59 pc=00101f23",
    )
    bad_checks = compare(
        parse_trace_text(MAME_SELF_TEST, source="mame"),
        parse_trace_text(RTL_STATE_SELF_TEST, source="rtl"),
        parse_trace_text(bad_object, source="rtl"),
    )
    controller_check = next(
        check for check in bad_checks if check.name == "RTL PLAYER SELECT controller"
    )
    assert not controller_check.passed, "old multi-write SETF signature was not rejected"


def print_checks(checks: list[Check]) -> None:
    for check in checks:
        print(f"{'PASS' if check.passed else 'FAIL'}: {check.name}: {check.detail}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Compare fresh Golden Axe PLAYER SELECT MAME and Verilator memtrace "
            "logs by semantic event order rather than absolute frame number."
        )
    )
    parser.add_argument(
        "--mame",
        type=Path,
        default=Path("scratch/mame_ga2_select_trace.log"),
        help="MAME log emitted by ga2_select_trace.lua",
    )
    parser.add_argument(
        "--rtl-state",
        type=Path,
        default=Path("scratch/rtl_ga2_select_state.log"),
        help="Verilator log using +TRACELO=20ac7a +TRACEHI=20ac83",
    )
    parser.add_argument(
        "--rtl-object",
        type=Path,
        default=Path("scratch/rtl_ga2_select_object.log"),
        help="Verilator log using +TRACELO=204a60 +TRACEHI=204aff",
    )
    parser.add_argument("--json", type=Path, help="optionally write machine-readable results")
    parser.add_argument("--self-test", action="store_true", help="run embedded positive/negative parser tests")
    return parser


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    args = build_parser().parse_args()
    if args.self_test:
        self_test()
        print("GA2 SELECT TRACE COMPARATOR SELF-TEST PASS")
        return 0

    try:
        mame = parse_trace(args.mame, source="mame")
        rtl_state = parse_trace(args.rtl_state, source="rtl")
        rtl_object = parse_trace(args.rtl_object, source="rtl")
        checks = compare(mame, rtl_state, rtl_object)
    except (OSError, ValueError) as exc:
        print(f"GA2 SELECT TRACE ERROR: {exc}", file=sys.stderr)
        return 2

    print_checks(checks)
    if args.json:
        payload = {
            "passed": all(check.passed for check in checks),
            "checks": [asdict(check) for check in checks],
        }
        args.json.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    if all(check.passed for check in checks):
        print(f"GA2 SELECT TRACE MATCH PASS ({len(checks)} checks)")
        return 0
    print("GA2 SELECT TRACE MATCH FAIL", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
