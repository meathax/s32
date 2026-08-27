import unittest

from verif.reference.s32_mixer_ref import (
    BACKGROUND,
    BITMAP,
    NBG0,
    NBG1,
    SPRITE,
    TEXT,
    mix_pixel,
    sprite_blend_mask,
    sprite_group_params,
)


def blank_regs() -> list[int]:
    regs = [0] * 64
    regs[0x16] = 0
    return regs


def palette(index: int) -> int:
    return {
        0x001: 0x7FFF,
        0x002: 0x2000,
        0x020: 0x03E0,
        0x030: 0x001F,
        0x200: 0x000F,
    }.get(index, 0)


class MixerReferenceTests(unittest.TestCase):
    def test_holo_backdrop_comes_from_vram_1ff5e(self) -> None:
        result = mix_pixel(blank_regs(), [0] * 6, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, BACKGROUND)
        self.assertEqual(result.first_palette_index, 0x200)
        self.assertEqual(result.rgb, 0x7B0000)

    def test_equal_priority_order_is_sprite_then_nbg0(self) -> None:
        regs = blank_regs()
        regs[0x11] = 0x000F
        regs[0x12] = 0x000F
        regs[0x00] = 0x000F
        regs[0x26] = 0x0004
        pixels = [0, 0x2001, 0x2002, 0, 0, 0]
        result = mix_pixel(regs, pixels, 0x8002, 0, 0, 0, palette)
        self.assertEqual(result.winner, SPRITE)
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0, 0, palette)
        self.assertEqual(result.winner, NBG0)

    def test_shadow_pen_passes_through_and_halves_winner(self) -> None:
        regs = blank_regs()
        regs[0x11] = 0x000F
        regs[0x00] = 0x000F
        regs[0x26] = 0x0007
        pixels = [0, 0x2001, 0, 0, 0, 0]
        result = mix_pixel(regs, pixels, 0x07FE, 0, 0, 0, palette)
        self.assertEqual(result.winner, NBG0)
        self.assertTrue(result.shadowed)
        self.assertEqual(result.rgb, 0x7B7B7B)

    def test_blend_uses_raw_not_or_adjusted_sprite_group(self) -> None:
        regs = blank_regs()
        regs[0x11] = 0x000F
        regs[0x02] = 0x0007
        regs[0x19] = 0x1000
        regs[0x26] = 0x0001
        regs[0x27] = 0x0B00
        pixels = [0, 0x2001, 0, 0, 0, 0]
        result = mix_pixel(regs, pixels, 0x8002, 0, 0, 0, palette)
        self.assertEqual(result.winner, NBG0)
        self.assertEqual(result.partner, SPRITE)
        self.assertTrue(result.blended)
        self.assertEqual(result.rgb, 0x7B7B9C)

    def test_opaque_zero_is_only_a_backdrop_fallback(self) -> None:
        regs = blank_regs()
        regs[0x12] = 0x000F
        pixels = [0, 0, 0x2020, 0, 0, 0]

        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, NBG1)
        self.assertEqual(result.first_palette_index, 0x020)

        regs[0x15] = 0x0001
        pixels[BITMAP] = 0x2002
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, BITMAP)

        pixels[BITMAP] = 0
        regs[0x15] = 0
        regs[0x01] = 0x0001
        result = mix_pixel(regs, pixels, 0x8001, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, SPRITE)

        regs[0x01] = 0
        regs[0x10] = 0x0001
        pixels[TEXT] = 0x2001
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, TEXT)

        pixels[TEXT] = 0
        regs[0x10] = 0
        regs[0x11] = 0x0001
        pixels[NBG0] = 0x2001
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, NBG0)

        pixels[NBG0] = 0
        result = mix_pixel(regs, pixels, 0xFFFF, 1 << NBG1, 0x0200, 0, palette)
        self.assertEqual(result.winner, BACKGROUND)
        regs[0x12] = 0
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, BACKGROUND)

    def test_opaque_zero_uses_fixed_nbg_rank_and_blends(self) -> None:
        regs = blank_regs()
        regs[0x11] = 0x0001
        regs[0x12] = 0x000F
        regs[0x14] = 0x000F
        pixels = [0, 0x2030, 0, 0, 0x2020, 0]
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, NBG0)
        self.assertEqual(result.first_palette_index, 0x030)

        # Normal NBG0 blends with fallback NBG1.
        regs[0x11] = 0x000F
        regs[0x14] = 0
        regs[0x19] = 0x0100
        regs[0x27] = 0x0B00
        pixels = [0, 0x2001, 0x2020, 0, 0, 0]
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, NBG0)
        self.assertEqual(result.partner, NBG1)
        self.assertTrue(result.blended)
        self.assertEqual(result.rgb, 0x7BFF7B)

        # Fallback NBG1 blends with the backdrop when no real pixel exists.
        regs[0x11] = 0
        regs[0x19] = 0
        regs[0x1A] = 0x2000
        pixels[NBG0] = 0
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, NBG1)
        self.assertEqual(result.partner, BACKGROUND)
        self.assertTrue(result.blended)
        self.assertEqual(result.rgb, 0x397B00)

    def test_all_sprite_group_modes_and_blend_encodings(self) -> None:
        self.assertEqual([sprite_group_params(mode) for mode in range(16)], [
            (14, 0, 1), (14, 1, 2), (13, 3, 4), (12, 7, 8),
            (14, 1, 0), (13, 3, 0), (12, 7, 0), (11, 15, 0),
            (14, 1, 0), (13, 3, 0), (12, 7, 0), (11, 15, 0),
            (13, 1, 0), (12, 3, 0), (11, 7, 0), (10, 15, 0),
        ])
        self.assertEqual(sprite_blend_mask(0x05), 1 << 5)
        self.assertEqual(sprite_blend_mask(0x15), 0x003F)
        self.assertEqual(sprite_blend_mask(0x25), 0xFFE0)
        self.assertEqual(sprite_blend_mask(0x35), 0xFFFF)


if __name__ == "__main__":
    unittest.main()
