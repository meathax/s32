from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from .process import global_data_root
from .util import atomic_write_json, load_json, sha256_file, stable_hash, utc_now


class ReferenceCache:
    """Global cache for independently proven deterministic MAME reference traces."""

    def __init__(self) -> None:
        self.root = global_data_root() / "reference-cache"

    def key(self, identity: dict[str, Any]) -> str:
        return stable_hash(identity)

    def entry_dir(self, key: str) -> Path:
        return self.root / key

    @staticmethod
    def _meta_path(path: Path) -> Path:
        return path.with_name(path.name + ".meta.json")

    def restore(self, key: str, destination: Path) -> dict[str, Any] | None:
        entry = self.entry_dir(key)
        manifest = load_json(entry / "manifest.json")
        trace = entry / "reference.normalized.jsonl"
        metadata = self._meta_path(trace)
        if not isinstance(manifest, dict) or not trace.exists() or not metadata.exists():
            return None
        if manifest.get("deterministic") is not True or manifest.get("identity_hash") != key:
            return None
        expected_hash = manifest.get("trace_sha256")
        expected_meta_hash = manifest.get("metadata_sha256")
        if not isinstance(expected_hash, str) or sha256_file(trace) != expected_hash:
            return None
        if not isinstance(expected_meta_hash, str) or sha256_file(metadata) != expected_meta_hash:
            return None
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(trace, destination)
        shutil.copy2(metadata, self._meta_path(destination))
        return manifest

    def store(
        self,
        key: str,
        normalized_trace: Path,
        *,
        identity: dict[str, Any],
        determinism_report: dict[str, Any],
    ) -> Path:
        if determinism_report.get("status") != "MATCH":
            raise ValueError("Nondeterministic reference traces may never be cached.")
        source_metadata = self._meta_path(normalized_trace)
        if not source_metadata.exists():
            raise ValueError("A reference trace may be cached only with verified normalization metadata.")
        if key != stable_hash(identity):
            raise ValueError("Reference-cache key does not match the supplied identity.")
        entry = self.entry_dir(key)
        entry.mkdir(parents=True, exist_ok=True)
        cached_trace = entry / "reference.normalized.jsonl"
        cached_metadata = self._meta_path(cached_trace)
        shutil.copy2(normalized_trace, cached_trace)
        shutil.copy2(source_metadata, cached_metadata)
        manifest = {
            "schema": "mister-reference-cache-v4",
            "created_utc": utc_now(),
            "deterministic": True,
            "trace_sha256": sha256_file(cached_trace),
            "metadata_sha256": sha256_file(cached_metadata),
            "identity_hash": key,
            "identity": identity,
            "determinism_report": determinism_report,
        }
        atomic_write_json(entry / "manifest.json", manifest)
        return entry
