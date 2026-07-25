import unittest
from pathlib import Path
from xml.etree import ElementTree


class CloneMraRomsetTests(unittest.TestCase):
    def test_clone_mras_accept_merged_nonmerged_and_split_archives(self) -> None:
        mra_dir = Path(__file__).parents[1] / "mra"
        clone_count = 0
        for path in sorted(mra_dir.glob("*.mra")):
            root = ElementTree.parse(path).getroot()
            parent = root.findtext("parent")
            if not parent:
                continue
            clone_count += 1
            setname = root.findtext("setname")
            region_roms = [r for r in root.findall("rom")
                           if int(r.attrib["index"]) >= 4]
            self.assertGreater(len(region_roms), 0, path.name)
            for rom in region_roms:
                self.assertEqual(rom.attrib["zip"],
                                 f"{parent}.zip|{setname}.zip")
        self.assertGreater(clone_count, 0)


if __name__ == "__main__":
    unittest.main()
