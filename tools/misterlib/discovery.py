from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Any
from xml.etree import ElementTree

from .util import atomic_write_json, run_capture, tool_identity, utc_now


MODULE_RE = re.compile(r"(?m)^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)")
QSF_TOP_RE = re.compile(r"set_global_assignment\s+-name\s+TOP_LEVEL_ENTITY\s+(\S+)", re.I)
QSF_SDC_RE = re.compile(r"set_global_assignment\s+-name\s+SDC_FILE\s+(.+)", re.I)
QPF_REV_RE = re.compile(r"PROJECT_REVISION\s*=\s*\"?([^\"\r\n]+)", re.I)


def _first_files(root: Path, patterns: list[str], limit: int = 100) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if path.is_file():
                rel = path.relative_to(root).as_posix()
                if rel not in seen:
                    seen.add(rel)
                    out.append(rel)
                    if len(out) >= limit:
                        return out
    return out


def discover(root: Path, config: dict[str, Any] | None = None) -> dict[str, Any]:
    root = root.resolve()
    qpf_files = _first_files(root, ["*.qpf", "**/*.qpf"])
    qsf_files = _first_files(root, ["*.qsf", "**/*.qsf"])
    sdc_files = _first_files(root, ["*.sdc", "**/*.sdc"])
    hdl_files = _first_files(root, ["**/*.sv", "**/*.v", "**/*.vhd", "**/*.vhdl"], limit=500)
    build_files = _first_files(
        root, ["Makefile", "**/Makefile", "*.mk", "**/*.mk", "CMakeLists.txt", "**/CMakeLists.txt", "*.bat", "*.cmd", "*.ps1"],
        limit=100
    )
    mra_files = _first_files(root, ["**/*.mra"], limit=50)
    rbf_files = _first_files(root, ["**/*.rbf"], limit=50)
    modules: list[dict[str, str]] = []
    for rel in hdl_files[:250]:
        path = root / rel
        if path.suffix.lower() not in {".sv", ".v"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for match in MODULE_RE.finditer(text):
            modules.append({"module": match.group(1), "file": rel})

    quartus: dict[str, Any] = {"qpf_files": qpf_files, "qsf_files": qsf_files, "sdc_files": sdc_files}
    if qpf_files:
        text = (root / qpf_files[0]).read_text(encoding="utf-8", errors="replace")
        match = QPF_REV_RE.search(text)
        if match:
            quartus["revision_candidate"] = match.group(1).strip()
    if qsf_files:
        text = (root / qsf_files[0]).read_text(encoding="utf-8", errors="replace")
        top = QSF_TOP_RE.search(text)
        if top:
            quartus["top_candidate"] = top.group(1).strip().strip('"')
        qsf_sdcs = [m.group(1).strip().strip('"') for m in QSF_SDC_RE.finditer(text)]
        if qsf_sdcs:
            quartus["qsf_sdc_candidates"] = qsf_sdcs

    mra: list[dict[str, Any]] = []
    for rel in mra_files:
        try:
            tree = ElementTree.parse(root / rel)
            root_xml = tree.getroot()
            setname = root_xml.findtext(".//setname")
            rbf = root_xml.findtext(".//rbf")
            mra.append({"file": rel, "setname": setname, "rbf": rbf})
        except (ElementTree.ParseError, OSError):
            mra.append({"file": rel, "parse_error": True})

    tool_requests = {}
    if config:
        paths = config.get("paths", {})
        for key in ("mame_exe", "verilator"):
            value = paths.get(key)
            if isinstance(value, str) and value:
                tool_requests[key] = tool_identity(value)
        qroot = paths.get("quartus_root")
        if isinstance(qroot, str) and qroot:
            candidates = [
                Path(qroot) / "quartus/bin64/quartus_sh.exe",
                Path(qroot) / "quartus/bin/quartus_sh.exe",
                Path(qroot) / "bin64/quartus_sh.exe",
            ]
            resolved = next((p for p in candidates if p.exists()), None)
            tool_requests["quartus_sh"] = tool_identity(str(resolved or "quartus_sh"))

    result = {
        "schema": "mister-discovery-v4",
        "created_utc": utc_now(),
        "root": str(root),
        "quartus": quartus,
        "hdl": {"files": hdl_files, "modules": modules},
        "build_files": build_files,
        "mra": mra,
        "rbf_files": rbf_files,
        "tools": tool_requests,
        "recommendations": [],
    }
    if not qpf_files:
        result["recommendations"].append("No Quartus QPF was found.")
    if not modules:
        result["recommendations"].append("No Verilog/SystemVerilog modules were found.")
    if mra and mra[0].get("setname"):
        result["mame_shortname_candidate"] = mra[0]["setname"]
    return result


def write_discovery(root: Path, result: dict[str, Any]) -> Path:
    path = root / ".mister/discovery.json"
    atomic_write_json(path, result)
    return path
