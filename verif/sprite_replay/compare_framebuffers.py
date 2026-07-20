"""Exact 16-bit framebuffer comparator for System 32 sprite replays."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .format import FB_BYTES, FB_HEIGHT, FB_WIDTH, sha256_bytes


def compare_u16(
    expected: bytes,
    actual: bytes,
    width: int,
    height: int,
    max_report: int = 20,
) -> dict[str, object]:
    expected_size = width * height * 2
    if len(expected) != expected_size or len(actual) != expected_size:
        raise ValueError(
            f"buffers must both be {expected_size} bytes ({width}x{height} u16le); "
            f"got expected={len(expected)} actual={len(actual)}"
        )
    differences: list[dict[str, int]] = []
    mismatch_count = 0
    min_x, min_y = width, height
    max_x = max_y = -1
    for pixel in range(width * height):
        offset = pixel * 2
        want = int.from_bytes(expected[offset:offset + 2], "little")
        got = int.from_bytes(actual[offset:offset + 2], "little")
        if want == got:
            continue
        mismatch_count += 1
        y, x = divmod(pixel, width)
        min_x, min_y = min(min_x, x), min(min_y, y)
        max_x, max_y = max(max_x, x), max(max_y, y)
        if len(differences) < max_report:
            differences.append({"x": x, "y": y, "expected": want, "actual": got})
    return {
        "match": mismatch_count == 0,
        "mismatch_count": mismatch_count,
        "bbox": None if mismatch_count == 0 else [min_x, min_y, max_x, max_y],
        "first_differences": differences,
        "expected_sha256": sha256_bytes(expected),
        "actual_sha256": sha256_bytes(actual),
    }


def compare(expected: bytes, actual: bytes, max_report: int = 20) -> dict[str, object]:
    return compare_u16(expected, actual, FB_WIDTH, FB_HEIGHT, max_report)


def active_scanout(physical: bytes, width: int, control2: int) -> bytes:
    """Map MAME physical storage to the visible ctl2-flipped active frame."""
    if len(physical) != FB_BYTES or width not in (320, 416):
        raise ValueError("physical framebuffer must be 416x224 and width 320 or 416")
    flip_x = bool(control2 & 1)
    flip_y = bool(control2 & 2)
    output = bytearray(width * FB_HEIGHT * 2)
    for y in range(FB_HEIGHT):
        source_y = FB_HEIGHT - 1 - y if flip_y else y
        for x in range(width):
            source_x = width - 1 - x if flip_x else x
            source = (source_y * FB_WIDTH + source_x) * 2
            target = (y * width + x) * 2
            output[target:target + 2] = physical[source:source + 2]
    return bytes(output)


def active_crop(physical: bytes, width: int) -> bytes:
    """Read active pixels from RTL storage, where writes already mirror ctl2."""
    if len(physical) != FB_BYTES or width not in (320, 416):
        raise ValueError("physical framebuffer must be 416x224 and width 320 or 416")
    output = bytearray(width * FB_HEIGHT * 2)
    for y in range(FB_HEIGHT):
        source = y * FB_WIDTH * 2
        target = y * width * 2
        output[target:target + width * 2] = physical[source:source + width * 2]
    return bytes(output)


def rtl_storage_initial(physical: bytes, width: int, control2: int) -> bytes:
    """Adapt a MAME physical baseline for the RTL's sequential scanout store."""
    visible = active_scanout(physical, width, control2)
    output = bytearray(physical)
    for y in range(FB_HEIGHT):
        source = y * width * 2
        target = y * FB_WIDTH * 2
        output[target:target + width * 2] = visible[source:source + width * 2]
    return bytes(output)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--max-report", type=int, default=20)
    parser.add_argument("--json", dest="json_path", type=Path)
    args = parser.parse_args(argv)
    try:
        result = compare(args.expected.read_bytes(), args.actual.read_bytes(), args.max_report)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    text = json.dumps(result, indent=2, sort_keys=True)
    print(text)
    if args.json_path:
        args.json_path.write_text(text + "\n", encoding="utf-8")
    return 0 if result["match"] else 1


if __name__ == "__main__":
    sys.exit(main())
