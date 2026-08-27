from __future__ import annotations

from pathlib import Path
from typing import Any
from xml.etree import ElementTree

from .util import ensure_relative, utc_now


class MRAError(ValueError):
    pass


def _rbf_stem(value: str) -> str:
    name = Path(value.strip()).name
    return Path(name).stem.lower()


def _rom_record(node: ElementTree.Element) -> dict[str, Any]:
    parts = node.findall(".//part")
    text = "".join(node.itertext()).strip()
    attrs = {str(k): str(v) for k, v in node.attrib.items()}
    meaningful_attrs = {"zip", "md5", "crc", "address", "length", "index", "type", "name"}
    usable = bool(text or parts or meaningful_attrs.intersection(attrs))
    return {
        "attributes": attrs,
        "part_count": len(parts),
        "has_text": bool(text),
        "usable": usable,
    }


def validate_mras(root: Path, config: dict[str, Any], *, rbf_path: Path | None = None) -> dict[str, Any]:
    mister_cfg = config.get("mister", {})
    mame_cfg = config.get("mame", {})
    files = mister_cfg.get("mra_files", [])
    errors: list[str] = []
    warnings: list[str] = []
    records: list[dict[str, Any]] = []
    if not isinstance(files, list) or not files:
        errors.append("mister.mra_files must list at least one MRA for release.")
        files = []
    supported = mame_cfg.get("supported_setnames", [])
    if not isinstance(supported, list):
        supported = []
    if not supported and isinstance(mame_cfg.get("shortname"), str):
        supported = [mame_cfg["shortname"]]
    supported_normalized = {str(item).strip().lower() for item in supported if str(item).strip()}
    expected_rbf = mister_cfg.get("rbf_name")
    if expected_rbf in (None, "", "AUTO") and rbf_path is not None:
        expected_rbf = rbf_path.stem
    expected_rbf_stem = _rbf_stem(expected_rbf) if isinstance(expected_rbf, str) and expected_rbf.strip() else None
    require_rom_mapping = bool(mister_cfg.get("require_rom_mapping", True))

    for value in files:
        path = ensure_relative(root, str(value)).resolve()
        record: dict[str, Any] = {"path": str(path)}
        if not path.exists():
            errors.append(f"MRA does not exist: {path}")
            records.append(record)
            continue
        if not path.is_file():
            errors.append(f"MRA path is not a file: {path}")
            records.append(record)
            continue
        try:
            tree = ElementTree.parse(path)
        except (ElementTree.ParseError, OSError) as exc:
            errors.append(f"Cannot parse MRA {path}: {exc}")
            records.append(record)
            continue
        xml = tree.getroot()
        setname = (xml.findtext(".//setname") or "").strip()
        rbf = (xml.findtext(".//rbf") or "").strip()
        name = (xml.findtext(".//name") or "").strip()
        rom_nodes = xml.findall(".//rom")
        roms = [_rom_record(node) for node in rom_nodes]
        record.update({
            "name": name,
            "setname": setname,
            "rbf": rbf,
            "rom_count": len(roms),
            "usable_rom_count": sum(1 for item in roms if item["usable"]),
            "roms": roms,
        })
        if not setname:
            errors.append(f"MRA has no setname: {path}")
        elif supported_normalized and setname.lower() not in supported_normalized:
            errors.append(
                f"MRA setname {setname!r} is not in mame.supported_setnames: {path}"
            )
        if not rbf:
            errors.append(f"MRA has no rbf element: {path}")
        elif expected_rbf_stem and _rbf_stem(rbf) != expected_rbf_stem:
            errors.append(
                f"MRA rbf {rbf!r} does not match expected {expected_rbf!r}: {path}"
            )

        indices: list[str] = []
        for node in rom_nodes:
            index = node.attrib.get("index")
            if index is not None:
                indices.append(index.strip())
        duplicates = sorted({index for index in indices if indices.count(index) > 1})
        if duplicates:
            errors.append(f"MRA contains duplicate rom index values {duplicates}: {path}")
        usable_count = record["usable_rom_count"]
        if usable_count == 0:
            message = f"MRA contains no usable ROM mapping: {path}"
            if require_rom_mapping:
                errors.append(message)
            else:
                warnings.append(message)
        if any(not item["usable"] for item in roms):
            warnings.append(f"MRA contains empty rom nodes: {path}")
        records.append(record)
    status = "PASS" if not errors else "FAIL"
    return {
        "schema": "mister-mra-report-v4",
        "created_utc": utc_now(),
        "status": status,
        "ok": status == "PASS",
        "checked": len(records),
        "errors": errors,
        "issues": list(errors),
        "warnings": warnings,
        "mras": records,
    }
