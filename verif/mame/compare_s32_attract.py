#!/usr/bin/env python3
"""Compare an RTL attract-mode dump sweep against a MAME snapshot sweep.

Generic version of verif/mame/compare_sonic_gameplay.py: works for any game
captured with verif/mame/capture_frames.lua (S32_MAME_FRAMES=<list>) on the
MAME side and tb_core_romboot's +DUMPAT/+DUMPEVERY/+DUMPN on the RTL side,
as long as both used the SAME frame-number list (the two sides are matched by
position in that list, not by filename).

MAME's snapshot numbering is sequential (0000.png, 0001.png, ...) in capture
order; the RTL side names each dump by its own frame number (dump<N>.ppm).
This script maps position i in the requested-frame list to RTL frame N and
MAME snapshot i, then reports the differing-pixel count at a given RTL/MAME
frame offset, with an optional +/-N scan to distinguish timing drift from a
real content divergence (the same technique used for the SegaSonic gameplay
comparison).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops


def load_rtl(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB")


def crop_padding(rtl: Image.Image, width: int, height: int) -> Image.Image:
    if rtl.size == (width, height):
        return rtl
    if rtl.height != height or rtl.width < width:
        raise ValueError(f"unexpected RTL geometry {rtl.size} vs {(width, height)}")
    pad = rtl.crop((width, 0, rtl.width, rtl.height))
    if ImageChops.difference(
        pad, Image.new("RGB", pad.size, "black")
    ).getbbox() is not None:
        raise ValueError("RTL right padding is not black; geometry is wrong")
    return rtl.crop((0, 0, width, height))


def differing(a: Image.Image, b: Image.Image) -> int:
    delta = ImageChops.difference(a, b)
    return sum(1 for p in delta.getdata() if p != (0, 0, 0))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rtl-dir", type=Path, required=True,
                    help="directory containing dump<N>.ppm files")
    ap.add_argument("--mame-dir", type=Path, required=True,
                    help="directory containing MAME's NNNN.png snapshots")
    ap.add_argument("--frames", type=int, nargs="+", required=True,
                    help="the RTL frame numbers requested, in capture order "
                         "(matches +DUMPAT/+DUMPEVERY/+DUMPN and the same "
                         "list passed as S32_MAME_FRAMES on the MAME side)")
    ap.add_argument("--offset", type=int, default=0,
                    help="MAME frame = RTL frame + offset (searched "
                         "automatically from the first matching frame if 0 "
                         "differing pixels aren't found at offset 0)")
    ap.add_argument("--scan", type=int, default=10,
                    help="if a frame doesn't match at --offset, also try "
                         "nearby MAME snapshots (+/- this many list "
                         "positions) and report the best")
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()

    rows = []
    exact = 0
    for i, frame in enumerate(args.frames):
        rtl_path = args.rtl_dir / f"dump{frame}.ppm"
        mame_path = args.mame_dir / f"{i:04d}.png"
        if not rtl_path.is_file() or not mame_path.is_file():
            rows.append({"rtl": frame, "index": i, "status": "missing"})
            print(f"  RTL {frame:5d} (idx {i}): missing "
                  f"({'RTL' if not rtl_path.is_file() else 'MAME'} file absent)")
            continue
        mame = Image.open(mame_path).convert("RGB")
        rtl = crop_padding(load_rtl(rtl_path), mame.width, mame.height)
        d = differing(mame, rtl)
        row = {"rtl": frame, "index": i, "differing": d,
               "pixels": mame.width * mame.height,
               "percent": round(100.0 * d / (mame.width * mame.height), 4)}
        note = ""
        if d == 0:
            exact += 1
        elif args.scan:
            best = (d, i)
            for j in range(max(0, i - args.scan),
                           min(len(args.frames), i + args.scan + 1)):
                if j == i:
                    continue
                cand_path = args.mame_dir / f"{j:04d}.png"
                if not cand_path.is_file():
                    continue
                cand = Image.open(cand_path).convert("RGB")
                if cand.size != mame.size:
                    continue
                cd = differing(cand, rtl)
                if cd < best[0]:
                    best = (cd, j)
            row["best_differing"] = best[0]
            row["best_index"] = best[1]
            row["best_frame_offset"] = args.frames[best[1]] - frame if best[1] < len(args.frames) else None
            if best[1] != i:
                note = f"   best match idx {best[1]} ({best[0]} differing)"
        rows.append(row)
        print(f"  RTL {frame:5d} (idx {i:2d}) vs MAME idx {i:2d}: "
              f"{d:7d} / {row['pixels']} differing ({row['percent']:7.4f}%){note}")

    compared = [r for r in rows if "differing" in r]
    print(f"COMPARE: {exact}/{len(compared)} frames exact "
          f"({len(rows) - len(compared)} missing)")
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(rows, indent=2), encoding="utf-8")
    return 0 if compared and exact == len(compared) else 1


if __name__ == "__main__":
    raise SystemExit(main())
