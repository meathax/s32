import sys
import tempfile
import unittest
from pathlib import Path
from xml.etree import ElementTree

from tools.gen_mra import (BUTTON_COUNTS, BUTTONS, GAMES, IGNORED_PARENTS,
                           IGNORED_SETS, gen)


class BoardDescriptorTests(unittest.TestCase):
    def test_ignored_parents_are_not_profile_descriptors(self) -> None:
        self.assertTrue(IGNORED_PARENTS.isdisjoint(GAMES))

    def test_dropped_svfo_clone_is_not_regenerated(self) -> None:
        self.assertIn("svfo", IGNORED_SETS)
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(gen("svfo", {}, tmp))
            self.assertEqual(list(Path(tmp).glob("*.mra")), [])

    def test_holo_and_spidman_are_standard_profile_descriptors(self) -> None:
        self.assertEqual(GAMES["holo"][0] & 0x06, 0x00)
        self.assertEqual(GAMES["holo"][0] & 0x20, 0x00)
        self.assertEqual(GAMES["spidman"][0] & 0x20, 0x20)

    def test_supported_standard_games_keep_their_board_features(self) -> None:
        self.assertEqual(GAMES["darkedge"][:3], bytes.fromhex("200003"))
        self.assertEqual(GAMES["radr"][:3], bytes.fromhex("089080"))
        # Rad Mobile: MSM6253 ADC (b0 bit3) + DRIVING analog profile
        # (b1[5:4]=1), no protection, no gear toggle and no comm link -- MAME's
        # init_radm installs only the cabinet lamp/wiper switch outputs.
        self.assertEqual(GAMES["radm"][:3], bytes.fromhex("481000"))
        # Byte 4 is the semantic player-port layout: Rad Mobile leaves P1_A
        # bit0 unused and puts Light/Wiper on bits 1/2 (DIGITAL_RADM = 1).
        self.assertEqual(GAMES["radm"][4], 0x01)

    def test_positional_gun_descriptors_keep_adc_and_alien3_coin_layout(self) -> None:
        # b0 bit 3 selects the existing MSM6253 ADC. b1 bit 2 selects the
        # direct USB/SNAC positional-gun input adapter and bit 3 is Alien3's
        # special SERVICE12 coin layout.
        self.assertEqual(GAMES["alien3"][:2], bytes.fromhex("080c"))
        self.assertEqual(GAMES["jpark"][:2], bytes.fromhex("0804"))

    def test_football_family_uses_standard_board_and_jleague_protection(self) -> None:
        self.assertEqual(GAMES["svf"][:3], bytes.fromhex("000000"))
        self.assertEqual(GAMES["jleague"][:3], bytes.fromhex("000006"))
        self.assertEqual(GAMES["jleagueo"][:3], bytes.fromhex("000006"))

    def test_burning_rival_selects_ppi_and_protection(self) -> None:
        self.assertEqual(GAMES["brival"][:3], bytes.fromhex("200002"))

    def test_every_supported_four_player_parent_selects_the_ppi(self) -> None:
        # b0[5] is the descriptor's i8255-present flag.  Keep this list
        # explicit: Arabian Fight and Golden Axe II use the same 4-player
        # board as the ordinary PPI parents even though they also select V25.
        expected = {"arabfgt", "brival", "darkedge", "ga2", "spidman"}
        actual = {name for name, descriptor in GAMES.items()
                  if descriptor[0] & 0x20}
        self.assertEqual(actual, expected)


