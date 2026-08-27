"""Generate deterministic constrained-random 315-5386A replay fixtures.

This generator only creates inputs.  Expected pixels always come from the
independent MAME-derived oracle in ``verif.reference``.
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

from .format import (
    FB_HEIGHT,
    FB_PIXELS,
    FB_WIDTH,
    SCHEMA,
    SPRITE_RAM_WORDS,
    words_to_blob,
    write_json,
)


def _s12(value: int) -> int:
    if not -2048 <= value <= 2047:
        raise ValueError(f"signed 12-bit value out of range: {value}")
    return value & 0xFFF


def _put_entry(words: list[int], entry: int, data: list[int]) -> None:
    if len(data) != 8 or not 0 <= entry < 0x2000:
        raise ValueError("sprite entry must be eight words at index 0..8191")
    base = entry * 8
    words[base:base + 8] = [value & 0xFFFF for value in data]


def _initial_sprite_ram(rng: random.Random) -> list[int]:
    # Random payload catches from-RAM byte-order bugs.  Every entry initially
    # decodes as END so a generator error cannot walk arbitrary payload.
    words = [rng.getrandbits(16) for _ in range(SPRITE_RAM_WORDS)]
    for entry in range(0x2000):
        words[entry * 8] = 0xC000
    return words


def _initial_fb(rng: random.Random) -> bytes:
    # Nontrivial high-bit-set pixels make shadow RMW and untouched-pixel
    # preservation observable.  Include erased pixels at a regular cadence.
    pixels = []
    for index in range(FB_PIXELS):
        pixels.append(0xFFFF if index % 31 == 0 else 0x8000 | rng.getrandbits(15))
    return words_to_blob(pixels)


def generate_case(
    output_dir: Path,
    *,
    seed: int,
    command_count: int,
    width: int,
    rom_size: int,
    global_flip: int = 0,
) -> Path:
    if not 0 <= command_count <= 1024:
        raise ValueError("command_count must be in 0..1024")
    if width not in (320, 416):
        raise ValueError("width must be 320 or 416")
    if rom_size < 0x400000 or rom_size % 0x400000:
        raise ValueError("rom_size must be a positive multiple of 4 MiB")
    if global_flip not in (0, 1, 2, 3):
        raise ValueError("global_flip must be 0..3")

    rng = random.Random(seed)
    output_dir.mkdir(parents=True, exist_ok=True)
    words = _initial_sprite_ram(rng)
    features: set[str] = set()
    cursor = 0

    # Exercise both independent clip rectangles before drawing.  Values are
    # deliberately inside the active screen so exclusion is visible.
    clip_r = width - 7
    _put_entry(
        words,
        cursor,
        [0x4000 | 0x1000 | 0x2000 | _s12(2), _s12(221), _s12(3), _s12(width - 4),
         _s12(70), _s12(100), _s12(width // 3), _s12(width // 3 + 7)],
    )
    cursor += 1
    features.update(("clip-in", "clip-out"))

    # A non-looping jump proves target decode and signed global offsets.
    jump_target = cursor + 1
    _put_entry(words, cursor, [0x8000 | 0x2000 | jump_target, _s12(-5), _s12(9), 0, 0, 0, 0, 0])
    cursor = jump_target
    features.add("jump-offset")

    external_table_entry = 0x1F00
    for table_index in range(16):
        words[external_table_entry * 8 + table_index] = (
            0x7FFF if table_index == 0 else rng.getrandbits(15)
        )

    generated = 0
    while generated < command_count:
        if cursor >= 0x1E00:
            raise ValueError("command list overflowed the reserved test area")
        flavor = generated % 8
        bpp8 = flavor in (1, 3) or (flavor >= 6 and bool(rng.getrandbits(1)))
        indirect = flavor in (2, 3) or (flavor >= 6 and rng.randrange(5) == 0)
        inline = indirect and (flavor == 2 or bool(rng.getrandbits(1)))
        shadow = flavor == 4 or (flavor >= 6 and rng.randrange(7) == 0)
        fromram = flavor == 5 or (flavor >= 6 and rng.randrange(9) == 0)
        opaque = flavor == 7 or (flavor >= 6 and bool(rng.getrandbits(1)))
        flipx = bool(rng.getrandbits(1))
        flipy = bool(rng.getrandbits(1))
        apply_offsets = generated % 3 == 0

        srcw = rng.randint(1, 4)
        srch = rng.randint(1, 8)
        dstw = rng.randint(1, 64)
        dsth = rng.randint(1, 48)
        xpos = rng.randint(-40, width + 24)
        ypos = rng.randint(-24, FB_HEIGHT + 12)
        address = rng.randrange(0x10000) if fromram else rng.randrange(0x100000)

        word0 = 0
        word0 |= 0x2000 if indirect else 0
        word0 |= 0x1000 if inline else 0
        word0 |= 0x0800 if shadow else 0
        word0 |= 0x0400 if fromram else 0
        word0 |= 0x0200 if bpp8 else 0
        word0 |= 0x0100 if opaque else 0
        word0 |= 0x0080 if flipy else 0
        word0 |= 0x0040 if flipx else 0
        word0 |= 0x0030 if apply_offsets else 0
        word0 |= rng.randrange(4) << 2  # Y anchor
        word0 |= rng.randrange(4)       # X anchor
        word1 = (srch << 8) | (srcw if bpp8 else srcw << 1)
        word2 = ((address >> 16) << 12) | dsth
        raw_bank = rng.randrange(4)
        # System 32 bank bits are descriptor +6 bits 11 and 14. Emit every raw
        # value so smaller logical regions exercise MAME-compatible modulo.
        word3 = dstw | ((raw_bank & 1) << 11) | ((raw_bank & 2) << 13)
        word7 = rng.randrange(0x8000) & (0x7F00 if bpp8 else 0x7FF0)
        if indirect and not inline:
            word7 = (word7 & 0xE000) | external_table_entry
        _put_entry(
            words,
            cursor,
            [word0, word1, word2, word3, _s12(ypos), _s12(xpos), address, word7],
        )
        cursor += 1
        if inline:
            for table_index in range(16):
                words[cursor * 8 + table_index] = (
                    0x7FFF if table_index == 0 else rng.getrandbits(15)
                )
            cursor += 2

        generated += 1
        features.add("8bpp" if bpp8 else "4bpp")
        features.add("indirect-inline" if indirect and inline else
                     "indirect-external" if indirect else "direct")
        if shadow:
            features.add("shadow")
        if fromram:
            features.add("from-ram")
        if opaque:
            features.add("opaque")
        if flipx or flipy:
            features.add("per-sprite-flip")

    _put_entry(words, cursor, [0xC000, 0, 0, 0, 0, 0, 0, 0])
    features.add("end")

    sprite_ram = words_to_blob(words)
    sprite_rom = rng.randbytes(rom_size)
    back_fb = _initial_fb(rng)
    front_fb = b"\xff\xff" * FB_PIXELS
    (output_dir / "sprite_ram.bin").write_bytes(sprite_ram)
    (output_dir / "sprite_rom.bin").write_bytes(sprite_rom)
    (output_dir / "front.fb16le").write_bytes(front_fb)
    (output_dir / "back.fb16le").write_bytes(back_fb)

    controls = [0] * 8
    controls[2] = global_flip
    controls[3] = 0x02  # manual command mode for deterministic RTL launch
    controls[4] = rng.randrange(4)
    controls[5] = rng.randrange(4) | 1  # enable shadow semantics
    controls[6] = 1 if width == 416 else 0
    manifest = {
        "schema": SCHEMA,
        "name": f"random_seed_{seed}",
        "width": width,
        "controls": controls,
        "latched_controls": controls,
        "sprite_ram": {"path": "sprite_ram.bin", "format": "u16le", "size": len(sprite_ram)},
        "sprite_rom": {"path": "sprite_rom.bin", "format": "mame-region-bytes", "size": len(sprite_rom)},
        "front_fb": {"path": "front.fb16le", "format": "u16le", "width": FB_WIDTH, "height": FB_HEIGHT},
        "back_fb": {"path": "back.fb16le", "format": "u16le", "width": FB_WIDTH, "height": FB_HEIGHT},
        "event": "render",
        "metadata": {
            "generator": "verif.sprite_replay.generate_cases",
            "seed": seed,
            "draw_commands": command_count,
            "logical_sprite_rom_bytes": rom_size,
            "logical_sprite_rom_banks": rom_size // 0x400000,
            "list_entries_through_end": cursor + 1,
            "features": sorted(features),
            "global_flip_storage_adapter": global_flip,
        },
    }
    manifest_path = output_dir / "manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x5386A)
    parser.add_argument("--commands", type=int, default=64)
    parser.add_argument("--width", type=int, choices=(320, 416), default=320)
    parser.add_argument("--rom-size", type=lambda value: int(value, 0), default=0x400000)
    parser.add_argument("--global-flip", type=int, choices=(0, 1, 2, 3), default=0)
    args = parser.parse_args(argv)
    try:
        manifest = generate_case(
            args.output,
            seed=args.seed,
            command_count=args.commands,
            width=args.width,
            rom_size=args.rom_size,
            global_flip=args.global_flip,
        )
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
