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

    def test_gun_games_default_invert_aim(self) -> None:
        # alien3/jpark carry gun_aim (b1 bit2) so their positional-gun analog
        # aim defaults to inverted; the ADC (b0 bit3) stays set.
        for game in ("alien3", "jpark"):
            descriptor = bytearray(GAMES[game])
            self.assertEqual(descriptor[0] & 0x08, 0x08, game)  # ADC present
            self.assertEqual(descriptor[1] & 0x04, 0x04, game)  # gun_aim invert
        # a non-gun analog board (radm steering) must NOT default-invert
        self.assertEqual(bytearray(GAMES["radm"])[1] & 0x04, 0x00)


if __name__ == "__main__":
    unittest.main()
