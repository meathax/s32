import unittest
from pathlib import Path
from xml.etree import ElementTree

from tools.gen_mra import (BUTTONS, GAMES, GAMES_BY_SET, PROT, RBF_BY_PARENT)


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

    def test_outrunners_selects_two_station_wiring(self) -> None:
        descriptor = bytearray(GAMES["orunners"])
        self.assertEqual(descriptor[0] & 0x09, 0x09)  # Multi32 + ADC
        self.assertEqual(descriptor[1] & 0x10, 0x10)  # OutRunners wiring
        # OutRunners has its own dedicated revision; it is the only Multi 32
        # bitstream that has been fitted and qualified.
        self.assertEqual(RBF_BY_PARENT["orunners"], "s32OutRunners")

    def test_no_multi32_title_targets_the_system32_bitstream(self) -> None:
        # SegaS32 is built S32_SYSTEM32_ONLY=1, so is_multi32 folds to a
        # constant zero: no second palette or mixer, no MultiPCM, half the work
        # RAM.  A Multi 32 set pointed at it could not drive the board at all.
        for parent in ("harddunk", "orunners", "scross", "titlef"):
            self.assertIn(parent, RBF_BY_PARENT, parent)
            self.assertNotEqual(RBF_BY_PARENT[parent], "SegaS32", parent)
            self.assertEqual(GAMES[parent][0] & 0x01, 0x01, f"{parent} multi32 bit")
            self.assertEqual(GAMES[parent][0] & 0x02, 0x00,
                             f"{parent} must be unprotected")
            # byte 3 (sprite bank valid/mask) is computed at generation time
            # from the real ROM region size, not carried in GAMES.

    def test_three_multi32_titles_share_one_rbf(self) -> None:
        for parent in ("harddunk", "scross", "titlef"):
            self.assertEqual(RBF_BY_PARENT[parent], "s32Multi32", parent)
        # The per-game selectors the RTL keeps descriptor-driven must actually
        # differ, or a single build could not tell the four apart.
        self.assertEqual(GAMES["harddunk"][0] & 0x20, 0x20)   # has_ppi
        self.assertEqual(GAMES["harddunk"][0] & 0x08, 0x00)   # no adc
        self.assertEqual(GAMES["scross"][0]   & 0x08, 0x08)   # has_adc
        self.assertEqual(GAMES["scross"][0]   & 0x20, 0x00)   # no ppi
        self.assertEqual(GAMES["scross"][1]   & 0x10, 0x00)   # not orunners wiring
        self.assertEqual(GAMES["titlef"][0]   & 0x28, 0x00)   # neither

    def test_multi32_revision_qsf(self) -> None:
        qsf = (Path(__file__).parents[1] / "s32Multi32.qsf").read_text(encoding="utf-8")
        self.assertIn('VERILOG_MACRO "S32_MULTI32_ONLY=1"', qsf)
        self.assertIn('VERILOG_MACRO "S32_RELEASE_MINIMAL=1"', qsf)
        self.assertIn('VERILOG_MACRO "S32_JT12_MLAB_SHIFTS=1"', qsf)
        # Both screens are retained on this revision by decision.
        self.assertNotIn("S32_SINGLE_SCREEN_MIX", qsf)

    def test_outrunners_revision_qsf(self) -> None:
        qsf = (Path(__file__).parents[1] / "s32OutRunners.qsf").read_text(encoding="utf-8")
        self.assertIn('VERILOG_MACRO "S32_OUTRUNNERS_ONLY=1"', qsf)
        self.assertIn('VERILOG_MACRO "S32_RELEASE_MINIMAL=1"', qsf)
        # Restoring the generic asynchronous V60 ROM cache moves ~2,850 ALMs
        # back into logic and crashed every fitter seed on routing congestion.
        self.assertNotIn('VERILOG_MACRO "S32_NO_MLAB_ROM_CACHE', qsf)


