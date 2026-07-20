"""Bounded, non-rendering audit of System 32 sprite-list bank usage."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

from .format import SPRITE_RAM_BYTES


def _words(blob: bytes) -> list[int]:
    if len(blob) != SPRITE_RAM_BYTES:
        raise ValueError(f"sprite RAM must be {SPRITE_RAM_BYTES} bytes")
    return [int.from_bytes(blob[index:index + 2], "little") for index in range(0, len(blob), 2)]


def audit(sprite_ram: bytes, sprite_rom_size: int, *, is_multi32: bool = False) -> dict[str, object]:
    if sprite_rom_size <= 0 or sprite_rom_size % 0x400000:
        raise ValueError("logical sprite ROM size must be a multiple of 4 MiB")
    bank_count = sprite_rom_size // 0x400000
    ram = _words(sprite_ram)
    index = 0
    commands = Counter()
    raw_banks = Counter()
    effective_banks = Counter()
    first_draws: list[dict[str, int]] = []
    terminated = "limit"
    for ordinal in range(8192):
        base = (index & 0x1FFF) * 8
        descriptor = ram[base:base + 8]
        command = descriptor[0] >> 14
        if command == 3:
            commands["end"] += 1
            terminated = "end"
            break
        if command == 2:
            commands["jump"] += 1
            index = descriptor[0] & 0x1FFF
            continue
        if command == 1:
            commands["clip"] += 1
            index = (index + 1) & 0x1FFF
            continue

        commands["draw"] += 1
        word3 = descriptor[3]
        if is_multi32:
            raw_bank = ((word3 & 0x2000) >> 13) | ((word3 & 0x8000) >> 14)
        else:
            raw_bank = ((word3 & 0x0800) >> 11) | ((word3 & 0x4000) >> 13)
        effective = raw_bank % bank_count
        raw_banks[raw_bank] += 1
        effective_banks[effective] += 1
        if len(first_draws) < 32:
            first_draws.append(
                {
                    "ordinal": ordinal,
                    "entry": index & 0x1FFF,
                    "raw_bank": raw_bank,
                    "effective_bank": effective,
                    "from_ram": int(bool(descriptor[0] & 0x0400)),
                    "address": descriptor[6] | ((descriptor[2] & 0xF000) << 4),
                }
            )
        inline_entries = 2 if descriptor[0] & 0x3000 == 0x3000 else 0
        index = (index + 1 + inline_entries) & 0x1FFF
    return {
        "logical_sprite_rom_bytes": sprite_rom_size,
        "bank_bytes": 0x400000,
        "bank_count": bank_count,
        "commands": dict(sorted(commands.items())),
        "raw_bank_histogram": {str(key): value for key, value in sorted(raw_banks.items())},
        "effective_bank_histogram": {
            str(key): value for key, value in sorted(effective_banks.items())
        },
        "uses_bank_modulo": any(raw >= bank_count for raw in raw_banks),
        "first_draws": first_draws,
        "termination": terminated,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sprite_ram", type=Path)
    parser.add_argument("--sprite-rom-size", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--multi32", action="store_true")
    parser.add_argument("--json", dest="json_path", type=Path)
    args = parser.parse_args(argv)
    try:
        result = audit(args.sprite_ram.read_bytes(), args.sprite_rom_size, is_multi32=args.multi32)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    text = json.dumps(result, indent=2, sort_keys=True)
    print(text)
    if args.json_path:
        args.json_path.write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
