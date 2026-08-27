#!/usr/bin/env python3
"""Independent Sega System 32 315-5386A OBJECT reference renderer.

This is an event-level behavioral oracle, not a translation of the RTL and
not a cycle model.  It follows the System 32 (non-Multi 32) behavior pinned in
``scratch/segas32_v.cpp``.  The physical sprite framebuffers are always
416x224.  Control byte 6 selects a 320- or 416-pixel active render width.

The command line interface is intentionally blob-oriented so MAME captures,
RTL dumps, and synthetic fixtures can all use the same deterministic schema::

    python -m verif.reference.s32_sprite_ref render manifest.json \
        --output-dir output

See ``docs/sprite-315-5386a-spec.md`` for the schema and source traceability.
No game ROM is required by the module or its unit tests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Protocol, Sequence


STORAGE_WIDTH = 416
HEIGHT = 224
FRAME_WORDS = STORAGE_WIDTH * HEIGHT
SPRITE_RAM_BYTES = 0x20000
SPRITE_RAM_WORDS = SPRITE_RAM_BYTES // 2
LIST_ENTRIES = SPRITE_RAM_BYTES // 16
ROM_BANK_WORDS = 0x100000
ROM_BANK_BYTES = ROM_BANK_WORDS * 4

TRANSPARENCY_MASKS = (
    (0x7FFF, 0x3FFF, 0x1FFF, 0x0FFF),
    (0x3FFF, 0x1FFF, 0x0FFF, 0x07FF),
    (0x3FFF, 0x1FFF, 0x0FFF, 0x07FF),
    (0x1FFF, 0x0FFF, 0x07FF, 0x03FF),
)


def _sext12(value: int) -> int:
    value &= 0x0FFF
    return value - 0x1000 if value & 0x0800 else value


def _u8_list(values: Iterable[int], *, name: str) -> list[int]:
    result = [int(value) for value in values]
    if len(result) != 8:
        raise ValueError(f"{name} must contain exactly 8 bytes")
    if any(value < 0 or value > 0xFF for value in result):
        raise ValueError(f"{name} values must be in the range 0..255")
    return result


def _u16_words(blob: bytes, expected_words: int, *, name: str) -> list[int]:
    if len(blob) != expected_words * 2:
        raise ValueError(
            f"{name} must be exactly {expected_words * 2} bytes, got {len(blob)}"
        )
    return list(struct.unpack(f"<{expected_words}H", blob))


def _words_blob(words: Sequence[int]) -> bytes:
    return struct.pack(f"<{len(words)}H", *(word & 0xFFFF for word in words))


def _sha256_words(words: Sequence[int]) -> str:
    return hashlib.sha256(_words_blob(words)).hexdigest()


@dataclass(frozen=True)
class Rect:
    """Inclusive rectangle, matching MAME's rectangle convention."""

    min_x: int
    max_x: int
    min_y: int
    max_y: int

    def intersect(self, other: "Rect") -> "Rect":
        return Rect(
            max(self.min_x, other.min_x),
            min(self.max_x, other.max_x),
            max(self.min_y, other.min_y),
            min(self.max_y, other.max_y),
        )


class SpriteRom(Protocol):
    """32-bit, big-endian-word sprite ROM view."""

    @property
    def bank_count(self) -> int: ...

    def read_word(self, bank: int, address: int) -> int: ...


class MameSpriteRom:
    """MAME ``ROM_REGION32_BE`` bytes exposed as 32-bit sprite words."""

    def __init__(self, data: bytes | bytearray | memoryview):
        self._data = memoryview(data).cast("B")
        if len(self._data) == 0 or len(self._data) % ROM_BANK_BYTES:
            raise ValueError(
                "sprite ROM must contain one or more complete 4 MiB banks"
            )

    @property
    def bank_count(self) -> int:
        return len(self._data) // ROM_BANK_BYTES

    def read_word(self, bank: int, address: int) -> int:
        bank %= self.bank_count
        absolute = bank * ROM_BANK_WORDS + (address & (ROM_BANK_WORDS - 1))
        offset = absolute * 4
        return int.from_bytes(self._data[offset : offset + 4], "big")


