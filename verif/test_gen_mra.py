import unittest

from tools.gen_mra import GAMES


class BoardDescriptorTests(unittest.TestCase):
    def test_holosseum_is_regular_flipped_two_bank_sprite_board(self) -> None:
        descriptor = bytearray(GAMES["holo"])
        # Generator fills physical sprite metadata after parsing the ROM region.
        descriptor[3] = 0x81
        self.assertEqual(descriptor[0], 0x00)
        self.assertEqual(descriptor[1] & 0x01, 0x00)  # no dual PCB
        self.assertEqual(descriptor[1] & 0x02, 0x02)  # ORIENTATION_FLIP_Y
        self.assertEqual(descriptor[2], 0x00)         # no protection HLE
        self.assertEqual(descriptor[3], 0x81)         # 8 MiB sprites


if __name__ == "__main__":
    unittest.main()
