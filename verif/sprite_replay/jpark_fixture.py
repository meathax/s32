"""Build a local Jurassic Park sprite-replay fixture from MAME/Verilator hex.

The generated fixture contains copyrighted ROM bytes and must remain under a
caller-selected scratch directory; only this converter belongs in the repo.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .format import FB_PIXELS, read_u16_hex


def rom128_hex_to_bytes(path: Path) -> bytes:
    output = bytearray()
    for lineno, text in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        text = text.strip()
        if not text or text.startswith("//"):
            continue
        try:
            value = int(text, 16)
        except ValueError as exc:
            raise ValueError(f"invalid ROM chunk at {path}:{lineno}") from exc
        if value.bit_length() > 128:
            raise ValueError(f"wide ROM chunk at {path}:{lineno}")
        output.extend(value.to_bytes(16, "little"))
    return bytes(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sprite_ram_hex", type=Path)
    parser.add_argument("sprite_rom_hex", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    sprite_ram = read_u16_hex(args.sprite_ram_hex, 65536)
    sprite_rom = rom128_hex_to_bytes(args.sprite_rom_hex)
    if len(sprite_rom) != 0x1000000:
        parser.error(
            f"Jurassic Park sprite ROM must be 16 MiB, got {len(sprite_rom)} bytes"
        )

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "sprite_ram.bin").write_bytes(sprite_ram)
    (output / "sprite_rom.bin").write_bytes(sprite_rom)
    (output / "back.fb16le").write_bytes(b"\xff\xff" * FB_PIXELS)
    manifest = {
        "schema": "s32.sprite.v1",
        "name": "jpark_mame_visible_gameplay",
        "event": "render",
        "width": 320,
        "controls": [0, 0, 0, 0, 0, 3, 0, 0],
        "latched_controls": [0, 0, 0, 0, 0, 3, 0, 0],
        "sprite_ram": {
            "path": "sprite_ram.bin",
            "format": "u16le",
            "size": len(sprite_ram),
        },
        "sprite_rom": {
            "path": "sprite_rom.bin",
            "format": "mame-region-bytes",
            "size": len(sprite_rom),
        },
        "back_fb": {
            "path": "back.fb16le",
            "format": "u16le",
            "width": 416,
            "height": 224,
        },
        "metadata": {
            "source": "MAME jpark frame 193 after scripted coin/start",
            "copyrighted_fixture": True,
        },
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(output / "manifest.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
