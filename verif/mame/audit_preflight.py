#!/usr/bin/env python3
"""Write the rtl-mame reference-alignment preflight for one S32 parent set."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


V25_PARENTS = {"ga2", "arabfgt"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command_output(args: list[str]) -> str:
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return (result.stdout + result.stderr).strip()


def ppm_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as source:
        magic = source.readline().strip()
        if magic not in {b"P3", b"P6"}:
            raise ValueError(f"unsupported PPM magic {magic!r}: {path}")
        dimensions = source.readline().split()
        while dimensions and dimensions[0].startswith(b"#"):
            dimensions = source.readline().split()
        if len(dimensions) != 2:
            raise ValueError(f"invalid PPM dimensions: {path}")
        return int(dimensions[0]), int(dimensions[1])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("set")
    parser.add_argument("session", type=Path)
    parser.add_argument("--profile", choices=("standard", "v25"), required=True)
    parser.add_argument("--mame", type=Path, default=Path(r"D:\Arcade\AI\mame\mame.exe"))
    parser.add_argument("--mame-source", type=Path, default=Path(r"D:\Arcade\AI\MAMESOURCE\mame"))
    parser.add_argument("--rom-root", type=Path, default=Path("roms"))
    parser.add_argument("--rtl-width", type=int, default=416)
    parser.add_argument("--rtl-height", type=int, default=224)
    parser.add_argument(
        "--reference-frame",
        type=Path,
        help="raw screen_device::pixels() PPM used for runtime dimensions",
    )
    args = parser.parse_args()

    args.session.mkdir(parents=True, exist_ok=True)
    for name in ("cfg", "nvram", "sta", "snap", "reference", "rtl", "diff", "logs"):
        (args.session / name).mkdir(exist_ok=True)

    expected_profile = "v25" if args.set in V25_PARENTS else "standard"
    archive = args.rom_root / f"{args.set}.zip"
    image_dir = args.rom_root / "sim" / args.set
    descriptor = image_dir / "desc.txt"
    source_driver = args.mame_source / "src" / "mame" / "sega" / "segas32.cpp"
    failures: list[str] = []
    if args.profile != expected_profile:
        failures.append(f"{args.set} belongs to {expected_profile}, not {args.profile}")
    for path in (args.mame, archive, descriptor, source_driver):
        if not path.is_file():
            failures.append(f"missing required file: {path.resolve()}")

    xml_text = ""
    machine = None
    if not failures:
        xml_text = command_output([str(args.mame), "-listxml", args.set])
        root = ET.fromstring(xml_text[xml_text.index("<?xml") :])
        machine = next(node for node in root.findall("machine") if node.get("name") == args.set)
        if machine.get("cloneof"):
            failures.append(f"{args.set} is a clone of {machine.get('cloneof')}")

    display = machine.find("display") if machine is not None else None
    declared_width = int(display.get("width", "0")) if display is not None else 0
    declared_height = int(display.get("height", "0")) if display is not None else 0
    if args.reference_frame is None:
        failures.append("a raw --reference-frame is required to establish runtime dimensions")
        ref_width, ref_height = declared_width, declared_height
    elif not args.reference_frame.is_file():
        failures.append(f"missing raw reference frame: {args.reference_frame.resolve()}")
        ref_width, ref_height = declared_width, declared_height
    else:
        ref_width, ref_height = ppm_dimensions(args.reference_frame)
    if ref_height and ref_height != args.rtl_height:
        failures.append(f"native height differs: MAME={ref_height}, RTL={args.rtl_height}")
    if ref_width and ref_width > args.rtl_width:
        failures.append(f"MAME width {ref_width} exceeds RTL surface {args.rtl_width}")

    image_hashes = {
        str(path.relative_to(image_dir)): sha256(path)
        for path in sorted(image_dir.glob("*"))
        if path.is_file()
    } if image_dir.is_dir() else {}
    controls = []
    if machine is not None:
        input_node = machine.find("input")
        if input_node is not None:
            controls = [dict(control.attrib) for control in input_node.findall("control")]

    artifact = {
        "schema": "s32-rtl-mame-preflight-v1",
        "result": "pass" if not failures else "failure",
        "failures": failures,
        "set": args.set,
        "cloneof": machine.get("cloneof") if machine is not None else None,
        "profile": args.profile,
        "profile_macro": "S32_UNIVERSAL=1;S32_V25_HW=1;S32_PROFILE_STANDARD=1",
        "media": {
            "mame_archive": str(archive.resolve()),
            "mame_archive_sha256": sha256(archive) if archive.is_file() else None,
            "rtl_image_dir": str(image_dir.resolve()),
            "rtl_image_sha256": image_hashes,
            "provenance": "tools/make_sim_images.py transforms the named parent ZIP into region images; container hashes are recorded, not falsely equated",
        },
        "tools": {
            "mame": command_output([str(args.mame), "-version"]) if args.mame.is_file() else None,
            "mame_source": str(source_driver.resolve()),
            "mame_source_sha256": sha256(source_driver) if source_driver.is_file() else None,
        },
        "configuration": {
            "isolated_cfg": str((args.session / "cfg").resolve()),
            "isolated_nvram": str((args.session / "nvram").resolve()),
            "isolated_state": str((args.session / "sta").resolve()),
            "sound": "enabled",
            "cabinet_and_dips": "MAME parent defaults; no inherited CFG",
            "digital_inputs": "neutral frame packet; one owner when interactive",
            "analog_inputs": "MAME parent defaults, including unassigned channels; descriptor-specific values must be copied into a session input manifest before causal comparison",
            "controls_declared_by_mame": controls,
        },
        "video": {
            "mame_surface": "screen_device::pixels() visible area before renderer",
            "mame_declared_dimensions": [declared_width, declared_height],
            "mame_runtime_dimensions": [ref_width, ref_height],
            "mame_runtime_dimension_evidence": str(args.reference_frame.resolve()) if args.reference_frame else None,
            "rtl_surface": "tb_core_romboot completed active-video PPM before presentation",
            "rtl_dimensions": [args.rtl_width, args.rtl_height],
            "fixed_alignment": {"x": 0, "y": 0, "crop_right_black": args.rtl_width - ref_width},
            "mame_boundary": "machine frame notifier after screen update",
            "rtl_boundary": "first active pixel after completed vertical blank transition",
            "phase_caveat": "tokens identify completed native surfaces; instantaneous CPU PCs are not assumed scheduler-phase-equal",
        },
    }
    target = args.session / ("PREFLIGHT_PASS.json" if not failures else "PREFLIGHT_FAILURE.json")
    target.write_text(json.dumps(artifact, indent=2) + "\n", encoding="utf-8")
    print(target)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
