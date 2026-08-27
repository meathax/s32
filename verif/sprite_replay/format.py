"""Shared, oracle-independent helpers for ``s32.sprite.v1`` fixtures.

The renderer reference lives in :mod:`verif.reference`; this module only
validates transport details and converts the binary blobs into simulator hex
files.  Keeping this code separate prevents the RTL runner from accidentally
sharing rendering logic with its oracle.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Iterable


SCHEMA = "s32.sprite.v1"
FB_WIDTH = 416
FB_HEIGHT = 224
FB_PIXELS = FB_WIDTH * FB_HEIGHT
FB_BYTES = FB_PIXELS * 2
SPRITE_RAM_BYTES = 0x20000
SPRITE_RAM_WORDS = SPRITE_RAM_BYTES // 2


class FixtureError(ValueError):
    """Raised when a replay fixture is malformed or ambiguous."""


def _blob_path(manifest_path: Path, spec: dict[str, Any], key: str) -> Path:
    try:
        value = spec["path"]
    except (KeyError, TypeError) as exc:
        raise FixtureError(f"{key} must be an object containing path") from exc
    path = Path(value)
    if not path.is_absolute():
        path = manifest_path.parent / path
    return path.resolve()


def derive_width(controls: list[int]) -> int:
    """Return the controller's active width; storage is always 416 pixels."""
    return 416 if controls[6] & 1 else 320


def load_manifest(path: str | Path) -> tuple[Path, dict[str, Any]]:
    manifest_path = Path(path).resolve()
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FixtureError(f"cannot read manifest {manifest_path}: {exc}") from exc
    validate_manifest(manifest_path, manifest)
    return manifest_path, manifest


def validate_manifest(manifest_path: Path, manifest: dict[str, Any]) -> None:
    if manifest.get("schema") != SCHEMA:
        raise FixtureError(f"schema must be {SCHEMA!r}")
    controls = manifest.get("controls")
    if not isinstance(controls, list) or len(controls) != 8:
        raise FixtureError("controls must contain exactly eight byte integers")
    if any(not isinstance(value, int) or not 0 <= value <= 0xFF for value in controls):
        raise FixtureError("each controls value must be an integer in 0..255")
    latched = manifest.get("latched_controls", controls)
    if not isinstance(latched, list) or len(latched) != 8 or any(
        not isinstance(value, int) or not 0 <= value <= 0xFF for value in latched
    ):
        raise FixtureError("latched_controls must contain eight byte integers")
    width = manifest.get("width", derive_width(controls))
    if width not in (320, 416):
        raise FixtureError("width must be 320 or 416")
    if width != derive_width(latched):
        raise FixtureError("width disagrees with latched_controls[6].bit0")
    if manifest.get("event", "render") not in ("render", "erase", "swap", "vblank"):
        raise FixtureError("event must be render, erase, swap, or vblank")

    required = {
        "sprite_ram": ("u16le", SPRITE_RAM_BYTES),
        "sprite_rom": ("mame-region-bytes", None),
    }
    optional = {
        "front_fb": ("u16le", FB_BYTES),
        "back_fb": ("u16le", FB_BYTES),
    }
    for key, (fmt, exact_size) in required.items():
        if key not in manifest:
            raise FixtureError(f"missing required blob {key}")
        _validate_blob(manifest_path, key, manifest[key], fmt, exact_size)
    for key, (fmt, exact_size) in optional.items():
        if key in manifest:
            _validate_blob(manifest_path, key, manifest[key], fmt, exact_size)


def _validate_blob(
    manifest_path: Path,
    key: str,
    spec: dict[str, Any],
    expected_format: str,
    exact_size: int | None,
) -> None:
    if not isinstance(spec, dict) or spec.get("format") != expected_format:
        raise FixtureError(f"{key}.format must be {expected_format!r}")
    path = _blob_path(manifest_path, spec, key)
    if not path.is_file():
        raise FixtureError(f"{key} blob does not exist: {path}")
    size = path.stat().st_size
    declared_size = spec.get("size")
    if declared_size is not None and declared_size != size:
        raise FixtureError(f"{key}.size={declared_size} but file has {size} bytes")
    if exact_size is not None and size != exact_size:
        raise FixtureError(f"{key} must be exactly {exact_size} bytes, got {size}")
    if key == "sprite_rom" and (size == 0 or size % 4):
        raise FixtureError("sprite_rom must be non-empty and a multiple of 4 bytes")
    if key.endswith("_fb"):
        if spec.get("width", FB_WIDTH) != FB_WIDTH or spec.get("height", FB_HEIGHT) != FB_HEIGHT:
            raise FixtureError(f"{key} storage must be 416x224 even in 320-wide mode")


def resolve_blob(manifest_path: Path, manifest: dict[str, Any], key: str) -> Path | None:
    spec = manifest.get(key)
    return None if spec is None else _blob_path(manifest_path, spec, key)


def read_blob(manifest_path: Path, manifest: dict[str, Any], key: str) -> bytes:
    path = resolve_blob(manifest_path, manifest, key)
    if path is None:
        if key in ("front_fb", "back_fb"):
            return b"\xff\xff" * FB_PIXELS
        raise FixtureError(f"missing blob {key}")
    return path.read_bytes()


def write_u16le_hex(blob: bytes, path: str | Path) -> None:
    if len(blob) % 2:
        raise FixtureError("u16le blob has an odd byte count")
    output = Path(path)
    with output.open("w", encoding="ascii", newline="\n") as stream:
        for offset in range(0, len(blob), 2):
            stream.write(f"{int.from_bytes(blob[offset:offset + 2], 'little'):04x}\n")


def write_rom128_hex(blob: bytes, path: str | Path) -> int:
    """Write ascending-address bytes in the p2 port's LSB-first burst layout."""
    output = Path(path)
    chunks = (len(blob) + 15) // 16
    with output.open("w", encoding="ascii", newline="\n") as stream:
        for offset in range(0, len(blob), 16):
            chunk = blob[offset:offset + 16].ljust(16, b"\xff")
            stream.write(f"{int.from_bytes(chunk, 'little'):032x}\n")
    return chunks


def read_u16_hex(path: str | Path, expected_words: int | None = None) -> bytes:
    values: list[int] = []
    for lineno, text in enumerate(Path(path).read_text(encoding="ascii").splitlines(), 1):
        text = text.strip()
        if not text or text.startswith("//"):
            continue
        try:
            value = int(text, 16)
        except ValueError as exc:
            raise FixtureError(f"invalid hex word at {path}:{lineno}") from exc
        if not 0 <= value <= 0xFFFF:
            raise FixtureError(f"wide hex word at {path}:{lineno}")
        values.append(value)
    if expected_words is not None and len(values) != expected_words:
        raise FixtureError(f"{path} has {len(values)} words, expected {expected_words}")
    return b"".join(value.to_bytes(2, "little") for value in values)


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: str | Path, value: Any) -> None:
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def words_to_blob(words: Iterable[int]) -> bytes:
    return b"".join((word & 0xFFFF).to_bytes(2, "little") for word in words)
