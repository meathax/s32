from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .util import atomic_write_json, git_info, load_json, sha256_file, utc_now


LICENSE_NAMES = (
    "LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYING.txt",
    "COPYING.md", "COPYRIGHT", "NOTICE",
)
LICENSE_HINTS = {
    "gpl-3": re.compile(r"GNU GENERAL PUBLIC LICENSE\s+Version 3", re.I),
    "gpl-2": re.compile(r"GNU GENERAL PUBLIC LICENSE\s+Version 2", re.I),
    "lgpl": re.compile(r"GNU LESSER GENERAL PUBLIC LICENSE", re.I),
    "mit": re.compile(r"MIT License|Permission is hereby granted, free of charge", re.I),
    "bsd": re.compile(r"Redistribution and use in source and binary forms", re.I),
    "apache-2.0": re.compile(r"Apache License\s+Version 2", re.I),
    "mpl-2.0": re.compile(r"Mozilla Public License\s+Version 2", re.I),
}


def find_license_files(path: Path) -> list[Path]:
    found: list[Path] = []
    for candidate in path.iterdir() if path.exists() and path.is_dir() else []:
        if candidate.is_file() and candidate.name.lower() in {name.lower() for name in LICENSE_NAMES}:
            found.append(candidate)
    return sorted(found)


def identify_license(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")[:100000]
    except OSError:
        return "unknown"
    for name, pattern in LICENSE_HINTS.items():
        if pattern.search(text):
            return name
    return "unclassified"


def scan_donor(path: Path, *, source_url: str | None = None, label: str | None = None) -> dict[str, Any]:
    path = path.resolve()
    if not path.exists() or not path.is_dir():
        raise ValueError(f"Donor path does not exist: {path}")
    git = git_info(path)
    license_files = find_license_files(path)
    hdl = [
        p for p in path.rglob("*")
        if p.is_file() and p.suffix.lower() in {".sv", ".v", ".vhd", ".vhdl"}
        and ".git" not in p.parts
    ]
    records = []
    for license_file in license_files:
        records.append({
            "path": str(license_file.relative_to(path)),
            "sha256": sha256_file(license_file),
            "classification": identify_license(license_file),
        })
    return {
        "schema": "mister-donor-provenance-v4",
        "recorded_utc": utc_now(),
        "label": label or path.name,
        "local_path": str(path),
        "source_url": source_url or git.get("remote"),
        "commit": git.get("commit"),
        "dirty": git.get("dirty"),
        "license_files": records,
        "license_status": "recorded" if records else "MISSING",
        "hdl_file_count": len(hdl),
        "reuse_status": "candidate",
        "reuse_plan": [],
        "obligations_reviewed": False,
        "notes": (
            "Automated license identification is only a clue. Codex must read the actual license, "
            "preserve notices, record copied/adapted files and reject unclear reuse."
        ),
    }


def add_donor(root: Path, donor: dict[str, Any]) -> Path:
    path = root / "docs/PROVENANCE.json"
    data = load_json(path, default={"schema_version": 4, "donors": [], "reused_files": []})
    if not isinstance(data, dict):
        data = {"schema_version": 4, "donors": [], "reused_files": []}
    donors = list(data.get("donors", []))
    key = (donor.get("source_url"), donor.get("commit"), donor.get("local_path"))
    donors = [
        existing for existing in donors
        if (existing.get("source_url"), existing.get("commit"), existing.get("local_path")) != key
    ]
    donors.append(donor)
    data["schema_version"] = 4
    data["donors"] = donors
    data.setdefault("reused_files", [])
    atomic_write_json(path, data)

    license_dest = root / ".mister/provenance/licenses"
    donor_path = Path(donor["local_path"])
    for record in donor.get("license_files", []):
        source = donor_path / record["path"]
        if source.exists():
            destination = license_dest / f"{donor.get('label','donor')}-{source.name}"
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    return path


def validate_provenance(root: Path) -> dict[str, list[str]]:
    data = load_json(root / "docs/PROVENANCE.json", default={})
    errors: list[str] = []
    warnings: list[str] = []
    donors = data.get("donors", []) if isinstance(data, dict) else []
    for index, donor in enumerate(donors):
        prefix = f"donors[{index}]"
        if not donor.get("source_url"):
            warnings.append(f"{prefix}.source_url is missing.")
        if not donor.get("commit"):
            errors.append(f"{prefix}.commit is missing; floating donor sources are not reproducible.")
        if donor.get("license_status") != "recorded":
            errors.append(f"{prefix} has no recorded license.")
        if donor.get("reuse_status") == "used" and donor.get("obligations_reviewed") is not True:
            errors.append(f"{prefix} is marked used but license obligations are not reviewed.")
    reused = data.get("reused_files", []) if isinstance(data, dict) else []
    for index, record in enumerate(reused):
        for field in ("project_path", "donor_label", "donor_path", "mode"):
            if not record.get(field):
                errors.append(f"reused_files[{index}].{field} is required.")
    return {"errors": errors, "warnings": warnings}


def fetch_donor(
    root: Path,
    *,
    source_url: str,
    ref: str = "HEAD",
    label: str | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Clone a donor read-only-ish at an immutable detached commit and record provenance."""
    safe_label = re.sub(r"[^A-Za-z0-9._-]+", "-", label or Path(source_url.rstrip("/")).stem).strip("-")
    if not safe_label:
        safe_label = "donor"
    destination = root / ".mister/donors" / safe_label
    if destination.exists():
        raise ValueError(
            f"Donor destination already exists: {destination}. Reuse/inspect it or choose another label."
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    clone = subprocess.run(
        ["git", "clone", "--no-checkout", "--filter=blob:none", source_url, str(destination)],
        capture_output=True, text=True, check=False, timeout=1800,
    )
    if clone.returncode != 0:
        shutil.rmtree(destination, ignore_errors=True)
        clone = subprocess.run(
            ["git", "clone", "--no-checkout", source_url, str(destination)],
            capture_output=True, text=True, check=False, timeout=1800,
        )
    if clone.returncode != 0:
        shutil.rmtree(destination, ignore_errors=True)
        raise ValueError(f"git clone failed: {(clone.stderr or clone.stdout)[-4000:]}")
    fetch = subprocess.run(
        ["git", "-C", str(destination), "fetch", "--depth", "1", "origin", ref],
        capture_output=True, text=True, check=False, timeout=1800,
    )
    if fetch.returncode != 0:
        shutil.rmtree(destination, ignore_errors=True)
        raise ValueError(f"git fetch {ref!r} failed: {(fetch.stderr or fetch.stdout)[-4000:]}")
    checkout = subprocess.run(
        ["git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"],
        capture_output=True, text=True, check=False, timeout=300,
    )
    if checkout.returncode != 0:
        shutil.rmtree(destination, ignore_errors=True)
        raise ValueError(f"git checkout failed: {(checkout.stderr or checkout.stdout)[-4000:]}")
    record = scan_donor(destination, source_url=source_url, label=safe_label)
    record["requested_ref"] = ref
    path = add_donor(root, record)
    return path, record