class CloneProtectionTests(unittest.TestCase):
    """A clone whose MAME init_* differs from its parent's must not inherit the
    parent's protection selector.

    Verified against segas32.cpp: exactly four sets have a divergent init_* --
    f1lapt, jleague, jleagueo and sonicp.  The descriptor lookup used to consult
    GAMES[parent] first, which made an explicit GAMES entry for a clone
    unreachable, so sonicp and jleague/jleagueo silently took the wrong setting.
    """

    def _descriptor(self, setname: str, parent: str) -> bytearray:
        # Mirrors the lookup order in tools.gen_mra.gen().
        base = (GAMES_BY_SET.get(setname)
                or GAMES.get(setname)
                or GAMES.get(parent))
        self.assertIsNotNone(base, f"no descriptor resolvable for {setname}")
        return bytearray(base)

    def test_f1lapt_is_unprotected(self) -> None:
        # init_f1lapt() omits m_system32_prot_vblank = f1lap_fd1149_vblank.
        self.assertEqual(self._descriptor("f1lapt", "f1lap")[2], PROT["NONE"])
        self.assertEqual(self._descriptor("f1lap", "f1lap")[2], PROT["F1LAP"])
        self.assertEqual(self._descriptor("f1lapt", "f1lap")[0] & 0x08, 0x08)

    def test_sonicp_prototype_is_unprotected(self) -> None:
        # init_sonicp() is segas32_common_init() only; init_sonic() installs
        # the 0x20e5c4 level-load handler.
        self.assertEqual(self._descriptor("sonicp", "sonic")[2], PROT["NONE"])
        self.assertEqual(self._descriptor("sonic", "sonic")[2], PROT["SONIC"])
        for st, pa in (("sonicp", "sonic"), ("sonic", "sonic")):
            self.assertEqual(self._descriptor(st, pa)[0] & 0x10, 0x10, st)

    def test_jleague_sets_are_protected_though_parent_svf_is_not(self) -> None:
        # init_jleague() installs the 0x20f700 handler; init_svf() does not.
        for setname in ("jleague", "jleagueo"):
            self.assertEqual(self._descriptor(setname, "svf")[2],
                             PROT["JLEAGUE"], setname)
        self.assertEqual(self._descriptor("svf", "svf")[2], PROT["NONE"])
        self.assertEqual(self._descriptor("svs", "svf")[2], PROT["NONE"])


class TrackedMraDescriptorTests(unittest.TestCase):
    """Pin the descriptor actually shipped in the tracked .mra files."""

    EXPECTED = {
        "F1 Super Lap (World, Unprotected).mra": "08000083",
        "F1 Super Lap (World).mra": "08000483",
        "SegaSonic The Hedgehog (Japan, rev. C).mra": "10000183",
        "The J.League 1994 (Japan).mra": "00000683",
        "The J.League 1994 (Japan, Rev A).mra": "00000683",
    }

    def test_tracked_descriptors(self) -> None:
        mra_dir = Path(__file__).parents[1] / "mra"
        for name, want in self.EXPECTED.items():
            path = mra_dir / name
            self.assertTrue(path.exists(), f"missing tracked MRA: {name}")
            root = ElementTree.fromstring(path.read_text(encoding="utf-8"))
            rom0 = next(r for r in root.iter("rom") if r.get("index") == "0")
            part = "".join(rom0.find("part").text.split())
            self.assertEqual(part[:8].upper(), want.upper(), name)