class ButtonMetadataTests(unittest.TestCase):
    def test_ga2_exposes_its_three_physical_action_buttons(self) -> None:
        names, defaults = BUTTONS["ga2"]
        self.assertEqual(names.split(","),
                         ["Attack", "Jump", "Magic", "-", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "X", "Start", "Select", "R", "L", "Y"])

    def test_arabian_fight_has_attack_and_jump_buttons(self) -> None:
        names, defaults = BUTTONS["arabfgt"]
        self.assertEqual(names.split(","),
                         ["Attack", "Jump", "-", "-", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "Start", "Select", "R", "L", "Y"])

    def test_spiderman_has_two_action_buttons_and_system_controls(self) -> None:
        names, defaults = BUTTONS["spidman"]
        self.assertEqual(names.split(","),
                         ["Attack", "Jump", "-", "-", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "Start", "Select", "R", "L", "Y"])

    def test_holosseum_has_only_light_and_heavy_attack(self) -> None:
        names, defaults = BUTTONS["holo"]
        self.assertEqual(names.split(","),
                         ["Light Attack", "Heavy Attack", "-", "-", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "Start", "Select", "R", "L", "Y"])

    def test_dark_edge_names_actions_and_assigns_jump_to_last_default_button(self) -> None:
        names, defaults = BUTTONS["darkedge"]
        self.assertEqual(names.split(","),
                         ["Light Punch", "Heavy Punch", "Jump",
                          "Light Kick", "Heavy Kick", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "R", "X", "Y", "Start", "Select", "L", "-"])

    def test_rad_mobile_shares_the_driving_pedals_and_adds_light_and_wiper(self) -> None:
        """Rad Mobile matches Rad Rally's pedal layout.

        B1/B2 are the shared digital Accelerate/Brake fallbacks that drive the
        MSM6253 channels; Rad Mobile's Light and Wiper cabinet switches sit on
        B3/B4 so they cannot collide with them.  Rad Mobile has no gear
        selector, which is the only difference from Rad Rally.
        """
        names, defaults = BUTTONS["radm"]
        self.assertEqual(names.split(","),
                         ["Accelerate", "Brake", "Light", "Wiper", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "X", "Y", "Start", "Select", "R", "L", "-"])

    def test_rad_rally_names_its_pedals_and_puts_the_gear_toggle_on_b3(self) -> None:
        """The gear toggle is joystick_0[6] = B3, matching Slip Stream.

        This previously named B1 "Gear Change", but B1 is the accelerator.
        """
        names, defaults = BUTTONS["radr"]
        self.assertEqual(names.split(","),
                         ["Accelerate", "Brake", "Gear Change", "-", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "X", "Start", "Select", "R", "L", "Y"])

    def test_promoted_games_keep_cabinet_button_counts(self) -> None:
        expected = {
            "alien3": 2, "brival": 6, "darkedge": 5, "holo": 2, "jpark": 1,
            "radm": 4, "radr": 3,
        }
        for parent, count in expected.items():
            with self.subTest(parent=parent):
                names, _ = BUTTONS[parent]
                self.assertEqual(sum(name != "-" for name in names.split(",")[:6]),
                                 count)

    def test_positional_gun_button_assignments_are_not_shared(self) -> None:
        self.assertEqual(BUTTONS["alien3"], (
            "Trigger,Button,-,-,-,-,Start,Coin,Test,Service,Pause",
            "A,B,Start,Select,R,L,Y",
        ))
        self.assertEqual(BUTTONS["jpark"], (
            "Shoot,-,-,-,-,-,Start,Coin,Test,Service,Pause",
            "A,Start,Select,R,L,Y",
        ))

    def test_slip_stream_maps_pedals_and_gear_to_a_b_x(self) -> None:
        names, defaults = BUTTONS["slipstrm"]
        self.assertEqual(names.split(","),
                         ["Accelerate", "Brake", "Gear Change", "-", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "X", "Start", "Select", "R", "L", "Y"])

    def test_football_controls_are_named_and_mapped_as_three_buttons(self) -> None:
        names, defaults = BUTTONS["svf"]
        self.assertEqual(names.split(","),
                         ["Shoot", "Pass-A", "Pass-B", "-", "-", "-",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "X", "Start", "Select", "R", "L", "Y"])

    def test_burning_rival_controls_are_named_and_mapped_as_six_buttons(self) -> None:
        names, defaults = BUTTONS["brival"]
        self.assertEqual(names.split(","),
                         ["Light Punch", "Medium Punch", "Heavy Punch",
                          "Light Kick", "Medium Kick", "Heavy Kick",
                          "Start", "Coin", "Test", "Service", "Pause"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "X", "Y", "R", "L", "Start", "Select", "-"])

    def test_every_tracked_mra_has_exact_parent_button_metadata(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.rglob("*.mra"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(path=path.relative_to(mra_dir)):
                root = ElementTree.parse(path).getroot()
                parent = root.findtext("parent") or root.findtext("setname")
                self.assertIn(parent, BUTTONS)
                buttons = root.find("buttons")
                self.assertIsNotNone(buttons)
                self.assertEqual(buttons.attrib["names"], BUTTONS[parent][0])
                self.assertEqual(buttons.attrib["default"], BUTTONS[parent][1])
                self.assertEqual(buttons.attrib["count"],
                                 str(BUTTON_COUNTS[parent]))
                self.assertEqual(buttons.attrib["names"].split(",")[-1], "Pause")


class EepromArchiveSourceTests(unittest.TestCase):
    def generate_radr(self, setname: str, parent: str) -> ElementTree.Element:
        data = {
            "parent": parent,
            "title": f"EEPROM source fixture {setname}",
            "year": "1991",
            "manu": "Sega",
            "regions": [
                {
                    "region": "maincpu", "size": 1,
                    "loads": [{
                        "macro": "ROM_LOAD", "file": "program.bin",
                        "offset": 0, "size": 1, "crc": "00000000",
                    }],
                },
                {
                    "region": "eeprom", "size": 0x80,
                    "loads": [{
                        "macro": "ROM_LOAD16_WORD",
                        "file": "eeprom-radr.ic76",
                        "offset": 0, "size": 0x80, "crc": "602032c6",
                    }],
                },
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(gen(setname, data, tmp))
            path = next(Path(tmp).glob("*.mra"))
            return ElementTree.parse(path).getroot()

    def test_parent_and_clone_eeprom_roms_name_their_archives(self) -> None:
        for setname, parent, expected_zip in (
            ("radr", "", "radr.zip"),
            ("radru", "radr", "radr.zip|radru.zip"),
        ):
            with self.subTest(setname=setname):
                root = self.generate_radr(setname, parent)
                eeprom = next(
                    rom for rom in root.findall("rom")
                    if rom.attrib["index"] == "2"
                )
                self.assertEqual(eeprom.attrib.get("zip"), expected_zip)
                self.assertEqual(eeprom.attrib.get("md5"), "none")
                self.assertEqual(
                    eeprom.find("part").attrib,
                    {"name": "eeprom-radr.ic76", "crc": "602032c6"},
                )


class OptimizedLayoutTests(unittest.TestCase):
    def test_release_tree_has_one_canonical_mra_per_game(self) -> None:
        release_dir = Path(__file__).parents[1] / "releases"
        expected_root = {
            "Alien3 The Gun (World).mra",
            "Arabian Fight (World).mra",
            "Burning Rival (World).mra",
            "Dark Edge (World).mra",
            "Golden Axe The Revenge of Death Adder (World, Rev B).mra",
            "Holosseum (US, Rev A).mra",
            "Jurassic Park (World, Rev A).mra",
            "Rad Mobile (World).mra",
            "Rad Rally (World).mra",
            "Slip Stream (Brazil 950515).mra",
            "Spider-Man The Videogame (World).mra",
            "Super Visual Football European Sega Cup (Rev A).mra",
            "Super Visual Soccer Sega Cup (US, Rev A).mra",
            "The J.League 1994 (Japan).mra",
        }
        self.assertEqual(
            {path.name for path in release_dir.glob("*.mra")},
            expected_root,
        )
        alternatives = sorted((release_dir / "_alternatives").rglob("*.mra"))
        self.assertEqual(len(alternatives), 18)
        for path in alternatives:
            with self.subTest(path=path.relative_to(release_dir)):
                self.assertEqual(path.parent.parent.name, "_alternatives")
                self.assertTrue(path.parent.name.startswith("_"))

    def test_football_variants_have_the_parent_and_descriptor_split(self) -> None:
        expected = {
            "svf": ("Super Visual Football European Sega Cup (Rev A).mra", 0x00),
            "svs": ("Super Visual Soccer Sega Cup (US, Rev A).mra", 0x00),
            "jleague": ("The J.League 1994 (Japan, Rev A).mra", 0x06),
            "jleagueo": ("The J.League 1994 (Japan).mra", 0x06),
        }
        mra_dir = Path(__file__).parents[1] / "releases"
        for setname, (filename, prot) in expected.items():
            with self.subTest(setname=setname):
                matches = list(mra_dir.rglob(filename))
                self.assertEqual(len(matches), 1, filename)
                root = ElementTree.parse(matches[0]).getroot()
                self.assertEqual(root.findtext("setname"), setname)
                if setname != "svf":
                    self.assertEqual(root.findtext("parent"), "svf")
                self.assertEqual(root.find("buttons").attrib["names"],
                                 BUTTONS["svf"][0])
                descriptor = bytes.fromhex(root.findall("rom")[-1].findtext("part", ""))
                self.assertEqual(descriptor[2], prot)

    def test_every_supported_mra_declares_persistent_score_storage(self) -> None:
        """Every supported variant must expose the EEPROM to MiSTer NVRAM.

        System 32 high scores live in the board's 93C46-backed persistent
        storage.  The core's loader and EEPROM model use index 3 as the
        upload/save image; a missing tag makes a title appear to work while
        silently losing its score table between launches.
        """
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.rglob("*.mra"), key=lambda path: path.name)
        self.assertEqual(len(paths), 32, str(mra_dir))
        for path in paths:
            root = ElementTree.parse(path).getroot()
            self.assertEqual(len(root.findall("nvram")), 1, path.name)
            nvram = root.find("nvram[@index='3']")
            self.assertIsNotNone(nvram, path.name)
            self.assertEqual(nvram.attrib, {"index": "3", "size": "128"}, path.name)

    def test_every_mra_commits_descriptor_after_region_downloads(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.rglob("*.mra"))
        # Air Rescue is intentionally excluded because its second PCB is not
        # part of the production core.
        self.assertEqual(len(paths), 32)
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

    def test_air_rescue_is_not_emitted(self) -> None:
        names = {path.name for path in (Path(__file__).parents[1] / "releases").glob("*.mra")}
        self.assertFalse(any("Air Rescue" in name for name in names))

    def test_rad_mobile_ships_both_regions_with_the_radm_port_layout(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.rglob("Rad Mobile*.mra"))
        self.assertEqual([path.name for path in paths],
                         ["Rad Mobile (US).mra", "Rad Mobile (World).mra"])
        for path in paths:
            root = ElementTree.parse(path).getroot()
            descriptor = bytes.fromhex(root.findall("rom")[-1].findtext("part", ""))
            self.assertEqual(descriptor[0] & 0x08, 0x08, path.name)   # ADC
            self.assertEqual(descriptor[0] & 0x40, 0x40, path.name)   # 837-7753 HLE
            self.assertEqual((descriptor[1] >> 4) & 0x03, 0x01, path.name)
            self.assertEqual(descriptor[2], 0x00, path.name)          # no prot
            self.assertEqual(descriptor[4], 0x01, path.name)          # RADM
            # Both sets ship the factory 93C46 image as the index-2 default.
            eeprom = [rom for rom in root.findall("rom")
                      if rom.attrib["index"] == "2"]
            self.assertEqual(len(eeprom), 1, path.name)
            self.assertEqual(eeprom[0].find("part").attrib["name"],
                             "eeprom-radm.ic76", path.name)

    def test_gun_games_ship_descriptor_and_distinct_button_assignments(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        expected = {
            "Alien3 The Gun (World).mra": ("alien3", 0x08, 0x0C, 2,
                                            BUTTONS["alien3"][0]),
            "Jurassic Park (World, Rev A).mra": ("jpark", 0x08, 0x04, 1,
                                                  BUTTONS["jpark"][0]),
        }
        for filename, (setname, b0, b1, count, names) in expected.items():
            with self.subTest(filename=filename):
                root = ElementTree.parse(mra_dir / filename).getroot()
                self.assertEqual(root.findtext("setname"), setname)
                descriptor = bytes.fromhex(root.findall("rom")[-1].findtext("part", ""))
                self.assertEqual(descriptor[0], b0)
                self.assertEqual(descriptor[1], b1)
                buttons = root.find("buttons")
                self.assertIsNotNone(buttons)
                self.assertEqual(buttons.attrib["count"], str(count))
                self.assertEqual(buttons.attrib["names"], names)
                if setname == "jpark":
                    patch = root.find("rom[@index='4']/patch")
                    self.assertIsNotNone(patch)
                    self.assertEqual(patch.attrib["offset"], "0xC15A8")
                    self.assertEqual(patch.text, "70 CD CD D8")

    def test_burning_rival_variants_ship_descriptor_and_six_named_buttons(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.rglob("Burning Rival*.mra"))
        self.assertEqual([path.name for path in paths],
                         ["Burning Rival (Japan).mra", "Burning Rival (World).mra"])
        for path in paths:
            root = ElementTree.parse(path).getroot()
            self.assertEqual(root.findtext("rbf"), "Arcade-SegaSystem32")
            descriptor = bytes.fromhex(root.findall("rom")[-1].findtext("part", ""))
            self.assertEqual(descriptor[:3], bytes.fromhex("200002"), path.name)
            buttons = root.find("buttons")
            self.assertIsNotNone(buttons, path.name)
            self.assertEqual(buttons.attrib["count"], "6", path.name)
            self.assertEqual(buttons.attrib["names"], BUTTONS["brival"][0], path.name)
            self.assertEqual(buttons.attrib["default"], BUTTONS["brival"][1], path.name)

    def test_rad_rally_uses_behavioral_link_without_diagnostic_firmware(self) -> None:
        for path in (Path(__file__).parents[1] / "releases").rglob("Rad Rally*.mra"):
            root = ElementTree.parse(path).getroot()
            roms = root.findall("rom")
            indexes = [int(rom.attrib["index"]) for rom in roms]
            self.assertNotIn(13, indexes, path.name)
            self.assertNotIn(14, indexes, path.name)
            self.assertEqual(indexes[-1], 0, path.name)


class RegenerationFidelityTests(unittest.TestCase):
    """The tracked MRAs must be exactly what gen_mra.py emits today.

    Drift here is silent and lossy: a regeneration overwrites hand-carried
    metadata with whatever the generator tables happen to say.  That is how the
    ga2 Pause mapping was lost -- BUTTONS["ga2"] omitted it while the three
    tracked MRAs shipped it, so any regeneration would have dropped a working
    control with no error.  Skipped when the MAME source is absent (it is
    reference material, not tracked).
    """

    MAME_SRC = (Path(__file__).parents[1] / "reference" / "ga2-cycle-accuracy" /
                "07_emulator_sources" / "mame_current" / "src" / "mame" /
                "sega" / "segas32.cpp")

    def test_ga2_mras_keep_the_pause_mapping(self) -> None:
        names, defaults = BUTTONS["ga2"]
        self.assertEqual(names.split(",")[-1], "Pause")
        self.assertEqual(defaults.split(",")[-1], "Y")
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.rglob("Golden Axe*.mra"))
        self.assertEqual(len(paths), 3)
        for path in paths:
            buttons = ElementTree.parse(path).getroot().find("buttons")
            self.assertIsNotNone(buttons, path.name)
            self.assertEqual(buttons.attrib["names"], names, path.name)
            self.assertEqual(buttons.attrib["default"], defaults, path.name)

    def test_generator_reproduces_every_tracked_mra(self) -> None:
        if not self.MAME_SRC.is_file():
            self.skipTest(f"MAME reference source not present: {self.MAME_SRC}")
        import subprocess, tempfile
        repo = Path(__file__).parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(
                [sys.executable, str(repo / "tools" / "gen_mra.py"),
                 str(self.MAME_SRC), tmp],
                 check=True, capture_output=True)
            generated = sorted(Path(tmp).glob("*.mra"))
            mra_dir = repo / "releases"
            tracked = sorted(mra_dir.rglob("*.mra"), key=lambda path: path.name)
            self.assertEqual([p.name for p in generated],
                             [p.name for p in tracked],
                             str(mra_dir))
            for want, got in zip(tracked, generated):
                # Compare text, not bytes: the tracked files carry CRLF
                # from git's autocrlf checkout while the generator emits LF.
                self.assertEqual(
                    want.read_text(encoding="utf-8").splitlines(),
                    got.read_text(encoding="utf-8").splitlines(),
                    want.name,
                )


class Multi32ExclusionTests(unittest.TestCase):
    """This repository is System 32 only.

    Every shipped Quartus revision sets S32_SYSTEM32_ONLY=1, which folds
    is_multi32 to a constant and removes the second palette, the second mixer,
    the MultiPCM path and half of work RAM.  A Multi 32 MRA therefore
    advertises a game no RBF built here can run.  These tests fail if one is
    reintroduced by either surface: the generator table or the tracked MRAs.
    """

    MULTI32_PARENTS = ("harddunk", "orunners", "scross", "titlef")

    def test_generator_defines_no_multi32_set(self) -> None:
        for parent in self.MULTI32_PARENTS:
            self.assertNotIn(parent, GAMES)

    def test_no_game_descriptor_sets_the_multi32_bit(self) -> None:
        # b0 bit0 is the multi32 flag the RTL parses out of the index-0
        # descriptor.  No emitted set may assert it.
        for name, descriptor in GAMES.items():
            self.assertEqual(descriptor[0] & 0x01, 0x00, name)

    def test_no_tracked_mra_carries_a_multi32_descriptor(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.glob("*.mra"))
        self.assertTrue(paths)
        for path in paths:
            root = ElementTree.parse(path).getroot()
            setname = root.findtext("setname", "")
            self.assertNotIn(setname, self.MULTI32_PARENTS, path.name)
            descriptor = bytes.fromhex(root.findall("rom")[-1].findtext("part", ""))
            self.assertEqual(descriptor[0] & 0x01, 0x00, path.name)

    def test_no_mra_targets_a_multi32_rbf(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        for path in sorted(mra_dir.glob("*.mra")):
            rbf = ElementTree.parse(path).getroot().findtext("rbf", "")
            self.assertNotIn("Multi32", rbf, path.name)
            self.assertNotIn("OutRunners", rbf, path.name)


if __name__ == "__main__":
    unittest.main()
