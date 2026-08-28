"""Static contract tests for the three single-screen driving profiles."""

import binascii
import unittest
from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).parents[1]
EXPECTED_DRIVING_SETS = {
    "slipstrm",
    "slipstrmh",
    "radm",
    "radmu",
    "radr",
    "radru",
    "radrj",
}


def descriptor(path: Path) -> bytes:
    root = ElementTree.parse(path).getroot()
    rom0 = next(
        rom for rom in root.findall("rom") if rom.get("index") == "0"
    )
    text = "".join("".join(part.itertext()) for part in rom0.findall("part"))
    return binascii.unhexlify("".join(text.split()))


class DrivingInputContractTests(unittest.TestCase):
    def test_driving_menu_gate_matches_shipped_descriptors(self) -> None:
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        self.assertIn(
            "wire driving_controls_visible = active_board.digital_steering ||",
            top,
        )
        self.assertIn("(active_board.digital_profile == DIGITAL_RADM)", top)
        self.assertIn("active_board.comm_link_hle", top)
        self.assertIn("h3O[40:39]", top)
        self.assertIn("h3O[42:41]", top)
        self.assertIn(
            "status_menumask({12'd0, driving_controls_visible", top)

        gated = set()
        for path in (ROOT / "releases").rglob("*.mra"):
            data = descriptor(path)
            enabled = bool(
                (data[4] & 0x04)
                or ((data[4] & 0x03) == 0x01)
                or (data[2] & 0x80)
            )
            if enabled:
                mra_root = ElementTree.parse(path).getroot()
                gated.add(mra_root.findtext("setname"))
        self.assertEqual(gated, EXPECTED_DRIVING_SETS)

    def test_driving_adapter_consumes_all_hps_steering_sources(self) -> None:
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        controls = (ROOT / "rtl/io/s32_driving_controls.sv").read_text(
            encoding="utf-8"
        )
        for source in (
            "paddle_0(paddle_0)",
            "spinner_0(spinner_0)",
            "paddle(paddle_0)",
            "spinner(spinner_0)",
            "mouse(ps2_mouse)",
            "wheel_source(driving_wheel_source)",
            "steering_sensitivity(driving_steering_sensitivity)",
        ):
            self.assertIn(source, top)
        for signal in (
            "wheel_sample",
            "spinner_event",
            "mouse_event",
            "scale_position",
            "scale_relative",
            "spinner_step",
        ):
            self.assertIn(signal, controls)