class Multi32EmissionTests(unittest.TestCase):
    """Every emitted Multi 32 MRA must carry the board bit and a Multi 32 RBF.

    The inverse of the failure this file used to guard: a Multi 32 launcher
    pointed at SegaS32 produces a core that cannot drive the board, and a
    Multi 32 MRA without the descriptor bit leaves is_multi32 low so the second
    palette, second mixer and MultiPCM never come up.
    """

    MULTI32_RBFS = {"s32Multi32", "s32OutRunners"}

    def _multi32_mras(self):
        mra_dir = Path(__file__).parents[1] / "mra"
        for path in sorted(mra_dir.glob("*.mra")):
            root = ElementTree.fromstring(path.read_text(encoding="utf-8"))
            rom0 = next(r for r in root.iter("rom") if r.get("index") == "0")
            descriptor = bytes.fromhex("".join(rom0.find("part").text.split()))
            yield path, root, descriptor

    def test_multi32_bit_and_rbf_agree_on_every_mra(self) -> None:
        seen = 0
        for path, root, descriptor in self._multi32_mras():
            rbf = root.findtext("rbf", "")
            is_multi32 = bool(descriptor[0] & 0x01)
            if is_multi32:
                seen += 1
                self.assertIn(rbf, self.MULTI32_RBFS,
                              f"{path.name} is a Multi 32 board on rbf {rbf!r}")
            else:
                self.assertNotIn(rbf, self.MULTI32_RBFS,
                                 f"{path.name} is not Multi 32 but targets {rbf!r}")
        # harddunk x2, orunners x3, scross x3, titlef x3
        self.assertEqual(seen, 11)

    def test_multi32_revisions_exist(self) -> None:
        root = Path(__file__).parents[1]
        for needed in ("s32Multi32.qsf", "s32OutRunners.qsf",
                       "s32Multi32.qpf", "s32OutRunners.qpf"):
            self.assertTrue((root / needed).exists(),
                            f"{needed} is required to build the Multi 32 sets")


class ButtonMetadataTests(unittest.TestCase):
    def test_outrunners_exposes_cabinet_controls(self) -> None:
        names, defaults = BUTTONS["orunners"]
        self.assertEqual(names.split(",")[:6],
                         ["Shift Up", "Shift Down", "DJ Music",
                          "Music Back", "Music Forward", "Brake"])
        self.assertEqual(len(defaults.split(",")), 10)

    def test_spiderman_has_two_action_buttons_and_system_controls(self) -> None:
        names, defaults = BUTTONS["spidman"]
        self.assertEqual(names.split(","),
                         ["Attack", "Jump", "-", "-", "-", "-", "Start", "Coin", "Test", "Service"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "Start", "Select", "R", "L"])

    def test_all_spiderman_mras_expose_button_metadata(self) -> None:
        mra_dir = Path(__file__).parents[1] / "mra"
        for path in sorted(mra_dir.glob("Spider-Man The Videogame*.mra")):
            root = ElementTree.parse(path).getroot()
            buttons = root.find("buttons")
            self.assertIsNotNone(buttons, path.name)
            self.assertEqual(buttons.attrib["names"], BUTTONS["spidman"][0])
            self.assertEqual(buttons.attrib["default"], BUTTONS["spidman"][1])
            self.assertEqual(buttons.attrib["count"], "2")


class OptimizedLayoutTests(unittest.TestCase):
    def test_every_mra_commits_descriptor_after_region_downloads(self) -> None:
        mra_dir = Path(__file__).parents[1] / "mra"
        paths = sorted(mra_dir.glob("*.mra"))
        # 44 System 32 + 11 Multi 32 (harddunk x2, orunners x3, scross x3,
        # titlef x3).  sonicp and the three Kokology sets stay dropped.
        self.assertEqual(len(paths), 55)
        for path in paths:
            root = ElementTree.parse(path).getroot()
            roms = root.findall("rom")
            indexes = [int(rom.attrib["index"]) for rom in roms]
            self.assertEqual(indexes[-1], 0, path.name)
            self.assertTrue(all(index in {0, 2, 4, 5, 6, 7, 8, 9}
                                for index in indexes), path.name)
            descriptor_rom = roms[-1]
            self.assertNotIn("zip", descriptor_rom.attrib, path.name)
            descriptor = bytes.fromhex(descriptor_rom.findtext("part", ""))
            self.assertEqual(len(descriptor), 64, path.name)
            self.assertTrue(any(index >= 4 for index in indexes), path.name)


if __name__ == "__main__":
    unittest.main()
