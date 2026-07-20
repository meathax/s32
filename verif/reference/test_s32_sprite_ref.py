#!/usr/bin/env python3
"""Synthetic, ROM-free tests for the independent 315-5386A oracle."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from verif.reference.s32_sprite_ref import (
    FRAME_WORDS,
    HEIGHT,
    LIST_ENTRIES,
    ROM_BANK_BYTES,
    SPRITE_RAM_WORDS,
    STORAGE_WIDTH,
    TRANSPARENCY_MASKS,
    MameSpriteRom,
    SparseSpriteRom,
    SpriteReference,
    main,
)


ALIGN_START = 0x000A  # X/Y adjustment 2 = position is the start coordinate.


def blank_ram() -> list[int]:
    return [0] * SPRITE_RAM_WORDS


def put_entry(ram: list[int], number: int, words: list[int]) -> None:
    base = (number & 0x1FFF) * 8
    for index, word in enumerate(words):
        ram[(base + index) & (SPRITE_RAM_WORDS - 1)] = word & 0xFFFF


def put_end(ram: list[int], number: int) -> None:
    put_entry(ram, number, [0xC000])


def descriptor(
    *,
    flags: int = ALIGN_START,
    bpp8: bool = False,
    source_width_words: int = 1,
    source_height: int = 1,
    dest_width: int | None = None,
    dest_height: int | None = None,
    x: int = 0,
    y: int = 0,
    address: int = 0,
    color: int = 0x0120,
    bank: int = 0,
) -> list[int]:
    if dest_width is None:
        dest_width = source_width_words * (4 if bpp8 else 8)
    if dest_height is None:
        dest_height = source_height
    word0 = flags | (0x0200 if bpp8 else 0)
    source_width_field = source_width_words if bpp8 else source_width_words << 1
    word1 = ((source_height & 0xFF) << 8) | (source_width_field & 0xFF)
    word2 = (dest_height & 0x03FF) | ((address >> 4) & 0xF000)
    word3 = dest_width & 0x03FF
    word3 |= (bank & 1) << 11
    word3 |= (bank & 2) << 13
    return [
        word0,
        word1,
        word2,
        word3,
        y & 0x0FFF,
        x & 0x0FFF,
        address & 0xFFFF,
        color & 0xFFFF,
    ]


def make_single(
    desc: list[int],
    rom_words: dict[int | tuple[int, int], int] | None = None,
    *,
    controls: list[int] | None = None,
    latched_controls: list[int] | None = None,
    bank_count: int = 1,
    back_fill: int = 0xFFFF,
    trace_level: str = "none",
) -> SpriteReference:
    ram = blank_ram()
    put_entry(ram, 0, desc)
    put_end(ram, 1)
    ref = SpriteReference(
        sprite_ram=ram,
        sprite_rom=SparseSpriteRom(rom_words, bank_count=bank_count),
        controls=controls,
        latched_controls=latched_controls,
        back_fb=[back_fill] * FRAME_WORDS,
        trace_level=trace_level,
    )
    ref.render_list()
    return ref


def pixel(ref: SpriteReference, x: int, y: int, *, front: bool = False) -> int:
    frame = ref.front_fb if front else ref.back_fb
    return frame[y * STORAGE_WIDTH + x]


class ControlAndListTests(unittest.TestCase):
    def test_erase_then_swap_then_render_order(self) -> None:
        ram = blank_ram()
        put_end(ram, 0)
        ref = SpriteReference(
            sprite_ram=ram,
            front_fb=[0x1111] * FRAME_WORDS,
            back_fb=[0x2222] * FRAME_WORDS,
            controls=[0] * 8,
            latched_controls=[0] * 8,
        )
        self.assertEqual(ref.read_control(0), 0xFD)
        ref.vblank()
        self.assertEqual(ref.front_fb[0], 0x2222)
        self.assertEqual(ref.back_fb[0], 0xFFFF)
        self.assertEqual(ref.selected_buffer, 0)
        self.assertEqual(ref.stats["erase_words"], FRAME_WORDS)
        self.assertEqual(ref.stats["swaps"], 1)
        self.assertEqual(ref.stats["renders"], 1)
        self.assertEqual(ref.controls[0], 0)

    def test_automatic_30hz_cadence(self) -> None:
        ram = blank_ram()
        put_end(ram, 0)
        controls = [0] * 8
        controls[3] = 1
        ref = SpriteReference(sprite_ram=ram, controls=controls)
        ref.vblank()
        self.assertEqual(ref.stats["swaps"], 1)
        ref.vblank()
        self.assertEqual(ref.stats["swaps"], 1)
        ref.vblank()
        self.assertEqual(ref.stats["swaps"], 2)

    def test_manual_pending_command_and_register_latch(self) -> None:
        ram = blank_ram()
        put_end(ram, 0)
        controls = [3, 0, 3, 2, 2, 1, 1, 3]
        ref = SpriteReference(sprite_ram=ram, controls=controls, latched_controls=[0] * 8)
        ref.vblank()
        self.assertEqual(ref.stats["swaps"], 1)
        self.assertEqual(ref.latched_controls, controls)
        self.assertEqual(ref.read_control(0), 0xFC)
        self.assertEqual(ref.read_control(1), 0xFD)
        self.assertEqual(ref.read_control(2), 0xFF)
        self.assertEqual(ref.read_control(3), 0xFE)
        self.assertEqual(ref.read_control(4), 0xFE)
        self.assertEqual(ref.read_control(5), 0xFD)
        self.assertEqual(ref.read_control(6), 0xFD)
        self.assertEqual(ref.read_control(7), 0xFC)
        ref.vblank()
        self.assertEqual(ref.stats["swaps"], 1)

    def test_jump_sets_offsets_and_target(self) -> None:
        ram = blank_ram()
        put_entry(ram, 0, [0xA002, 7, 5])
        put_entry(
            ram,
            2,
            descriptor(flags=ALIGN_START | 0x0030, dest_width=1, x=1, y=1),
        )
        put_end(ram, 3)
        ref = SpriteReference(sprite_ram=ram, sprite_rom=SparseSpriteRom({0: 0x1000000F}))
        self.assertEqual(ref.render_list(), "end")
        self.assertEqual(pixel(ref, 6, 8), 0x8121)
        self.assertEqual(ref.stats["jump_commands"], 1)
        self.assertEqual(ref.stats["commands"], 3)

    def test_jump_loop_is_bounded_at_8192_commands(self) -> None:
        ram = blank_ram()
        put_entry(ram, 0, [0x8000])
        ref = SpriteReference(sprite_ram=ram, trace_level="none")
        self.assertEqual(ref.render_list(), "command-limit")
        self.assertEqual(ref.stats["commands"], LIST_ENTRIES)
        self.assertEqual(ref.stats["jump_commands"], LIST_ENTRIES)

    def test_clip_in_and_clip_out_are_inclusive(self) -> None:
        ram = blank_ram()
        # Inclusive x=2..5/y=0..223, exclusive x=3/y=0..223.
        put_entry(ram, 0, [0x7000, 223, 2, 5, 0, 223, 3, 3])
        put_entry(ram, 1, descriptor(x=0, y=0))
        put_end(ram, 2)
        ref = SpriteReference(
            sprite_ram=ram,
            sprite_rom=SparseSpriteRom({0: 0x1234567F}),
        )
        ref.render_list()
        self.assertEqual(pixel(ref, 1, 0), 0xFFFF)
        self.assertEqual(pixel(ref, 2, 0), 0x8123)
        self.assertEqual(pixel(ref, 3, 0), 0xFFFF)
        self.assertEqual(pixel(ref, 4, 0), 0x8125)
        self.assertEqual(pixel(ref, 5, 0), 0x8126)
        self.assertEqual(pixel(ref, 6, 0), 0xFFFF)

    def test_zero_dimension_inline_palette_still_skips_two_entries(self) -> None:
        ram = blank_ram()
        put_entry(
            ram,
            0,
            descriptor(
                flags=ALIGN_START | 0x3000,
                source_width_words=0,
                source_height=1,
                dest_width=1,
            ),
        )
        put_end(ram, 3)
        ref = SpriteReference(sprite_ram=ram)
        self.assertEqual(ref.render_list(), "end")
        self.assertEqual(ref.stats["commands"], 2)
        self.assertEqual(ref.stats["skipped_draws"], 1)


class PixelFormatTests(unittest.TestCase):
    def test_direct_4bpp_and_normal_end_code(self) -> None:
        ref = make_single(descriptor(), {0: 0x1234567F})
        self.assertEqual(
            [pixel(ref, x, 0) for x in range(8)],
            [0x8121, 0x8122, 0x8123, 0x8124, 0x8125, 0x8126, 0x8127, 0xFFFF],
        )

    def test_end_code_only_terminates_on_low_edge_pixel(self) -> None:
        desc = descriptor(source_width_words=2, dest_width=16)
        ref = make_single(desc, {0: 0xF1F2345F, 1: 0x6666666F})
        self.assertEqual(pixel(ref, 0, 0), 0xFFFF)
        self.assertEqual(pixel(ref, 1, 0), 0x8121)
        self.assertEqual(pixel(ref, 2, 0), 0x812F)
        self.assertEqual(pixel(ref, 7, 0), 0xFFFF)
        self.assertTrue(all(pixel(ref, x, 0) == 0xFFFF for x in range(8, 16)))
        self.assertEqual(ref.stats["rom_fetches"], 1)

    def test_opaque_mode_disables_end_code_but_zero_remains_empty(self) -> None:
        desc = descriptor(flags=ALIGN_START | 0x0100, source_width_words=2, dest_width=16)
        ref = make_single(desc, {0: 0xF102030F, 1: 0x456789AB})
        self.assertEqual(pixel(ref, 0, 0), 0x812F)
        self.assertEqual(pixel(ref, 2, 0), 0xFFFF)
        self.assertEqual(pixel(ref, 7, 0), 0x812F)
        self.assertEqual(pixel(ref, 8, 0), 0x8124)
        self.assertEqual(ref.stats["rom_fetches"], 2)

    def test_direct_8bpp(self) -> None:
        desc = descriptor(bpp8=True, color=0x2300)
        ref = make_single(desc, {0: 0x112233FF})
        self.assertEqual(
            [pixel(ref, x, 0) for x in range(4)],
            [0xA311, 0xA322, 0xA333, 0xFFFF],
        )

    def test_from_sprite_ram_repacking(self) -> None:
        ram = blank_ram()
        source_address = 0x100
        ram[source_address * 2] = 0x1234
        ram[source_address * 2 + 1] = 0x5678
        put_entry(
            ram,
            0,
            descriptor(flags=ALIGN_START | 0x0400, address=source_address),
        )
        put_end(ram, 1)
        ref = SpriteReference(sprite_ram=ram)
        ref.render_list()
        self.assertEqual(
            [pixel(ref, x, 0) for x in range(8)],
            [0x8123, 0x8124, 0x8121, 0x8122, 0x8127, 0x8128, 0x8125, 0x8126],
        )
        self.assertEqual(ref.stats["ram_fetches"], 1)
        self.assertEqual(ref.stats["rom_fetches"], 0)

    def test_external_indirect_palette(self) -> None:
        ram = blank_ram()
        palette_entry = 10
        ram[8 * palette_entry + 1] = 0x1234
        ram[8 * palette_entry + 2] = 0x7FFF
        put_entry(
            ram,
            0,
            descriptor(flags=ALIGN_START | 0x2000, color=palette_entry),
        )
        put_end(ram, 1)
        ref = SpriteReference(sprite_ram=ram, sprite_rom=SparseSpriteRom({0: 0x1200000F}))
        ref.render_list()
        self.assertEqual(pixel(ref, 0, 0), 0x1234)
        self.assertEqual(pixel(ref, 1, 0), 0xFFFF)

    def test_inline_indirect_palette_and_entry_skip(self) -> None:
        ram = blank_ram()
        put_entry(ram, 0, descriptor(flags=ALIGN_START | 0x3000))
        ram[8 + 1] = 0x2345
        put_end(ram, 3)
        ref = SpriteReference(sprite_ram=ram, sprite_rom=SparseSpriteRom({0: 0x1000000F}))
        ref.render_list()
        self.assertEqual(pixel(ref, 0, 0), 0x2345)
        self.assertEqual(ref.stats["commands"], 2)

    def test_8bpp_indirect_palette_preserves_low_nibble(self) -> None:
        ram = blank_ram()
        palette_entry = 20
        ram[8 * palette_entry + 2] = 0x1237
        put_entry(
            ram,
            0,
            descriptor(
                flags=ALIGN_START | 0x2000,
                bpp8=True,
                color=palette_entry,
            ),
        )
        put_end(ram, 1)
        ref = SpriteReference(sprite_ram=ram, sprite_rom=SparseSpriteRom({0: 0x2A0000FF}))
        ref.render_list()
        self.assertEqual(pixel(ref, 0, 0), 0x123A)

    def test_all_16_indirect_transparency_masks(self) -> None:
        for control4 in range(4):
            for control5 in range(4):
                with self.subTest(control4=control4, control5=control5):
                    mask = TRANSPARENCY_MASKS[control4][control5]
                    controls = [0] * 8
                    controls[4] = control4
                    controls[5] = control5
                    ram = blank_ram()
                    palette_entry = 12
                    ram[8 * palette_entry + 1] = mask
                    put_entry(
                        ram,
                        0,
                        descriptor(flags=ALIGN_START | 0x2000, color=palette_entry),
                    )
                    put_end(ram, 1)
                    ref = SpriteReference(
                        sprite_ram=ram,
                        sprite_rom=SparseSpriteRom({0: 0x1000000F}),
                        controls=controls,
                        latched_controls=controls,
                    )
                    ref.render_list()
                    self.assertEqual(pixel(ref, 0, 0), 0xFFFF)

                    ram[8 * palette_entry + 1] = mask ^ 1
                    ref = SpriteReference(
                        sprite_ram=ram,
                        sprite_rom=SparseSpriteRom({0: 0x1000000F}),
                        controls=controls,
                        latched_controls=controls,
                    )
                    ref.render_list()
                    self.assertNotEqual(pixel(ref, 0, 0), 0xFFFF)

    def test_shadow_clears_bit15_of_existing_destination(self) -> None:
        controls = [0] * 8
        controls[5] = 1
        ref = make_single(
            descriptor(flags=ALIGN_START | 0x0800, dest_width=1),
            {0: 0x1000000F},
            controls=controls,
            latched_controls=controls,
            back_fill=0xBEEF,
        )
        self.assertEqual(pixel(ref, 0, 0), 0x3EEF)
        self.assertEqual(ref.stats["shadow_writes"], 1)

        controls[5] = 0
        ref = make_single(
            descriptor(flags=ALIGN_START | 0x0800, dest_width=1),
            {0: 0x1000000F},
            controls=controls,
            latched_controls=controls,
            back_fill=0xBEEF,
        )
        self.assertEqual(pixel(ref, 0, 0), 0x8121)


class GeometryAndMemoryTests(unittest.TestCase):
    def test_horizontal_scaling_exact_fixed_point_sequence(self) -> None:
        shrink = make_single(
            descriptor(flags=ALIGN_START | 0x0100, dest_width=4),
            {0: 0x12345678},
        )
        self.assertEqual(
            [pixel(shrink, x, 0) & 0xF for x in range(4)],
            [1, 3, 5, 7],
        )

        enlarge = make_single(
            descriptor(flags=ALIGN_START | 0x0100, dest_width=16),
            {0: 0x12345678},
        )
        self.assertEqual(
            [pixel(enlarge, x, 0) & 0xF for x in range(16)],
            [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8],
        )

    def test_vertical_scaling_and_flip(self) -> None:
        normal = make_single(
            descriptor(source_height=2, dest_width=1, dest_height=4, y=10),
            {0: 0x1000000F, 1: 0x2000000F},
        )
        self.assertEqual([pixel(normal, 0, y) & 0xF for y in range(10, 14)], [1, 1, 2, 2])

        flipped = make_single(
            descriptor(flags=ALIGN_START | 0x0080, source_height=2, dest_width=1, dest_height=2, y=10),
            {0: 0x1000000F, 1: 0x2000000F},
        )
        self.assertEqual(pixel(flipped, 0, 10) & 0xF, 2)
        self.assertEqual(pixel(flipped, 0, 11) & 0xF, 1)

    def test_all_anchor_encodings_and_even_center_rounding(self) -> None:
        expected = {
            0: set(range(9, 13)),
            1: set(range(7, 11)),
            2: set(range(10, 14)),
            3: set(range(9, 13)),
        }
        for adjustment, positions in expected.items():
            with self.subTest(adjustment=adjustment):
                flags = (2 << 2) | adjustment | 0x0100
                ref = make_single(
                    descriptor(flags=flags, dest_width=4, x=10),
                    {0: 0x12345678},
                )
                actual = {x for x in range(20) if pixel(ref, x, 0) != 0xFFFF}
                self.assertEqual(actual, positions)

    def test_horizontal_flip_reverses_destination_direction(self) -> None:
        ref = make_single(
            descriptor(flags=ALIGN_START | 0x0140, dest_width=4, x=10),
            {0: 0x12345678},
        )
        self.assertEqual([pixel(ref, x, 0) & 0xF for x in range(10, 14)], [7, 5, 3, 1])

    def test_signed_offscreen_position_clips_safely(self) -> None:
        ref = make_single(
            descriptor(flags=ALIGN_START | 0x0100, dest_width=2, x=-1),
            {0: 0x12345678},
        )
        self.assertEqual(pixel(ref, 0, 0), 0x8125)

    def test_320_and_416_active_widths_share_416_word_storage(self) -> None:
        narrow_controls = [0] * 8
        narrow = make_single(
            descriptor(dest_width=1, x=400),
            {0: 0x1000000F},
            controls=narrow_controls,
            latched_controls=narrow_controls,
        )
        self.assertEqual(len(narrow.back_fb), 416 * 224)
        self.assertEqual(pixel(narrow, 400, 0), 0xFFFF)

        wide_controls = [0] * 8
        wide_controls[6] = 1
        wide = make_single(
            descriptor(dest_width=1, x=400),
            {0: 0x1000000F},
            controls=wide_controls,
            latched_controls=wide_controls,
        )
        self.assertEqual(pixel(wide, 400, 0), 0x8121)

    def test_global_flip_is_scanout_only_not_physical_render(self) -> None:
        controls = [0] * 8
        controls[2] = 3
        front = [0xFFFF] * FRAME_WORDS
        front[5 * STORAGE_WIDTH + 7] = 0x1234
        ref = SpriteReference(
            controls=controls,
            latched_controls=controls,
            front_fb=front,
        )
        scanout = ref.scanout_front()
        self.assertEqual(pixel(ref, 7, 5, front=True), 0x1234)
        self.assertEqual(scanout[(HEIGHT - 1 - 5) * 320 + (320 - 1 - 7)], 0x1234)

    def test_rom_bank_modulo_and_trace_raw_vs_effective(self) -> None:
        ref = make_single(
            descriptor(dest_width=1, bank=3),
            {(0, 0): 0x1000000F, (1, 0): 0x2000000F},
            bank_count=2,
            trace_level="fetches",
        )
        self.assertEqual(pixel(ref, 0, 0), 0x8122)
        fetch = next(event for event in ref.trace if event["kind"] == "source-fetch")
        self.assertEqual(fetch["raw_bank"], 3)
        self.assertEqual(fetch["effective_bank"], 1)
        self.assertEqual(ref.result()["sprite_rom_banks"], 2)

    def test_rom_address_wraps_within_4mib_bank(self) -> None:
        ref = make_single(
            descriptor(
                flags=ALIGN_START | 0x0100,
                source_width_words=2,
                dest_width=16,
                address=0xFFFFF,
            ),
            {0xFFFFF: 0x11111111, 0: 0x2222222F},
            trace_level="fetches",
        )
        self.assertTrue(all((pixel(ref, x, 0) & 0xF) == 1 for x in range(8)))
        self.assertTrue(all((pixel(ref, x, 0) & 0xF) == 2 for x in range(8, 15)))
        addresses = [
            event["address"]
            for event in ref.trace
            if event["kind"] == "source-fetch"
        ]
        self.assertEqual(addresses, [0xFFFFF, 0])

    def test_mame_region_bytes_are_big_endian_words(self) -> None:
        blob = bytearray(ROM_BANK_BYTES)
        blob[:4] = b"\x12\x34\x56\x78"
        rom = MameSpriteRom(blob)
        self.assertEqual(rom.bank_count, 1)
        self.assertEqual(rom.read_word(0, 0), 0x12345678)


class ManifestTests(unittest.TestCase):
    def test_cli_is_deterministic_and_writes_fixed_blob_sizes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ram = blank_ram()
            put_end(ram, 0)
            (root / "sprite_ram.bin").write_bytes(
                b"".join(word.to_bytes(2, "little") for word in ram)
            )
            (root / "sprite_rom.bin").write_bytes(bytes(ROM_BANK_BYTES))
            manifest = {
                "schema": "s32.sprite.v1",
                "width": 320,
                "controls": [0] * 8,
                "latched_controls": [0] * 8,
                "sprite_ram": {"path": "sprite_ram.bin", "format": "u16le"},
                "sprite_rom": {"path": "sprite_rom.bin", "format": "mame-region-bytes"},
                "event": "render",
                "trace_level": "commands",
            }
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

            first = root / "out-a"
            second = root / "out-b"
            self.assertEqual(
                main(["render", str(root / "manifest.json"), "--output-dir", str(first)]),
                0,
            )
            self.assertEqual(
                main(["render", str(root / "manifest.json"), "--output-dir", str(second)]),
                0,
            )
            self.assertEqual((first / "front.fb16le").stat().st_size, FRAME_WORDS * 2)
            self.assertEqual((first / "back.fb16le").stat().st_size, FRAME_WORDS * 2)
            self.assertEqual((first / "scanout.fb16le").stat().st_size, 320 * HEIGHT * 2)
            self.assertEqual((first / "result.json").read_bytes(), (second / "result.json").read_bytes())
            self.assertEqual((first / "trace.jsonl").read_bytes(), (second / "trace.jsonl").read_bytes())
            result = json.loads((first / "result.json").read_text(encoding="utf-8"))
            self.assertEqual(result["termination"], "end")


if __name__ == "__main__":
    unittest.main()
