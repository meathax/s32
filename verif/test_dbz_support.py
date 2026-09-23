"""Contract tests for Dragon Ball Z V.R. V.S. support."""

import binascii
import unittest
from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).parents[1]
EXPECTED_BUTTONS = (
    "Left Punch,Right Punch,Jump,-,-,-,Start,Coin,Test,Service,Pause",
    "A,B,X,Start,Select,R,L,Y",
)


def dbz_mra() -> ElementTree.Element:
    for path in (ROOT / "releases").glob("*.mra"):
        root = ElementTree.parse(path).getroot()
        if root.findtext("setname") == "dbzvrvs":
            return root
    raise AssertionError("the dbzvrvs MRA is missing")


class DragonBallZSupportTests(unittest.TestCase):
    def test_mra_uses_official_metadata_and_functional_panel_names(self) -> None:
        root = dbz_mra()
        self.assertEqual(root.findtext("rbf"), "Arcade-SegaSystem32")
        self.assertEqual(root.findtext("homebrew"), "no")
        self.assertEqual(root.findtext("bootleg"), "no")
        self.assertEqual(root.findtext("resolution"), "15kHz")
        self.assertEqual(root.findtext("rotation"), "horizontal")

        buttons = root.find("buttons")
        self.assertIsNotNone(buttons)
        self.assertEqual(buttons.get("names"), EXPECTED_BUTTONS[0])
        self.assertEqual(buttons.get("default"), EXPECTED_BUTTONS[1])
        self.assertEqual(buttons.get("count"), "3")

        rom0 = root.find("rom[@index='0']")
        self.assertIsNotNone(rom0)
        descriptor = binascii.unhexlify(
            "".join("".join(part.itertext()) for part in rom0.findall("part"))
        )
        self.assertEqual(descriptor[:5], bytes.fromhex("0820058300"))
        self.assertTrue(all("type" not in rom.attrib for rom in root.findall("rom")))

    def test_top_consumes_dbz_all_ff_analog_profile(self) -> None:
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        self.assertIn(
            "wire analog_all_ff = active_board.analog_profile == ANALOG_ALL_FF;",
            top,
        )
        for channel in range(3):
            self.assertIn(
                f"assign adc_ch[{channel}] = analog_all_ff ? 8'hff :",
                top,
            )


if __name__ == "__main__":
    unittest.main()
