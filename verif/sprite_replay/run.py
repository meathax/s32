"""Run an s32.sprite.v1 fixture through oracle and production RTL."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from .compare_framebuffers import active_crop, active_scanout, compare, compare_u16, rtl_storage_initial
from .descriptor_audit import audit as audit_descriptors
from .format import (
    FB_PIXELS,
    load_manifest,
    read_blob,
    read_u16_hex,
    sha256_file,
    write_json,
    write_rom128_hex,
    write_u16le_hex,
)


REPO_ROOT = Path(__file__).resolve().parents[2]


def _run(command: list[str], *, cwd: Path, label: str) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        errors="replace",
        check=False,
    )
    if result.returncode:
        tail = "\n".join(result.stdout.splitlines()[-100:])
        raise RuntimeError(f"{label} failed with exit {result.returncode}\n{tail}")
    return result.stdout


def _tool(name: str, model_sim_bin: Path | None) -> str:
    suffix = ".exe" if os.name == "nt" else ""
    if model_sim_bin:
        candidate = model_sim_bin / f"{name}{suffix}"
        if candidate.is_file():
            return str(candidate)
    found = shutil.which(f"{name}{suffix}") or shutil.which(name)
    if not found:
        raise RuntimeError(f"cannot find ModelSim tool {name}; use --modelsim-bin")
    return found


def _prepare(manifest_path: Path, manifest: dict[str, object], work: Path) -> dict[str, object]:
    sprite_ram = read_blob(manifest_path, manifest, "sprite_ram")
    sprite_rom = read_blob(manifest_path, manifest, "sprite_rom")
    back_fb = read_blob(manifest_path, manifest, "back_fb")
    width = int(manifest.get("width", 416 if manifest["controls"][6] & 1 else 320))
    control2 = int(manifest.get("latched_controls", manifest["controls"])[2])
    rtl_back_fb = rtl_storage_initial(back_fb, width, control2)
    sram_hex = work / "sprite_ram.hex"
    rom_hex = work / "sprite_rom.hex"
    back_hex = work / "back.hex"
    write_u16le_hex(sprite_ram, sram_hex)
    chunks = write_rom128_hex(sprite_rom, rom_hex)
    write_u16le_hex(rtl_back_fb, back_hex)
    return {
        "sprite_ram": sprite_ram,
        "sprite_rom": sprite_rom,
        "sram_hex": sram_hex,
        "rom_hex": rom_hex,
        "back_hex": back_hex,
        "rom_chunks": chunks,
    }


def _run_oracle(manifest_path: Path, output: Path) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable,
        "-m",
        "verif.reference.s32_sprite_ref",
        "render",
        str(manifest_path),
        "--output-dir",
        str(output),
    ]
    text = _run(command, cwd=REPO_ROOT, label="sprite oracle")
    expected = output / "back.fb16le"
    if not expected.is_file():
        raise RuntimeError(f"oracle did not produce {expected}\n{text[-4000:]}")
    return expected


def _run_modelsim(
    manifest: dict[str, object],
    prepared: dict[str, object],
    work: Path,
    *,
    model_sim_bin: Path | None,
    max_cycles: int,
    seed: int,
    rom_stall: int,
    fb_stall: bool,
) -> tuple[bytes, str]:
    vlib = _tool("vlib", model_sim_bin)
    vlog = _tool("vlog", model_sim_bin)
    vsim = _tool("vsim", model_sim_bin)
    library = work / "modelsim_work"
    _run([vlib, str(library)], cwd=work, label="vlib sprite replay")
    _run(
        [
            vlog,
            "-sv",
            "-work",
            str(library),
            str(REPO_ROOT / "rtl/video/s32_sprite.sv"),
            str(REPO_ROOT / "verif/sprite_replay/tb_sprite_replay.sv"),
        ],
        cwd=work,
        label="vlog sprite replay",
    )
    out_hex = work / "rtl_back.hex"
    sim_log = work / "vsim.log"
    controls = manifest["controls"]
    bank_count = len(prepared["sprite_rom"]) // 0x400000
    if bank_count not in (1, 2, 4):
        raise RuntimeError(
            f"RTL bank-mask replay requires 1, 2, or 4 banks; got {bank_count}"
        )
    bank_mask = bank_count - 1
    args = [
        vsim,
        "-c",
        "-lib",
        str(library),
        "-l",
        str(sim_log),
        "tb_sprite_replay",
        f"+SPRRAM={prepared['sram_hex']}",
        f"+SROM={prepared['rom_hex']}",
        f"+BACK={prepared['back_hex']}",
        f"+OUT={out_hex}",
        f"+ROMCHUNKS={prepared['rom_chunks']}",
        f"+MAXCYCLES={max_cycles}",
        f"+SEED={seed & 0x7fffffff}",
        f"+ROMSTALL={rom_stall}",
        f"+FBSTALL={1 if fb_stall else 0}",
        f"+SBM={bank_mask:x}",
    ]
    args.extend(f"+C{index}={value:02x}" for index, value in enumerate(controls))
    args.extend(("-do", "run -all; quit -f"))
    transcript = _run(args, cwd=work, label="vsim sprite replay")
    if "SPRITE REPLAY RTL PASS" not in transcript:
        tail = "\n".join(transcript.splitlines()[-120:])
        raise RuntimeError(f"RTL replay did not pass protocol/liveness assertions\n{tail}")
    actual = read_u16_hex(out_hex, FB_PIXELS)
    return actual, transcript


def run_fixture(
    manifest_file: Path,
    *,
    work: Path,
    model_sim_bin: Path | None,
    expected: Path | None,
    run_oracle: bool,
    max_cycles: int,
    seed: int,
    rom_stall: int,
    fb_stall: bool,
) -> dict[str, object]:
    manifest_path, manifest = load_manifest(manifest_file)
    if manifest.get("event", "render") != "render":
        raise RuntimeError("RTL differential runner currently accepts direct render events only")
    if manifest.get("latched_controls", manifest["controls"]) != manifest["controls"]:
        raise RuntimeError("direct RTL replay requires live and latched controls to match")
    work.mkdir(parents=True, exist_ok=True)
    prepared = _prepare(manifest_path, manifest, work)
    if expected is None:
        oracle_output = work / "oracle"
        candidate = oracle_output / "back.fb16le"
        if run_oracle or not candidate.is_file():
            expected = _run_oracle(manifest_path, oracle_output)
        else:
            expected = candidate
    expected_blob = expected.read_bytes()
    actual_blob, transcript = _run_modelsim(
        manifest,
        prepared,
        work,
        model_sim_bin=model_sim_bin,
        max_cycles=max_cycles,
        seed=seed,
        rom_stall=rom_stall,
        fb_stall=fb_stall,
    )
    (work / "rtl_back.fb16le").write_bytes(actual_blob)
    width = int(manifest.get("width", 416 if manifest["controls"][6] & 1 else 320))
    control2 = int(manifest["latched_controls"][2])
    expected_visible = active_scanout(expected_blob, width, control2)
    actual_visible = active_crop(actual_blob, width)
    (work / "expected_visible.fb16le").write_bytes(expected_visible)
    (work / "rtl_visible.fb16le").write_bytes(actual_visible)
    visible_comparison = compare_u16(expected_visible, actual_visible, width, 224)
    physical_comparison = compare(expected_blob, actual_blob)
    # RTL mirrors write coordinates because its scanout is sequential. MAME
    # keeps physical storage unflipped and applies ctl2 during scanout.
    match = bool(
        visible_comparison["match"]
        and ((control2 & 3) != 0 or physical_comparison["match"])
    )
    bank_audit = audit_descriptors(
        prepared["sprite_ram"], len(prepared["sprite_rom"]), is_multi32=False
    )
    result: dict[str, object] = {
        "manifest": str(manifest_path),
        "match": match,
        "comparison_visible": visible_comparison,
        "comparison_physical": physical_comparison,
        "physical_match_required": (control2 & 3) == 0,
        "global_flip_storage_adapter": control2 & 3,
        "descriptor_bank_audit": bank_audit,
        "expected_path": str(expected),
        "rtl_path": str(work / "rtl_back.fb16le"),
        "rtl_transcript_sha256": sha256_file(work / "vsim.log") if (work / "vsim.log").exists() else None,
        "rtl_summary": next(
            (line.strip() for line in transcript.splitlines() if "SPRITE REPLAY RTL PASS" in line),
            None,
        ),
    }
    write_json(work / "replay_result.json", result)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--modelsim-bin", type=Path)
    parser.add_argument("--expected", type=Path)
    parser.add_argument("--no-oracle", action="store_true")
    parser.add_argument("--max-cycles", type=int, default=50_000_000)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x5386A)
    parser.add_argument("--rom-stall", type=int, choices=range(0, 256), default=7)
    parser.add_argument("--no-fb-stall", action="store_true")
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args(argv)

    temporary = None
    if args.work_dir is None:
        temporary = tempfile.TemporaryDirectory(prefix="s32-sprite-replay-")
        work = Path(temporary.name)
    else:
        work = args.work_dir.resolve()
    try:
        result = run_fixture(
            args.manifest,
            work=work,
            model_sim_bin=args.modelsim_bin,
            expected=args.expected,
            run_oracle=not args.no_oracle,
            max_cycles=args.max_cycles,
            seed=args.seed,
            rom_stall=args.rom_stall,
            fb_stall=not args.no_fb_stall,
        )
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"SPRITE REPLAY: FAIL: {exc}", file=sys.stderr)
        if temporary and args.keep_work:
            print(f"work directory retained only when --work-dir is explicit: {work}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    print("SPRITE REPLAY: PASS" if result["match"] else "SPRITE REPLAY: PIXEL MISMATCH")
    if temporary:
        temporary.cleanup()
    return 0 if result["match"] else 2


if __name__ == "__main__":
    sys.exit(main())
