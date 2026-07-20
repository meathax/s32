import unittest

from verif.sprite_replay.capture_holo import _controller_command


class ControllerCommandTests(unittest.TestCase):
    def test_automatic_60hz_callback_renders(self) -> None:
        self.assertEqual(_controller_command([0, 0, 0, 0, 0, 0, 0, 0], 0), (False, 3))

    def test_automatic_30hz_counted_callback_skips(self) -> None:
        self.assertEqual(_controller_command([0, 0, 0, 1, 0, 0, 0, 0], 1), (False, 0))

    def test_automatic_mode_ignores_live_manual_command_byte(self) -> None:
        self.assertEqual(_controller_command([1, 0, 0, 0, 0, 0, 0, 0], 0), (False, 3))

    def test_manual_mode_uses_live_command(self) -> None:
        self.assertEqual(_controller_command([3, 0, 0, 2, 0, 0, 0, 0], 1), (True, 3))
        self.assertEqual(_controller_command([0, 0, 0, 2, 0, 0, 0, 0], 0), (True, 0))

    def test_invalid_captured_count_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "render_count"):
            _controller_command([0] * 8, 2)


if __name__ == "__main__":
    unittest.main()
