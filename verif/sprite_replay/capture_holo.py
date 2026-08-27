"""Capture deterministic Holosseum sprite states from the full-core harness."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from .descriptor_audit import audit as audit_descriptors
from .format import (
    FB_HEIGHT,
    FB_PIXELS,
    FB_WIDTH,
    SCHEMA,
    SPRITE_RAM_WORDS,
    read_u16_hex,
    write_json,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
HOLO_LOGICAL_SPRITE_BYTES = 0x800000


def _run(
    command: list[str],
    cwd: Path,
    label: str,
    *,
    progress_markers: tuple[str, ...] = (),
) -> str:
    if progress_markers:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            errors="replace",
            bufsize=1,
        )
        assert process.stdout is not None
        lines: list[str] = []
        for line in process.stdout:
            lines.append(line)
            if any(marker in line for marker in progress_markers):
                print(line.rstrip(), flush=True)
        returncode = process.wait()
        output = "".join(lines)
        if returncode:
            raise RuntimeError(
                f"{label} failed with exit {returncode}\n" +
                "\n".join(output.splitlines()[-120:])
            )
        return output
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
        raise RuntimeError(
            f"{label} failed with exit {result.returncode}\n" +
            "\n".join(result.stdout.splitlines()[-120:])
        )
    return result.stdout


def _tool(name: str, tool_dir: Path | None) -> str:
    suffix = ".exe" if os.name == "nt" else ""
    if tool_dir:
        candidate = tool_dir / f"{name}{suffix}"
        if candidate.is_file():
            return str(candidate)
    found = shutil.which(f"{name}{suffix}") or shutil.which(name)
    if not found:
        raise RuntimeError(f"cannot find {name}; pass --modelsim-bin")
    return found


def _sprite_hex_to_trimmed_bin(source: Path, output: Path, logical_size: int) -> dict[str, int]:
    logical_chunks = logical_size // 16
    total_chunks = 0
    non_ff_padding = 0
    with source.open("r", encoding="ascii") as src, output.open("wb") as dst:
        for lineno, line in enumerate(src, 1):
            text = line.strip()
            if not text:
                continue
            try:
                value = int(text, 16)
            except ValueError as exc:
                raise ValueError(f"invalid sprites.hex line {lineno}") from exc
            if value.bit_length() > 128:
                raise ValueError(f"wide sprites.hex line {lineno}")
            chunk = value.to_bytes(16, "little")
            if total_chunks < logical_chunks:
                dst.write(chunk)
            elif chunk != b"\xff" * 16:
                non_ff_padding += 1
            total_chunks += 1
    if total_chunks < logical_chunks:
        raise ValueError(f"sprites.hex has only {total_chunks * 16:#x} bytes")
    if non_ff_padding:
        raise ValueError(
            f"refusing to trim Holo image: {non_ff_padding} upper padding chunks are not FF"
        )
    return {
        "input_bytes": total_chunks * 16,
        "logical_bytes": logical_size,
        "trimmed_padding_bytes": total_chunks * 16 - logical_size,
    }


def _read_byte_hex(path: Path) -> list[int]:
    values = [int(line.strip(), 16) for line in path.read_text(encoding="ascii").splitlines() if line.strip()]
    if len(values) != 8 or any(not 0 <= value <= 0xFF for value in values):
        raise ValueError(f"{path} must contain eight byte values")
    return values


def _read_meta(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def _controller_command(controls: list[int], render_count: int) -> tuple[bool, int]:
    """Return (manual_mode, command) for the upcoming controller callback."""
    if len(controls) != 8:
        raise ValueError("sprite controls must contain eight bytes")
    if render_count not in (0, 1):
        raise ValueError(f"invalid captured render_count {render_count}")
    manual = bool(controls[3] & 2)
    return manual, controls[0] if manual else (3 if render_count == 0 else 0)


def _postprocess(output: Path, frames: list[int], rom_info: dict[str, int]) -> list[Path]:
    manifests: list[Path] = []
    for frame in frames:
        directory = output / f"frame_{frame}"
        controls = _read_byte_hex(directory / "controls.hex")
        previous_latched = _read_byte_hex(directory / "previous_latched_controls.hex")
        sprite_ram = read_u16_hex(directory / "sprite_ram.hex", SPRITE_RAM_WORDS)
        pre_erase_target = read_u16_hex(directory / "pre_erase_target.hex", FB_PIXELS)
        front_fb = read_u16_hex(directory / "front.hex", FB_PIXELS)
        (directory / "sprite_ram.bin").write_bytes(sprite_ram)
        (directory / "pre_erase_target.fb16le").write_bytes(pre_erase_target)
        (directory / "front.fb16le").write_bytes(front_fb)
        bank_audit = audit_descriptors(sprite_ram, HOLO_LOGICAL_SPRITE_BYTES)
        write_json(directory / "descriptor_bank_audit.json", bank_audit)
        meta = _read_meta(directory / "capture_meta.txt")
        width = 416 if controls[6] & 1 else 320
        if int(meta.get("sprite_control_width", width)) != width:
            raise ValueError(
                f"frame {frame}: captured sprite width disagrees with control register 6"
            )
        render_count = int(meta.get("render_count", "0"))
        manual, command = _controller_command(controls, render_count)
        if not command & 1:
            # This vblank callback does not swap/render.  Keep the raw capture
            # and audit as provenance, but do not invent a direct-render event.
            write_json(
                directory / "capture_status.json",
                {
                    "frame": frame,
                    "manual_mode": manual,
                    "command": command,
                    "render_count": render_count,
                    "render_event": False,
                    "descriptor_bank_audit": bank_audit,
                },
            )
            continue
        erased_before_render = bool(command & 2)
        back_fb = (
            b"\xff\xff" * FB_PIXELS
            if erased_before_render
            else pre_erase_target
        )
        (directory / "back.fb16le").write_bytes(back_fb)
        replay_controls = list(controls)
        # The direct RTL runner adds a deterministic render command.  Erase,
        # if requested by the captured callback, is already reflected in the
        # selected initial target above and must not execute a second time.
        replay_controls[0] = 0
        manifest = {
            "schema": SCHEMA,
            "name": f"holo_full_core_frame_{frame}",
            "width": width,
            "controls": replay_controls,
            # This event represents the upcoming swap: MAME latches live
            # controls at that point, so previous_latched is provenance only.
            "latched_controls": replay_controls,
            "sprite_ram": {"path": "sprite_ram.bin", "format": "u16le", "size": len(sprite_ram)},
            "sprite_rom": {
                "path": "../sprite_rom.bin",
                "format": "mame-region-bytes",
                "size": HOLO_LOGICAL_SPRITE_BYTES,
            },
            "front_fb": {"path": "front.fb16le", "format": "u16le", "width": FB_WIDTH, "height": FB_HEIGHT},
            "back_fb": {"path": "back.fb16le", "format": "u16le", "width": FB_WIDTH, "height": FB_HEIGHT},
            "event": "render",
            "metadata": {
                "source": "tb_core_romboot real Holo ROM state",
                "capture_frame": frame,
                "capture_edge": "first clk_ram negedge with vblank_end asserted",
                "previous_latched_controls": previous_latched,
                "sprite_rom_conversion": rom_info,
                "sprite_bank_mask": 1,
                "bank_count": 2,
                "descriptor_bank_audit": bank_audit,
                "captured_live_controls": controls,
                "controller_mode": "manual" if manual else "automatic",
                "captured_command": command,
                "captured_render_count": render_count,
                "erased_before_render": erased_before_render,
                "controller_event": (
                    "erase-current-front, swap, render-erased-old-front"
                    if erased_before_render
                    else "swap, render-preserved-old-front"
                ),
                "pre_erase_target_path": "pre_erase_target.fb16le",
                **meta,
            },
        }
        manifest_path = directory / "manifest.json"
        write_json(manifest_path, manifest)
        manifests.append(manifest_path)
    return manifests


def capture(
    *,
    image_dir: Path,
    output: Path,
    frames: list[int],
    model_sim_bin: Path | None,
    keep_work: bool,
    real_z80: bool = False,
) -> list[Path]:
    if not frames or frames != list(range(frames[0], frames[-1] + 1)):
        raise ValueError("frames must be a non-empty contiguous ascending range")
    for name in ("maincpu.hex", "soundcpu.hex", "tiles.hex", "sprites.hex"):
        if not (image_dir / name).is_file():
            raise ValueError(f"missing Holo simulation image {image_dir / name}")
    output.mkdir(parents=True, exist_ok=True)
    for frame in frames:
        (output / f"frame_{frame}").mkdir(parents=True, exist_ok=True)
    rom_info = _sprite_hex_to_trimmed_bin(
        image_dir / "sprites.hex", output / "sprite_rom.bin", HOLO_LOGICAL_SPRITE_BYTES
    )

    temporary = tempfile.TemporaryDirectory(prefix="s32-holo-capture-")
    work = Path(temporary.name)
    library = work / "work"
    vlib = _tool("vlib", model_sim_bin)
    vlog = _tool("vlog", model_sim_bin)
    vsim = _tool("vsim", model_sim_bin)
    _run([vlib, str(library)], work, "vlib Holo capture")
    if real_z80:
        vcom = _tool("vcom", model_sim_bin)
        t80_sources = [
            REPO_ROOT / "rtl/audio/T80/T80_ALU.vhd",
            REPO_ROOT / "rtl/audio/T80/T80_MCode.vhd",
            REPO_ROOT / "rtl/audio/T80/T80_Reg.vhd",
            REPO_ROOT / "rtl/audio/T80/T80.vhd",
            REPO_ROOT / "rtl/audio/T80/T80s.vhd",
        ]
        _run(
            [vcom, "-2008", "-work", str(library), *map(str, t80_sources)],
            work,
            "vcom production T80",
        )
    video_sources = sorted((REPO_ROOT / "rtl/video").glob("*.sv"))
    sources = [
        REPO_ROOT / "rtl/s32_pkg.sv",
        REPO_ROOT / "rtl/cpu/v60/s32_v60.sv",
        REPO_ROOT / "rtl/cpu/v60/s32_v60_bus.sv",
        *video_sources,
        REPO_ROOT / "rtl/audio/s32_rf5c68.sv",
        REPO_ROOT / "rtl/audio/s32_multipcm.sv",
        REPO_ROOT / "rtl/audio/s32_audio_mix.sv",
        REPO_ROOT / "rtl/audio/s32_soundsys.sv",
        REPO_ROOT / "rtl/io/s32_io.sv",
        REPO_ROOT / "rtl/prot/s32_prot.sv",
        REPO_ROOT / "verif/common/jt12_stub.v",
        REPO_ROOT / "rtl/s32_core.sv",
        REPO_ROOT / "verif/common/tb_core_romboot.sv",
        REPO_ROOT / "verif/sprite_replay/tb_holo_sprite_capture.sv",
    ]
    _run(
        [
            vlog,
            "-sv",
            "+define+SIMULATION",
            *(["+define+S32_REAL_Z80_SIM"] if real_z80 else []),
            "-work",
            str(library),
            *map(str, sources),
        ],
        work,
        "vlog Holo capture",
    )
    transcript = _run(
        [
            vsim,
            "-c",
            # Preserve hierarchical capture visibility while allowing vopt;
            # full -novopt simulation is several times slower per Holo frame.
            "-voptargs=+acc",
            "-lib",
            str(library),
            "tb_holo_sprite_capture",
            f"+IMG={image_dir.resolve()}",
            "+B0=0",
            "+B1=2",
            "+SBM=1",
            f"+FRAMES={frames[-1] + 1}",
            f"+CAPROOT={output.resolve()}",
            f"+CAPFIRST={frames[0]}",
            f"+CAPLAST={frames[-1]}",
            "+CAPSTOP=1",
            "-do",
            "run -all; quit -f",
        ],
        work,
        "vsim Holo capture",
        progress_markers=("# frame ", "# HOLO SPRITE CAPTURE"),
    )
    if "HOLO SPRITE CAPTURE PASS" not in transcript:
        raise RuntimeError("Holo capture did not emit its completion marker")
    (output / "capture.log").write_text(transcript, encoding="utf-8")
    (output / "sound_cpu_mode.txt").write_text(
        ("production T80\n" if real_z80 else "simulation stub\n"),
        encoding="utf-8",
    )
    manifests = _postprocess(output, frames, rom_info)
    if keep_work:
        retained = output / "modelsim_work_path.txt"
        retained.write_text(str(work) + "\n", encoding="utf-8")
        # TemporaryDirectory cannot be transferred safely; retain meaningful
        # logs and generated capture artifacts instead of the compiled library.
    temporary.cleanup()
    return manifests


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image-dir", type=Path, default=REPO_ROOT / "roms/sim/holo")
    parser.add_argument("--output", type=Path, default=REPO_ROOT / "roms/sprite_replay/holo")
    parser.add_argument("--first-frame", type=int, default=1)
    parser.add_argument("--last-frame", type=int, default=3)
    parser.add_argument("--modelsim-bin", type=Path)
    parser.add_argument("--keep-work", action="store_true")
    parser.add_argument(
        "--real-z80",
        action="store_true",
        help="compile the production mixed-language T80 for full-core audio traffic",
    )
    args = parser.parse_args(argv)
    frames = list(range(args.first_frame, args.last_frame + 1))
    try:
        manifests = capture(
            image_dir=args.image_dir.resolve(),
            output=args.output.resolve(),
            frames=frames,
            model_sim_bin=args.modelsim_bin,
            keep_work=args.keep_work,
            real_z80=args.real_z80,
        )
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"HOLO SPRITE CAPTURE: FAIL: {exc}", file=sys.stderr)
        return 1
    print(json.dumps([str(path) for path in manifests], indent=2))
    print("HOLO SPRITE CAPTURE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
