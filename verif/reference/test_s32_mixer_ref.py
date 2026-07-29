"""Mixer reference tests, split by authority.

``MixerHardwareTruthTests`` is the accuracy gate.  Its expectations come from
hardware evidence and a failure means the model diverged from the board.

``MixerMameEquivalenceTests`` is a legacy change-detector.  It pins MAME's
integer semantics so an unintended behaviour change is still noticed, but a
pass proves only "we still match MAME" -- never promote it to an accuracy
argument.  Where the two classes disagree, the hardware class wins.
"""

import unittest

from verif.reference.s32_mixer_ref import (
    BACKGROUND,
    NBG0,
    SEM_HARDWARE,
    SEM_MAME,
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


def _blend_regs() -> list[int]:
    regs = blank_regs()
    regs[0x11] = 0x000F
    regs[0x02] = 0x0007
    regs[0x19] = 0x1000
    regs[0x26] = 0x0001
    regs[0x27] = 0x0B00
    return regs


def _shadow_regs() -> list[int]:
    regs = blank_regs()
    regs[0x11] = 0x000F
    regs[0x00] = 0x000F
    regs[0x26] = 0x0007
    return regs


class MixerHardwareTruthTests(unittest.TestCase):
    """Accuracy gate. Expectations trace to hardware evidence, not to MAME."""

    def test_full_scale_five_bit_reaches_full_white(self) -> None:
        """5-bit code 31 must emit 0xFF, not MAME's 0xF8.

        MacDonald measured the mixer colour-offset endpoints on a real board:
        ``$1F,$1F,$1F`` = "Screen is completely white".  furrtek's decap shows
        the 315-5242 is an OKI M71064 passive resistor-ladder DAC, so nothing
        sits between the 5-bit code and the monitor to bend the curve.
        """
        regs = blank_regs()
        regs[0x11] = 0x000F
        result = mix_pixel(regs, [0, 0x2001, 0, 0, 0, 0], 0xFFFF, 0, 0, 0,
                           palette, semantics=SEM_HARDWARE)
        self.assertEqual(result.winner, NBG0)
        self.assertEqual(result.rgb, 0xFFFFFF)

    def test_colour_offset_saturates_before_the_blend(self) -> None:
        """An over-range offset must clamp at the adder, not leak into the blend.

        MacDonald documents the offset stage as a clamped signed add in 5-bit
        colour space ("result CLAMPED (no wrapping)").  MAME instead carries the
        raw C integer into the blend, which changes the blended result.
        """
        regs = _blend_regs()
        # Offset mode 2 + layerflag set routes NBG0 to offset bank A.
        regs[0x1F] = 0x8000
        regs[0x19] = 0x5000
        regs[0x20] = 0x001F           # +31 on red: 31 + 31 = 62, must clamp to 31
        hardware = mix_pixel(regs, [0, 0x2001, 0, 0, 0, 0], 0x8002, 0, 0, 0,
                             palette, semantics=SEM_HARDWARE)
        legacy = mix_pixel(regs, [0, 0x2001, 0, 0, 0, 0], 0x8002, 0, 0, 0,
                           palette, semantics=SEM_MAME)
        self.assertTrue(hardware.blended)
        self.assertTrue(legacy.blended)
        # Hardware: clamp 62 -> 31, blend with 0 at factor 3 -> 15 -> 0x7B.
        self.assertEqual((hardware.rgb >> 16) & 0xFF, 0x7B)
        # MAME: 62 survives into the blend -> (62*4)>>3 = 31, clamped only at
        # the end. Two full stops brighter than the board would produce.
        self.assertEqual((legacy.rgb >> 19) & 0x1F, 31)

    def test_backdrop_and_shadow_use_replicated_expansion(self) -> None:
        backdrop = mix_pixel(blank_regs(), [0] * 6, 0xFFFF, 0, 0x0200, 0,
                             palette, semantics=SEM_HARDWARE)
        self.assertEqual(backdrop.winner, BACKGROUND)
        self.assertEqual(backdrop.first_palette_index, 0x200)
        self.assertEqual(backdrop.rgb, 0x7B0000)

        shadowed = mix_pixel(_shadow_regs(), [0, 0x2001, 0, 0, 0, 0], 0x07FE,
                             0, 0, 0, palette, semantics=SEM_HARDWARE)
        self.assertTrue(shadowed.shadowed)
        self.assertEqual(shadowed.rgb, 0x7B7B7B)

    def test_hardware_is_the_default_semantics(self) -> None:
        default = mix_pixel(blank_regs(), [0] * 6, 0xFFFF, 0, 0x0200, 0, palette)
        explicit = mix_pixel(blank_regs(), [0] * 6, 0xFFFF, 0, 0x0200, 0,
                             palette, semantics=SEM_HARDWARE)
        self.assertEqual(default.rgb, explicit.rgb)

    def test_unknown_semantics_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            mix_pixel(blank_regs(), [0] * 6, 0xFFFF, 0, 0, 0, palette,
                      semantics="approximate")


class MixerMameEquivalenceTests(unittest.TestCase):
    """LEGACY change-detector. Pins MAME's integer semantics.

    A pass here means "still bit-identical to MAME", which is NOT an accuracy
    claim -- MAME's colour packing and late clamping are both known wrong.
    """

    def test_holo_backdrop_comes_from_vram_1ff5e(self) -> None:
        result = mix_pixel(blank_regs(), [0] * 6, 0xFFFF, 0, 0x0200, 0, palette,
                           semantics=SEM_MAME)
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
        result = mix_pixel(regs, pixels, 0x8002, 0, 0, 0, palette,
                           semantics=SEM_MAME)
        self.assertEqual(result.winner, SPRITE)
        result = mix_pixel(regs, pixels, 0xFFFF, 0, 0, 0, palette,
                           semantics=SEM_MAME)
        self.assertEqual(result.winner, NBG0)

    def test_shadow_pen_passes_through_and_halves_winner(self) -> None:
        result = mix_pixel(_shadow_regs(), [0, 0x2001, 0, 0, 0, 0], 0x07FE,
                           0, 0, 0, palette, semantics=SEM_MAME)
        self.assertEqual(result.winner, NBG0)
        self.assertTrue(result.shadowed)
        self.assertEqual(result.rgb, 0x787878)

    def test_blend_uses_raw_not_or_adjusted_sprite_group(self) -> None:
        result = mix_pixel(_blend_regs(), [0, 0x2001, 0, 0, 0, 0], 0x8002,
                           0, 0, 0, palette, semantics=SEM_MAME)
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

    def test_layer_scan_ordering_is_unchanged_between_semantics(self) -> None:
        """Only arithmetic differs; layer selection must be identical."""
        regs = _blend_regs()
        pixels = [0, 0x2001, 0, 0, 0, 0]
        hardware = mix_pixel(regs, pixels, 0x8002, 0, 0, 0, palette,
                             semantics=SEM_HARDWARE)
        legacy = mix_pixel(regs, pixels, 0x8002, 0, 0, 0, palette,
                           semantics=SEM_MAME)
        self.assertEqual(hardware.winner, legacy.winner)
        self.assertEqual(hardware.partner, legacy.partner)
        self.assertEqual(hardware.blended, legacy.blended)
        self.assertEqual(hardware.shadowed, legacy.shadowed)
        self.assertEqual(hardware.first_palette_index, legacy.first_palette_index)


if __name__ == "__main__":
    unittest.main()
