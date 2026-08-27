#!/usr/bin/env python3
"""Flatten the MAME arabfgt V60/V25 MB8421 logs into one replay schedule.

The V60 does not use the MB8421 interrupt at all on this board (it never
writes 0x7fe/0x7ff), so there is no handshake edge to align on.  What there
is, is a stable per-frame cadence: the V25 emits a near-constant number of
mailbox writes per frame, so its own write counter is a usable clock.

Each V60 write tagged with MAME frame k is therefore scheduled at the V25
write count MAME had reached by the end of frame k.  The RTL bench injects a
line as soon as its own V25 write counter reaches that threshold, which keeps
the two sides aligned by *work done* rather than by wall time — the RTL V25
does not run at MAME's rate and has no frame signal of its own.

Output: "<threshold> <byte_offset> <byte_value>" per line, ascending.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

FRAME_RE = re.compile(r"^# frame (\d+) writes=(\d+) total=(\d+)")
V60_RE = re.compile(
    r"^\d+ f=(-?\d+) off=([0-9a-f]+) d=([0-9a-f]+) mask=([0-9a-f]+)"
)


def frame_totals(v25_log: Path) -> dict[int, int]:
    totals: dict[int, int] = {}
    for line in v25_log.read_text(encoding="utf-8", errors="replace").splitlines():
        m = FRAME_RE.match(line)
        if m:
            totals[int(m.group(1))] = int(m.group(3))
    return totals


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--v25-log", type=Path,
                    default=Path("scratch/arab_v25_boot/writes_60.txt"))
    ap.add_argument("--v60-log", type=Path,
                    default=Path("scratch/arab_v25_boot/v60_writes_full.txt"))
    ap.add_argument("--out", type=Path,
                    default=Path("scratch/arab_v25_rtl/v60_schedule.txt"))
    ap.add_argument("--max-frame", type=int, default=40)
    args = ap.parse_args()

    totals = frame_totals(args.v25_log)
    if not totals:
        raise SystemExit("no frame totals in the V25 log")

    rows: list[tuple[int, int, int]] = []
    skipped_wide = 0
    for line in args.v60_log.read_text(encoding="utf-8",
                                       errors="replace").splitlines():
        m = V60_RE.match(line)
        if not m:
            continue
        frame = int(m.group(1))
        if frame > args.max_frame:
            break
        offset = int(m.group(2), 16)
        data = int(m.group(3), 16)
        mask = int(m.group(4), 16)
        # The V60 side of the dual-port RAM is the low byte lane only; a write
        # that claims the high lane would mean the byte-lane assumption is
        # wrong, so count it rather than silently dropping it.
        if mask & 0xFF00:
            skipped_wide += 1
        if not (mask & 0x00FF):
            continue
        threshold = totals.get(frame)
        if threshold is None:
            continue
        rows.append((threshold, offset, data & 0xFF))

    rows.sort(key=lambda r: r[0])
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="ascii") as fh:
        for threshold, offset, data in rows:
            fh.write(f"{threshold} {offset:03x} {data:02x}\n")

    print(f"schedule rows={len(rows)} frames<={args.max_frame} "
          f"high-lane-writes={skipped_wide} -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
