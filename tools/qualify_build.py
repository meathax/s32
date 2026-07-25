#!/usr/bin/env python3
"""Fail unless a fresh Quartus fit, timing report, and RBF are deployable."""
from pathlib import Path
import argparse
import re


def status(text, label):
    match = re.search(rf"(?m)^{re.escape(label)}\s*:\s*(.+)$", text)
    return match.group(1).strip() if match else ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--revision", default="Arcade-SegaSystem32")
    args = parser.parse_args()
    root = args.root.resolve()
    out = root / "output_files"
    revision = args.revision
    paths = {kind: out / f"{revision}.{kind}" for kind in ("map.summary", "fit.summary", "sta.summary", "rbf")}
    missing = [str(path) for path in paths.values() if not path.is_file()]
    if missing:
        raise SystemExit("BUILD NOT READY: missing " + ", ".join(missing))

    map_text = paths["map.summary"].read_text(errors="replace")
    fit_text = paths["fit.summary"].read_text(errors="replace")
    sta_text = paths["sta.summary"].read_text(errors="replace")
    if not status(map_text, "Analysis & Synthesis Status").startswith("Successful"):
        raise SystemExit("BUILD NOT READY: synthesis was not successful")
    if not status(fit_text, "Fitter Status").startswith("Successful"):
        raise SystemExit("BUILD NOT READY: fitter was not successful")

    slacks = [float(value) for value in re.findall(
        r"(?ms)^Type\s*:\s*.+?\r?\nSlack\s*:\s*(-?\d+(?:\.\d+)?)", sta_text)]
    if not slacks or min(slacks) < 0:
        detail = "missing" if not slacks else f"{min(slacks):.3f} ns"
        raise SystemExit(f"BUILD NOT READY: worst timing slack is {detail}")

    extensions = {".qpf", ".qsf", ".qip", ".qsys", ".sdc", ".tcl", ".sv", ".svh", ".v", ".vh", ".vhd", ".vhdl", ".mif", ".hex", ".mem"}
    inputs = [path for base in (root, root / "rtl", root / "sys", root / "tools") if base.exists()
              for path in (base.iterdir() if base == root else base.rglob("*"))
              if path.is_file() and path.suffix.lower() in extensions]
    newest_input = max((path.stat().st_mtime for path in inputs), default=0)
    map_time = paths["map.summary"].stat().st_mtime
    fit_time = paths["fit.summary"].stat().st_mtime
    sta_time = paths["sta.summary"].stat().st_mtime
    rbf_time = paths["rbf"].stat().st_mtime
    if not (fit_time >= newest_input and fit_time >= map_time and sta_time >= fit_time and rbf_time >= fit_time):
        raise SystemExit("BUILD NOT READY: reports or RBF are stale")
    print(f"BUILD READY: worst slack {min(slacks):.3f} ns; {paths['rbf']}")


if __name__ == "__main__":
    main()
