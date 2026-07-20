#!/usr/bin/env python3
"""Boundary, validation, and CLI-path tests for the sprite oracle."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from verif.reference.s32_sprite_ref import (
    FRAME_WORDS,
    ROM_BANK_BYTES,
    SPRITE_RAM_WORDS,
    MameSpriteRom,
    SparseSpriteRom,
    SpriteReference,
    main,
)
from verif.reference.test_s32_sprite_ref import (
    ALIGN_START,
    blank_ram,
    descriptor,
    make_single,
    pixel,
    put_end,
)


class ConstructorValidationTests(unittest.TestCase):
    def test_rom_and_state_shape_validation(self) -> None:
        failures = (
            lambda: MameSpriteRom(b""),
            lambda: MameSpriteRom(b"\x00"),
            lambda: SparseSpriteRom(bank_count=0),
            lambda: SpriteReference(sprite_ram=[0]),
            lambda: SpriteReference(controls=[0] * 7),
            lambda: SpriteReference(controls=[0] * 7 + [256]),
            lambda: SpriteReference(selected_buffer=2),
            lambda: SpriteReference(render_count=-1),
            lambda: SpriteReference(trace_level="verbose"),
            lambda: SpriteReference(front_fb=[0]),
        )
        for failure in failures:
            with self.subTest(failure=failure):
                with self.assertRaises(ValueError):
                    failure()

    def test_byte_rom_constructor_and_control_alias_write(self) -> None:
        ref = SpriteReference(sprite_rom=bytes(ROM_BANK_BYTES))
        ref.write_control(9, 0x123)
        self.assertEqual(ref.controls[1], 0x23)


class EventAndGeometryEdgeTests(unittest.TestCase):
    @staticmethod
    def ended_reference() -> SpriteReference:
        ram = blank_ram()
        put_end(ram, 0)
        return SpriteReference(sprite_ram=ram)

    def test_run_event_dispatches_every_public_event(self) -> None:
        ref = self.ended_reference()
        ref.run_event("erase")
        self.assertEqual(ref.stats["erase_words"], FRAME_WORDS)
        ref.run_event("swap")
        self.assertEqual(ref.stats["swaps"], 1)
        ref.run_event("render")
        self.assertEqual(ref.stats["renders"], 1)
        ref.run_event("vblank")
        self.assertEqual(ref.stats["renders"], 2)
        with self.assertRaisesRegex(ValueError, "unknown sprite event"):
            ref.run_event("explode")

    def test_pixel_trace_level_records_write_details(self) -> None:
        ref = make_single(
            descriptor(dest_width=1),
            {0: 0x1000000F},
            trace_level="pixels",
        )
        kinds = {event["kind"] for event in ref.trace}
        self.assertIn("list-command", kinds)
        self.assertIn("draw-geometry", kinds)
        self.assertIn("source-fetch", kinds)
        self.assertIn("pixel-write", kinds)

    def test_all_vertical_anchor_encodings(self) -> None:
        expected = {
            0: set(range(9, 13)),
            1: set(range(7, 11)),
            2: set(range(10, 14)),
            3: set(range(9, 13)),
        }
        for adjustment, rows in expected.items():
            with self.subTest(adjustment=adjustment):
                flags = (adjustment << 2) | 2 | 0x0100
                ref = make_single(
                    descriptor(flags=flags, dest_width=1, dest_height=4, y=10),
                    {0: 0x1000000F},
                )
                actual = {y for y in range(20) if pixel(ref, 0, y) != 0xFFFF}
                self.assertEqual(actual, rows)

    def test_fully_offscreen_flipped_sprite_bails(self) -> None:
        ref = make_single(
            descriptor(flags=ALIGN_START | 0x0140, dest_width=4, x=-10),
            {0: 0x12345678},
        )
        self.assertEqual(ref.stats["skipped_draws"], 1)
        self.assertEqual(ref.stats["framebuffer_writes"], 0)


class ManifestValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        ram = blank_ram()
        put_end(ram, 0)
        (self.root / "ram.bin").write_bytes(
            b"".join(word.to_bytes(2, "little") for word in ram)
        )
        (self.root / "rom.bin").write_bytes(bytes(ROM_BANK_BYTES))
        (self.root / "front.bin").write_bytes((0x1111).to_bytes(2, "little") * FRAME_WORDS)
        (self.root / "back.bin").write_bytes((0x2222).to_bytes(2, "little") * FRAME_WORDS)
        self.manifest = {
            "schema": "s32.sprite.v1",
            "width": 416,
            "controls": [0] * 8,
            "latched_controls": [0, 0, 0, 0, 0, 0, 1, 0],
            "sprite_ram": "ram.bin",
            "sprite_rom": "rom.bin",
            "front_fb": {"path": "front.bin", "format": "u16le"},
            "back_fb": {"path": "back.bin", "format": "u16le"},
            "events": ["erase", "swap", "render"],
            "repeat": 2,
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_manifest(self, value: dict | None = None) -> Path:
        path = self.root / "manifest.json"
        path.write_text(json.dumps(value or self.manifest), encoding="utf-8")
        return path

    def test_optional_framebuffers_string_paths_event_list_and_repeat(self) -> None:
        manifest = self.write_manifest()
        output = self.root / "out"
        self.assertEqual(main(["render", str(manifest), "--output-dir", str(output)]), 0)
        result = json.loads((output / "result.json").read_text(encoding="utf-8"))
        self.assertEqual(result["active_width"], 320)
        self.assertEqual(result["stats"]["swaps"], 2)
        self.assertEqual(result["stats"]["renders"], 2)

    def test_manifest_schema_blob_and_width_failures(self) -> None:
        mutations = (
            ("schema", lambda data: data.update(schema="wrong")),
            ("missing sprite RAM", lambda data: data.pop("sprite_ram")),
            ("bad width", lambda data: data.update(width=321)),
            (
                "width mismatch",
                lambda data: data.update(width=320),
            ),
            (
                "wrong format",
                lambda data: data.update(sprite_ram={"path": "ram.bin", "format": "u16be"}),
            ),
            (
                "missing path",
                lambda data: data.update(sprite_ram={"format": "u16le"}),
            ),
        )
        for label, mutate in mutations:
            with self.subTest(label=label):
                data = json.loads(json.dumps(self.manifest))
                mutate(data)
                with self.assertRaises(ValueError):
                    SpriteReference.from_manifest(self.write_manifest(data))

    def test_manifest_blob_size_failures(self) -> None:
        (self.root / "short-ram.bin").write_bytes(b"\x00")
        (self.root / "short-rom.bin").write_bytes(b"\x00")
        for key, filename in (("sprite_ram", "short-ram.bin"), ("sprite_rom", "short-rom.bin")):
            with self.subTest(key=key):
                data = json.loads(json.dumps(self.manifest))
                data[key] = filename
                with self.assertRaises(ValueError):
                    SpriteReference.from_manifest(self.write_manifest(data))

    def test_event_list_repeat_and_event_name_failures(self) -> None:
        cases = (
            {"events": "render"},
            {"events": [1]},
            {"repeat": 0},
            {"events": ["unknown"]},
        )
        for changes in cases:
            with self.subTest(changes=changes):
                data = json.loads(json.dumps(self.manifest))
                data.update(changes)
                manifest = self.write_manifest(data)
                with self.assertRaises(ValueError):
                    main(["render", str(manifest), "--output-dir", str(self.root / "bad")])


if __name__ == "__main__":
    unittest.main()
