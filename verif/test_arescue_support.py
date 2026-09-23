from pathlib import Path
import unittest
from xml.etree import ElementTree

from tools.gen_mra import BUTTONS, BUTTON_COUNTS, GAMES


ROOT = Path(__file__).parents[1]
RELEASES = ROOT / "releases"


class AirRescueDescriptorTests(unittest.TestCase):
    def descriptor(self, filename: str) -> bytes:
        root = ElementTree.parse(RELEASES / filename).getroot()
        part = root.find("rom[@index='0']/part")
        self.assertIsNotNone(part, filename)
        return bytes.fromhex(part.text or "")

    def test_generator_profile_is_adc_dual_link_and_arescue_dsp(self) -> None:
        self.assertEqual(GAMES["arescue"][:3], bytes.fromhex("080108"))
        self.assertEqual(GAMES["arescue"][4], 0x00)

    def test_all_three_mra_variants_select_the_reduced_profile(self) -> None:
        expected = {
            "Air Rescue (World).mra": ("arescue", None, "arescue.zip"),
            "_alternatives/_Air Rescue/Air Rescue (US).mra":
                ("arescueu", "arescue", "arescue.zip|arescueu.zip"),
            "_alternatives/_Air Rescue/Air Rescue (Japan).mra":
                ("arescuej", "arescue", "arescue.zip|arescuej.zip"),
        }
        for relative, (setname, parent, zip_name) in expected.items():
            with self.subTest(relative=relative):
                root = ElementTree.parse(RELEASES / relative).getroot()
                self.assertEqual(root.findtext("setname"), setname)
                self.assertEqual(root.findtext("parent"), parent)
                self.assertEqual(root.findtext("rbf"), "Arcade-SegaSystem32")
                self.assertEqual(root.findtext("homebrew"), "no")
                self.assertEqual(root.findtext("bootleg"), "no")
                self.assertEqual(root.findtext("resolution"), "15kHz")
                self.assertEqual(root.findtext("rotation"), "horizontal")
                buttons = root.find("buttons")
                self.assertIsNotNone(buttons)
                self.assertEqual(buttons.attrib["names"], BUTTONS["arescue"][0])
                self.assertEqual(buttons.attrib["default"], BUTTONS["arescue"][1])
                self.assertEqual(buttons.attrib["count"],
                                 str(BUTTON_COUNTS["arescue"]))
                for index in ("4", "5", "6", "9"):
                    self.assertEqual(root.find(f"rom[@index='{index}']").attrib["zip"],
                                     zip_name)
                self.assertEqual(root.find("nvram").attrib,
                                 {"index": "3", "size": "128"})
                descriptor = self.descriptor(relative)
                self.assertEqual(len(descriptor), 64)
                self.assertEqual(descriptor[:5], bytes.fromhex("0801088100"))

    def test_mame_rom_lane_maps_and_no_unverified_dsp_download(self) -> None:
        root = ElementTree.parse(RELEASES / "Air Rescue (World).mra").getroot()
        tiles = root.find("rom[@index='6']/interleave")
        self.assertEqual(tiles.attrib, {"output": "32"})
        self.assertEqual([p.attrib["map"] for p in tiles.findall("part")],
                         ["0001", "0010", "0100", "1000"])
        sprites = root.find("rom[@index='9']/interleave")
        self.assertEqual(sprites.attrib, {"output": "64"})
        self.assertEqual([p.attrib["map"] for p in sprites.findall("part")],
                         ["00000001", "00000010", "00000100", "00001000",
                          "00010000", "00100000", "01000000", "10000000"])
        indexes = [int(rom.attrib["index"]) for rom in root.findall("rom")]
        self.assertEqual(indexes[-1], 0)
        self.assertNotIn(8, indexes)
        self.assertNotIn("d7725.01", (RELEASES / "Air Rescue (World).mra").read_text())

    def test_rtl_contains_title_gated_link_ram_id_and_dsp_paths(self) -> None:
        core = (ROOT / "rtl" / "s32_core.sv").read_text()
        self.assertIn("A[23:12] == 12'h810", core)
        self.assertIn("A[23:12] == 12'h818", core)
        self.assertIn("A[23:3] == 21'h140000", core)
        self.assertIn("reg [7:0] comm_ram_lo [0:2047]", core)
        self.assertIn("reg [7:0] comm_ram_hi [0:2047]", core)
        self.assertIn("wire [15:0] comm_word_q = {comm_hi_q, comm_lo_q};", core)
        self.assertIn("wire       arescue_link_we", core)
        self.assertNotIn("arescue_link_ram [0:2047]", core)
        self.assertIn("s32_prot_arescue_dsp arescue_dsp", core)
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text()
        self.assertIn("wire [7:0] arescue_p1a", top)
        self.assertIn("wire [7:0] arescue_stick_x = joystick_l_analog_0[7:0] + 8'h80", top)
        self.assertIn("wire [7:0] arescue_stick_y = joystick_l_analog_0[15:8] + 8'h80", top)
        self.assertIn("arescue_inputs ? ~arescue_stick_x", top)
        self.assertIn("arescue_inputs ? arescue_stick_y", top)
        self.assertIn("wire [7:0] svc12_arescue", top)
        self.assertIn("wire [7:0] svc34_arescue = 8'hff", top)
        self.assertTrue((ROOT / "verif" / "common" / "tb_arescue_dsp.sv").is_file())


if __name__ == "__main__":
    unittest.main()
