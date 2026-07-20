from __future__ import annotations

import argparse
import random
from pathlib import Path

from verif.reference.s32_mixer_ref import mix_pixel


VECTOR_BITS = 1179


def palette(index: int) -> int:
    value = ((index * 0x1F35) ^ (index << 7) ^ (index >> 3))
    return value & 0x7FFF


def _pack(parts: list[tuple[int, int]]) -> int:
    packed = 0
    width = 0
    for value, bits in parts:
        if value < 0 or value >= 1 << bits:
            raise ValueError(f"value {value:#x} does not fit {bits} bits")
        packed = (packed << bits) | value
        width += bits
    if width != VECTOR_BITS:
        raise AssertionError(f"packed {width} bits, expected {VECTOR_BITS}")
    return packed


def generate(seed: int, count: int) -> list[int]:
    rng = random.Random(seed)
    vectors: list[int] = []
    for _ in range(count):
        regs = [rng.getrandbits(16) for _ in range(64)]
        pixels = []
        for _layer in range(6):
            pixel = rng.getrandbits(13)
            if rng.randrange(4) != 0:
                pixel |= 0x2000
            pixels.append(pixel)
        sprite = rng.getrandbits(16)
        layer_off = rng.getrandbits(6)
        bg_ctrl = rng.getrandbits(16)
        y = rng.randrange(224)
        expected = mix_pixel(
            regs, pixels, sprite, layer_off, bg_ctrl, y, palette
        ).rgb
        parts = [
            (expected, 24), (layer_off, 6), (bg_ctrl, 16), (y, 9),
            (sprite, 16),
            *((pixel, 14) for pixel in pixels),
            *((reg, 16) for reg in regs),
        ]
        vectors.append(_pack(parts))
    return vectors


def write_vectors(path: Path, seed: int, count: int) -> None:
    digits = (VECTOR_BITS + 3) // 4
    path.write_text(
        "".join(f"{vector:0{digits}x}\n" for vector in generate(seed, count)),
        encoding="ascii",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=5387)
    parser.add_argument("--count", type=int, default=512)
    args = parser.parse_args()
    write_vectors(args.output, args.seed, args.count)


if __name__ == "__main__":
    main()
