import unittest

from verif.reference.s32_mixer_ref import (
    BACKGROUND,
    NBG0,
    SPRITE,
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
        0x200: 0x000F,
    }.get(index, 0)


class MixerReferenceTests(unittest.TestCase):
    def test_holo_backdrop_comes_from_vram_1ff5e(self) -> None:
        result = mix_pixel(blank_regs(), [0] * 6, 0xFFFF, 0, 0x0200, 0, palette)
        self.assertEqual(result.winner, BACKGROUND)
        self.assertEqual(result.first_palette_index, 0x200)
        self.assertEqual(result.rgb, 0x780000)

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
        self.assertEqual(result.rgb, 0x787878)

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
        self.assertEqual(result.rgb, 0x787898)

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
