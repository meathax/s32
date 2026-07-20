"""One edge where direct pen zero is distinct from the configured end code."""

import unittest

from verif.reference.test_s32_sprite_ref import descriptor, make_single, pixel


class DirectZeroTest(unittest.TestCase):
    def test_leading_direct_zero_is_empty_in_normal_mode(self) -> None:
        ref = make_single(descriptor(dest_width=1), {0: 0x0123456F})
        self.assertEqual(pixel(ref, 0, 0), 0xFFFF)
        self.assertEqual(ref.stats["framebuffer_writes"], 0)


if __name__ == "__main__":
    unittest.main()