class SparseSpriteRom:
    """Sparse synthetic ROM for unit tests; absent words read as zero."""

    def __init__(
        self,
        words: Mapping[int | tuple[int, int], int] | None = None,
        *,
        bank_count: int = 1,
    ):
        if bank_count <= 0:
            raise ValueError("bank_count must be positive")
        self._bank_count = bank_count
        self._words: dict[int, int] = {}
        for key, value in (words or {}).items():
            if isinstance(key, tuple):
                bank, address = key
                absolute = (bank % bank_count) * ROM_BANK_WORDS
                absolute += address & (ROM_BANK_WORDS - 1)
            else:
                absolute = int(key)
            self._words[absolute] = int(value) & 0xFFFFFFFF

    @property
    def bank_count(self) -> int:
        return self._bank_count

    def read_word(self, bank: int, address: int) -> int:
        absolute = (bank % self.bank_count) * ROM_BANK_WORDS
        absolute += address & (ROM_BANK_WORDS - 1)
        return self._words.get(absolute, 0)


class SpriteReference:
    """Event-level model of one non-Multi32 315-5386A sprite controller."""

    def __init__(
        self,
        *,
        sprite_ram: Sequence[int] | None = None,
        sprite_rom: SpriteRom | bytes | bytearray | memoryview | None = None,
        controls: Sequence[int] | None = None,
        latched_controls: Sequence[int] | None = None,
        front_fb: Sequence[int] | None = None,
        back_fb: Sequence[int] | None = None,
        selected_buffer: int = 1,
        render_count: int = 0,
        trace_level: str = "commands",
    ):
        self.sprite_ram = list(sprite_ram or [0] * SPRITE_RAM_WORDS)
        if len(self.sprite_ram) != SPRITE_RAM_WORDS:
            raise ValueError(
                f"sprite_ram must contain exactly {SPRITE_RAM_WORDS} words"
            )
        self.sprite_ram = [word & 0xFFFF for word in self.sprite_ram]

        if sprite_rom is None:
            self.sprite_rom: SpriteRom = SparseSpriteRom()
        elif isinstance(sprite_rom, (bytes, bytearray, memoryview)):
            self.sprite_rom = MameSpriteRom(sprite_rom)
        else:
            self.sprite_rom = sprite_rom

        self.controls = _u8_list(controls or [0] * 8, name="controls")
        self.latched_controls = _u8_list(
            latched_controls if latched_controls is not None else self.controls,
            name="latched_controls",
        )

        self.front_fb = self._framebuffer(front_fb, "front_fb")
        self.back_fb = self._framebuffer(back_fb, "back_fb")
        if selected_buffer not in (0, 1):
            raise ValueError("selected_buffer must be 0 or 1")
        self.selected_buffer = selected_buffer
        self.render_count = int(render_count)
        if self.render_count < 0:
            raise ValueError("render_count must be non-negative")
        if trace_level not in ("none", "commands", "fetches", "pixels"):
            raise ValueError("trace_level must be none, commands, fetches, or pixels")
        self.trace_level = trace_level

        self.trace: list[dict[str, Any]] = []
        self.stats: dict[str, int] = {}
        self.last_termination = "not-rendered"
        self._reset_stats()

    @staticmethod
    def _framebuffer(words: Sequence[int] | None, name: str) -> list[int]:
        result = list(words) if words is not None else [0xFFFF] * FRAME_WORDS
        if len(result) != FRAME_WORDS:
            raise ValueError(f"{name} must contain exactly {FRAME_WORDS} words")
        return [word & 0xFFFF for word in result]

    @property
    def active_width(self) -> int:
        return 416 if self.latched_controls[6] & 1 else 320

    def _reset_stats(self) -> None:
        self.stats = {
            "commands": 0,
            "draw_commands": 0,
            "clip_commands": 0,
            "jump_commands": 0,
            "end_commands": 0,
            "skipped_draws": 0,
            "rom_fetches": 0,
            "ram_fetches": 0,
            "framebuffer_writes": 0,
            "shadow_writes": 0,
            "erase_words": 0,
            "swaps": 0,
            "renders": 0,
        }

    def _emit(self, level: str, kind: str, **fields: Any) -> None:
        rank = {"none": 0, "commands": 1, "fetches": 2, "pixels": 3}
        if rank[self.trace_level] >= rank[level]:
            self.trace.append({"kind": kind, **fields})

    def write_control(self, offset: int, value: int) -> None:
        self.controls[offset & 7] = value & 0xFF

    def read_control(self, offset: int) -> int:
        """Return MAME's observable control value after an atomic event."""

        offset &= 7
        if offset == 0:
            return 0xFC | self.selected_buffer
        if offset == 1:
            return 0xFD
        if offset in (2, 3, 4, 5):
            return 0xFC | (self.latched_controls[offset] & 3)
        if offset == 6:
            return 0xFC | (self.latched_controls[6] & 1)
        return 0xFC

    def erase(self) -> None:
        self.front_fb[:] = [0xFFFF] * FRAME_WORDS
        self.stats["erase_words"] += FRAME_WORDS
        self._emit("commands", "erase", selected_buffer=self.selected_buffer)

    def swap(self) -> None:
        self.front_fb, self.back_fb = self.back_fb, self.front_fb
        self.selected_buffer ^= 1
        self.latched_controls = self.controls.copy()
        self.stats["swaps"] += 1
        self._emit(
            "commands",
            "swap",
            selected_buffer=self.selected_buffer,
            latched_controls=self.latched_controls.copy(),
        )

    def vblank(self) -> None:
        """Run the update callback scheduled 50 us after VBLANK ends."""

        if not (self.controls[3] & 2):
            if self.render_count == 0:
                self.controls[0] = 3
                self.render_count = self.controls[3] & 1
            else:
                self.render_count -= 1

        command = self.controls[0]
        self._emit(
            "commands",
            "vblank-update",
            command=command,
            render_count=self.render_count,
        )
        if command & 2:
            self.erase()
        if command & 1:
            self.swap()
            self.render_list()
        self.controls[0] = 0

    def run_event(self, event: str) -> None:
        if event == "render":
            self.render_list()
        elif event == "erase":
            self.erase()
        elif event == "swap":
            self.swap()
        elif event == "vblank":
            self.vblank()
        else:
            raise ValueError(f"unknown sprite event {event!r}")

    def _spr_word(self, index: int) -> int:
        # The 17-bit physical sprite RAM address wraps.  Valid MAME lists never
        # rely on table data crossing the end; wrapping makes synthetic failure
        # cases deterministic rather than invoking host out-of-bounds behavior.
        return self.sprite_ram[index & (SPRITE_RAM_WORDS - 1)]

    def _entry(self, number: int, words: int = 8) -> list[int]:
        base = 8 * (number & 0x1FFF)
        return [self._spr_word(base + index) for index in range(words)]

    def _from_ram_word(self, address: int) -> int:
        base = (address & 0x7FFF) * 2
        even = self._spr_word(base)
        odd = self._spr_word(base + 1)
        return (
            ((odd >> 8) & 0x000000FF)
            | ((odd << 8) & 0x0000FF00)
            | ((even << 8) & 0x00FF0000)
            | ((even << 24) & 0xFF000000)
        )

    def _source_word(
        self,
        *,
        from_ram: bool,
        bank: int,
        address: int,
        sprite_number: int,
        row: int,
    ) -> int:
        effective_address = address & (0x7FFF if from_ram else 0xFFFFF)
        if from_ram:
            value = self._from_ram_word(address)
            self.stats["ram_fetches"] += 1
            source = "ram"
            effective_bank = 0
        else:
            effective_bank = bank % self.sprite_rom.bank_count
            value = self.sprite_rom.read_word(effective_bank, address)
            self.stats["rom_fetches"] += 1
            source = "rom"
        self._emit(
            "fetches",
            "source-fetch",
            sprite=sprite_number,
            source=source,
            raw_bank=bank,
            effective_bank=effective_bank,
            raw_address=address,
            effective_address=effective_address,
            address=effective_address,
            row=row,
            value=f"{value:08x}",
        )
        return value

    def _write_pixel(
        self,
        *,
        x: int,
        y: int,
        value: int,
        shadow: bool,
        sprite_number: int,
        source_pixel: int,
    ) -> None:
        index = y * STORAGE_WIDTH + x
        old = self.back_fb[index]
        new = old & 0x7FFF if shadow else value & 0xFFFF
        self.back_fb[index] = new
        self.stats["framebuffer_writes"] += 1
        if shadow:
            self.stats["shadow_writes"] += 1
        self._emit(
            "pixels",
            "pixel-write",
            sprite=sprite_number,
            x=x,
            y=y,
            source_pixel=source_pixel,
            old=f"{old:04x}",
            value=f"{new:04x}",
            shadow=shadow,
        )

    def _draw_pixel(
        self,
        *,
        x: int,
        y: int,
        pix: int,
        transparent_code: int,
        do_clipout: bool,
        clipin: Rect,
        clipout: Rect,
        indirect: bool,
        indtable: Sequence[int],
        transmask: int,
        bpp8: bool,
        color: int,
        shadow: bool,
        sprite_number: int,
    ) -> None:
        if x < clipin.min_x or x > clipin.max_x:
            return
        if do_clipout and clipout.min_x <= x <= clipout.max_x:
            return
        if pix == transparent_code:
            return

        if not indirect:
            if pix == 0:
                return
            value = color | pix
        else:
            value = (indtable[pix >> 4] | (pix & 0x0F)) if bpp8 else indtable[pix]
            if (value & transmask) == transmask:
                return

        self._write_pixel(
            x=x,
            y=y,
            value=value,
            shadow=shadow,
            sprite_number=sprite_number,
            source_pixel=pix,
        )

    def draw_one_sprite(
        self,
        sprite_number: int,
        data: Sequence[int],
        xoffs: int,
        yoffs: int,
        clipin: Rect,
        clipout: Rect,
    ) -> int:
        indirect = bool(data[0] & 0x2000)
        indlocal = bool(data[0] & 0x1000)
        shadow = bool(data[0] & 0x0800) and bool(self.latched_controls[5] & 1)
        from_ram = bool(data[0] & 0x0400)
        bpp8 = bool(data[0] & 0x0200)
        transparent = 0 if data[0] & 0x0100 else (0xFF if bpp8 else 0x0F)
        flip_y = bool(data[0] & 0x0080)
        flip_x = bool(data[0] & 0x0040)
        offset_y = bool(data[0] & 0x0020)
        offset_x = bool(data[0] & 0x0010)
        adjust_y = (data[0] >> 2) & 3
        adjust_x = data[0] & 3
        source_height = data[1] >> 8
        source_width_words = (data[1] & 0x3F) if bpp8 else ((data[1] >> 1) & 0x3F)
        bank = ((data[3] & 0x0800) >> 11) | ((data[3] & 0x4000) >> 13)
        dest_height = data[2] & 0x03FF
        dest_width = data[3] & 0x03FF
        ypos = _sext12(data[4])
        xpos = _sext12(data[5])
        address = data[6] | ((data[2] & 0xF000) << 4)
        color = 0x8000 | (data[7] & (0x7F00 if bpp8 else 0x7FF0))
        skipped_entries = 2 if indirect and indlocal else 0

        if (
            source_width_words == 0
            or source_height == 0
            or dest_width == 0
            or dest_height == 0
        ):
            self.stats["skipped_draws"] += 1
            self._emit(
                "commands",
                "draw-skipped",
                sprite=sprite_number,
                reason="zero-dimension",
                skip_entries=skipped_entries,
            )
            return skipped_entries

        transmask = TRANSPARENCY_MASKS[
            self.latched_controls[4] & 3
        ][self.latched_controls[5] & 3]
        if bpp8:
            transmask &= 0xFFF0

        indtable = [0] * 16
        if indirect:
            if indlocal:
                palette = [self._spr_word(8 * sprite_number + 8 + x) for x in range(16)]
            else:
                palette_base = 8 * (data[7] & 0x1FFF)
                palette = [self._spr_word(palette_base + x) for x in range(16)]
            high = 0x8000 if self.latched_controls[5] & 1 else 0
            mask = 0xFFF0 if bpp8 else 0xFFFF
            indtable = [(word & mask) | high for word in palette]

        source_pixels = (4 if bpp8 else 8) * source_width_words
        hzoom = (source_pixels << 16) // dest_width
        vzoom = (source_height << 16) // dest_height

        if offset_x:
            xpos += xoffs
        if adjust_x in (0, 3):
            xpos -= (dest_width - 1) // 2
        elif adjust_x == 1:
            xpos -= dest_width - 1

        if offset_y:
            ypos += yoffs
        if adjust_y in (0, 3):
            ypos -= (dest_height - 1) // 2
        elif adjust_y == 1:
            ypos -= dest_height - 1

        xdelta = -1 if flip_x else 1
        ydelta = -1 if flip_y else 1
        if flip_x:
            xpos += dest_width - 1
        if flip_y:
            ypos += dest_height - 1

        xtarget = xpos + xdelta * dest_width
        ytarget = ypos + ydelta * dest_height
        if xdelta > 0 and xtarget > clipin.max_x:
            xtarget = clipin.max_x + 1
            if xpos >= xtarget:
                self.stats["skipped_draws"] += 1
                return skipped_entries
        if xdelta < 0 and xtarget < clipin.min_x:
            xtarget = clipin.min_x - 1
            if xpos <= xtarget:
                self.stats["skipped_draws"] += 1
                return skipped_entries

        self._emit(
            "commands",
            "draw-geometry",
            sprite=sprite_number,
            source_width_words=source_width_words,
            source_height=source_height,
            dest_width=dest_width,
            dest_height=dest_height,
            xpos=xpos,
            ypos=ypos,
            xtarget=xtarget,
            ytarget=ytarget,
            hzoom=hzoom,
            vzoom=vzoom,
            raw_bank=bank,
            effective_bank=bank % self.sprite_rom.bank_count if not from_ram else 0,
            address=address,
            bpp=8 if bpp8 else 4,
            from_ram=from_ram,
            indirect=indirect,
            shadow=shadow,
        )

        yacc = 0
        y = ypos
        row = 0
        while y != ytarget:
            if clipin.min_y <= y <= clipin.max_y:
                do_clipout = clipout.min_y <= y <= clipout.max_y
                xacc = 0
                x = xpos
                curaddr = address - 1
                pixels_per_word = 4 if bpp8 else 8
                shifts = (24, 16, 8, 0) if bpp8 else (28, 24, 20, 16, 12, 8, 4, 0)
                pixel_mask = 0xFF if bpp8 else 0x0F

                while x != xtarget:
                    curaddr += 1
                    pixels = self._source_word(
                        from_ram=from_ram,
                        bank=bank,
                        address=curaddr,
                        sprite_number=sprite_number,
                        row=row,
                    )
                    last_pix = 0
                    for source_index, shift in enumerate(shifts):
                        pix = (pixels >> shift) & pixel_mask
                        last_pix = pix
                        edge_transparent = transparent if source_index in (0, pixels_per_word - 1) else 0
                        while xacc < 0x10000 and x != xtarget:
                            self._draw_pixel(
                                x=x,
                                y=y,
                                pix=pix,
                                transparent_code=edge_transparent,
                                do_clipout=do_clipout,
                                clipin=clipin,
                                clipout=clipout,
                                indirect=indirect,
                                indtable=indtable,
                                transmask=transmask,
                                bpp8=bpp8,
                                color=color,
                                shadow=shadow,
                                sprite_number=sprite_number,
                            )
                            x += xdelta
                            xacc += hzoom
                        xacc -= 0x10000
                    if transparent != 0 and last_pix == transparent:
                        break

            yacc += vzoom
            address += source_width_words * (yacc >> 16)
            yacc &= 0xFFFF
            y += ydelta
            row += 1

        return skipped_entries

    def render_list(self) -> str:
        outer = Rect(0, 415 if self.latched_controls[6] & 1 else 319, 0, 223)
        clipin = outer
        clipout = Rect(0, -1, 0, -1)
        xoffs = 0
        yoffs = 0
        sprite_number = 0
        termination = "command-limit"
        self.stats["renders"] += 1

        for command_number in range(LIST_ENTRIES):
            data = self._entry(sprite_number, 24)
            command = data[0] >> 14
            self.stats["commands"] += 1
            self._emit(
                "commands",
                "list-command",
                ordinal=command_number,
                sprite=sprite_number & 0x1FFF,
                command=command,
                words=[f"{word:04x}" for word in data[:8]],
            )

            if command == 0:
                self.stats["draw_commands"] += 1
                skipped = self.draw_one_sprite(
                    sprite_number & 0x1FFF,
                    data,
                    xoffs,
                    yoffs,
                    clipin,
                    clipout,
                )
                sprite_number += 1 + skipped
            elif command == 1:
                self.stats["clip_commands"] += 1
                if data[0] & 0x1000:
                    clipin = Rect(
                        _sext12(data[2]),
                        _sext12(data[3]),
                        _sext12(data[0]),
                        _sext12(data[1]),
                    ).intersect(outer)
                if data[0] & 0x2000:
                    clipout = Rect(
                        _sext12(data[6]),
                        _sext12(data[7]),
                        _sext12(data[4]),
                        _sext12(data[5]),
                    )
                self._emit(
                    "commands",
                    "clip-set",
                    sprite=sprite_number & 0x1FFF,
                    clipin=clipin.__dict__,
                    clipout=clipout.__dict__,
                )
                sprite_number += 1
            elif command == 2:
                self.stats["jump_commands"] += 1
                if data[0] & 0x2000:
                    yoffs = _sext12(data[1])
                    xoffs = _sext12(data[2])
                sprite_number = data[0] & 0x1FFF
                self._emit(
                    "commands",
                    "jump",
                    target=sprite_number,
                    xoffs=xoffs,
                    yoffs=yoffs,
                )
            else:
                self.stats["end_commands"] += 1
                termination = "end"
                break

        self.last_termination = termination
        self._emit(
            "commands",
            "render-complete",
            termination=termination,
            commands=self.stats["commands"],
        )
        return termination

    def scanout_front(self) -> list[int]:
        """Return the active front buffer as seen after global X/Y scan flip."""

        width = self.active_width
        flip_x = bool(self.latched_controls[2] & 1)
        flip_y = bool(self.latched_controls[2] & 2)
        result = [0] * (width * HEIGHT)
        for y in range(HEIGHT):
            source_y = HEIGHT - 1 - y if flip_y else y
            source_base = source_y * STORAGE_WIDTH
            target_base = y * width
            if flip_x:
                for x in range(width):
                    result[target_base + x] = self.front_fb[source_base + width - 1 - x]
            else:
                result[target_base : target_base + width] = self.front_fb[
                    source_base : source_base + width
                ]
        return result

    def result(self) -> dict[str, Any]:
        scanout = self.scanout_front()
        return {
            "schema": "s32.sprite.result.v1",
            "active_width": self.active_width,
            "height": HEIGHT,
            "storage_width": STORAGE_WIDTH,
            "sprite_rom_banks": self.sprite_rom.bank_count,
            "selected_buffer": self.selected_buffer,
            "render_count": self.render_count,
            "controls": self.controls.copy(),
            "latched_controls": self.latched_controls.copy(),
            "termination": self.last_termination,
            "stats": self.stats.copy(),
            "sha256": {
                "front": _sha256_words(self.front_fb),
                "back": _sha256_words(self.back_fb),
                "scanout": _sha256_words(scanout),
            },
            "control_reads": [self.read_control(index) for index in range(8)],
        }

    @classmethod
    def from_manifest(cls, manifest_path: str | Path) -> tuple["SpriteReference", dict[str, Any]]:
        path = Path(manifest_path)
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if manifest.get("schema") != "s32.sprite.v1":
            raise ValueError("manifest schema must be s32.sprite.v1")
        base = path.parent

        def blob(
            spec: Any,
            *,
            expected_format: str,
            required: bool = True,
        ) -> bytes | None:
            if spec is None:
                if required:
                    raise ValueError("required blob specification is missing")
                return None
            relative = spec if isinstance(spec, str) else spec.get("path")
            if isinstance(spec, dict):
                actual_format = spec.get("format")
                if actual_format is not None and actual_format != expected_format:
                    raise ValueError(
                        f"blob format must be {expected_format}, got {actual_format}"
                    )
            if not relative:
                raise ValueError("blob specification requires a path")
            return (base / relative).read_bytes()

        controls = _u8_list(manifest.get("controls", [0] * 8), name="controls")
        latched_controls = _u8_list(
            manifest.get("latched_controls", controls), name="latched_controls"
        )
        if "width" in manifest:
            width = int(manifest["width"])
            if width not in (320, 416):
                raise ValueError("width must be 320 or 416")
            control_width = 416 if latched_controls[6] & 1 else 320
            if width != control_width:
                raise ValueError("width disagrees with latched_controls[6].bit0")

        sprite_ram_blob = blob(manifest.get("sprite_ram"), expected_format="u16le")
        sprite_rom_blob = blob(
            manifest.get("sprite_rom"), expected_format="mame-region-bytes"
        )
        front_blob = blob(manifest.get("front_fb"), expected_format="u16le", required=False)
        back_blob = blob(manifest.get("back_fb"), expected_format="u16le", required=False)

        reference = cls(
            sprite_ram=_u16_words(
                sprite_ram_blob or b"", SPRITE_RAM_WORDS, name="sprite_ram"
            ),
            sprite_rom=MameSpriteRom(sprite_rom_blob or b""),
            controls=controls,
            latched_controls=latched_controls,
            front_fb=(
                _u16_words(front_blob, FRAME_WORDS, name="front_fb")
                if front_blob is not None
                else None
            ),
            back_fb=(
                _u16_words(back_blob, FRAME_WORDS, name="back_fb")
                if back_blob is not None
                else None
            ),
            selected_buffer=int(manifest.get("selected_buffer", 1)),
            render_count=int(manifest.get("render_count", 0)),
            trace_level=str(manifest.get("trace_level", "commands")),
        )
        return reference, manifest

    def write_outputs(self, output_dir: str | Path) -> None:
        output = Path(output_dir)
        output.mkdir(parents=True, exist_ok=True)
        (output / "front.fb16le").write_bytes(_words_blob(self.front_fb))
        (output / "back.fb16le").write_bytes(_words_blob(self.back_fb))
        (output / "scanout.fb16le").write_bytes(_words_blob(self.scanout_front()))
        (output / "result.json").write_text(
            json.dumps(self.result(), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        trace_text = "".join(
            json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
            for event in self.trace
        )
        (output / "trace.jsonl").write_text(trace_text, encoding="utf-8")


def _render_cli(args: argparse.Namespace) -> int:
    reference, manifest = SpriteReference.from_manifest(args.manifest)
    events = manifest.get("events")
    if events is None:
        events = [manifest.get("event", "render")]
    if not isinstance(events, list) or not all(isinstance(item, str) for item in events):
        raise ValueError("events must be a list of event names")
    repeat = int(manifest.get("repeat", 1))
    if repeat <= 0:
        raise ValueError("repeat must be positive")
    for _ in range(repeat):
        for event in events:
            reference.run_event(event)
    reference.write_outputs(args.output_dir)
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    render = subparsers.add_parser("render", help="render a schema-v1 capture")
    render.add_argument("manifest", type=Path)
    render.add_argument("--output-dir", type=Path, required=True)
    render.set_defaults(func=_render_cli)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
