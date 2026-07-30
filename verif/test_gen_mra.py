import unittest
from pathlib import Path
from xml.etree import ElementTree

from tools.gen_mra import (BUTTONS, GAMES, GAMES_BY_SET, MULTI32_SETS, PROT,
                           RBF_BY_PARENT, UNSUPPORTED)


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


class System32OnlyScopeTests(unittest.TestCase):
    """This core is System 32 only; Multi 32 lives in a separate repository.

    The universal bitstream is built S32_SYSTEM32_ONLY=1, which leaves it with
    no V70 profile, no second palette or mixer and no MultiPCM. Shipping a
    Multi 32 launcher here could only produce a core that cannot drive the
    board, so those sets must not be emitted at all.
    """

    def test_multi32_sets_are_unsupported(self) -> None:
        self.assertTrue(MULTI32_SETS)
        for setname in MULTI32_SETS:
            self.assertIn(setname, UNSUPPORTED, setname)

    def test_no_multi32_descriptor_or_rbf_remains(self) -> None:
        for parent in ("harddunk", "orunners", "scross", "titlef"):
            self.assertNotIn(parent, GAMES, f"{parent} descriptor should be gone")
            self.assertNotIn(parent, RBF_BY_PARENT, f"{parent} RBF target should be gone")
            self.assertNotIn(parent, BUTTONS, f"{parent} button metadata should be gone")

    def test_no_emitted_mra_is_a_multi32_board(self) -> None:
        mra_dir = Path(__file__).parents[1] / "mra"
        for path in sorted(mra_dir.glob("*.mra")):
            root = ElementTree.fromstring(path.read_text(encoding="utf-8"))
            rom0 = next(r for r in root.iter("rom") if r.get("index") == "0")
            descriptor = bytes.fromhex("".join(rom0.find("part").text.split()))
            self.assertEqual(descriptor[0] & 0x01, 0x00,
                             f"{path.name} has the multi32 descriptor bit set")

    def test_only_system32_revisions_exist(self) -> None:
        root = Path(__file__).parents[1]
        for gone in ("s32Multi32.qsf", "s32OutRunners.qsf", "s32OutRunnersDbg.qsf"):
            self.assertFalse((root / gone).exists(), f"{gone} is a Multi 32 revision")


class ButtonMetadataTests(unittest.TestCase):
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
        self.assertEqual(len(paths), 46)
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
