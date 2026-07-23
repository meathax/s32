"""Regression tests for MRA stream patch handling in simulation images."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "make_sim_images", REPO_ROOT / "tools" / "make_sim_images.py"
)
assert SPEC is not None and SPEC.loader is not None
make_sim_images = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(make_sim_images)


def write_mra(path: Path, patch_offset: str) -> None:
    path.write_text(
        "<misterromdescription>"
        '<rom index="0">'
        "<part>00 11 22 33</part>"
        f'<patch offset="{patch_offset}">AA BB</patch>'
        "</rom>"
        "</misterromdescription>",
        encoding="utf-8",
    )


class MakeSimImagesPatchTests(unittest.TestCase):
    def test_patch_uses_complete_download_stream_offset(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            mra = temp / "patched.mra"
            write_mra(mra, "0x1")
            self.assertEqual(
                make_sim_images.build_stream(mra, temp),
                bytes.fromhex("00 AA BB 33"),
            )

    def test_patch_must_fit_inside_download_stream(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            mra = temp / "out-of-range.mra"
            write_mra(mra, "0x4")
            with self.assertRaisesRegex(AssertionError, "exceeds stream"):
                make_sim_images.build_stream(mra, temp)


if __name__ == "__main__":
    unittest.main()
