#!/usr/bin/env python3
"""Convert tb_core_romboot [track] lines to the shared rtl-mame JSONL schema."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


TRACK = re.compile(
    r"^\[track\] f=(?P<frame>\d+) pc=(?P<pc>[0-9a-fA-F]+) "
    r"rw=(?P<rw>[rw]) +a=(?P<address>[0-9a-fA-F]+) "
    r"d=(?P<data>[0-9a-fA-F]+) be=(?P<be>[01]+)$"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    count = 0
    with args.log.open(encoding="utf-8", errors="replace") as source, args.output.open("w", encoding="utf-8") as output:
        for line in source:
            match = TRACK.match(line.strip())
            if not match:
                continue
            raw_data = int(match["data"], 16)
            byte_enable = int(match["be"], 2)
            # The MAME map exposes only the low byte of this 16-bit V60 bus.
            # Retain the common hardware-visible lane and discard the inactive
            # 0xff upper read padding rather than reporting a false mismatch.
            event = {
                "frame": int(match["frame"]),
                "cpu": 0,
                "event": "bus",
                "rw": match["rw"],
                "address": int(match["address"], 16),
                "data": raw_data & 0xFF,
                "lanes": 1 if byte_enable & 1 else 0,
                "device": 4,
                "pc": int(match["pc"], 16),
            }
            output.write(json.dumps(event, separators=(",", ":")) + "\n")
            count += 1
    print(f"normalized {count} trackball events -> {args.output}")
    return 0 if count else 1


if __name__ == "__main__":
    raise SystemExit(main())
