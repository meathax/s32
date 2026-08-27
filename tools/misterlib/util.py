from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


AUTO_VALUES = {"", "AUTO", "REPLACE_ME", None}
_TOOL_ID_CACHE: dict[tuple[str, int, int], dict[str, Any]] = {}
_PERSISTENT_TOOL_CACHE: tuple[Path, dict[str, Any]] | None = None


def autopilot_data_root() -> Path:
    """Return the global cache/lock root, with an explicit override for tests and automation."""
    override = os.environ.get("MISTER_AUTOPILOT_DATA_ROOT")
    if override:
        return Path(os.path.expandvars(override)).expanduser().resolve()
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData/Local")))
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    return base / "MiSTerFPGA-Autopilot-v5"


def _tool_identity_cache_path() -> Path:
    return autopilot_data_root() / "tool-identities.json"


def _load_persistent_tool_cache() -> dict[str, Any]:
    global _PERSISTENT_TOOL_CACHE
    path = _tool_identity_cache_path().resolve()
    if _PERSISTENT_TOOL_CACHE is not None and _PERSISTENT_TOOL_CACHE[0] == path:
        return _PERSISTENT_TOOL_CACHE[1]
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        data = {}
    if not isinstance(data, dict) or data.get("schema") != "mister-tool-identity-cache-v1":
        data = {"schema": "mister-tool-identity-cache-v1", "entries": {}}
    if not isinstance(data.get("entries"), dict):
        data["entries"] = {}
    _PERSISTENT_TOOL_CACHE = (path, data)
    return data


def _store_persistent_tool_cache() -> None:
    if _PERSISTENT_TOOL_CACHE is None:
        return
    path, data = _PERSISTENT_TOOL_CACHE
    try:
        atomic_write_json(path, data)
    except OSError:
        pass


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def timestamp_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def slugify(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip())
    return value.strip("-").lower() or "core"


def load_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def atomic_write_json(path: Path, data: Any) -> None:
    atomic_write_text(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path, *, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def hash_tree(
    root: Path,
    patterns: Sequence[str],
    *,
    exclude_parts: Sequence[str] = (".git", ".mister", "obj_dir", "output_files", "db", "incremental_db"),
) -> str:
    records: list[str] = []
    seen: set[Path] = set()
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if not path.is_file():
                continue
            try:
                rel = path.relative_to(root)
            except ValueError:
                rel = path
            if any(part in exclude_parts for part in rel.parts):
                continue
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            records.append(f"{rel.as_posix()}\0{sha256_file(path)}")
    return sha256_bytes("\n".join(records).encode("utf-8"))


def hash_optional_file(path: Path | None) -> str:
    if path is None or not path.exists() or not path.is_file():
        return "MISSING"
    return sha256_file(path)


def stable_hash(data: Any) -> str:
    payload = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return sha256_bytes(payload.encode("utf-8"))


def deep_merge(base: dict[str, Any], overlay: Mapping[str, Any]) -> dict[str, Any]:
    out = dict(base)
    for key, value in overlay.items():
        if isinstance(value, Mapping) and isinstance(out.get(key), Mapping):
            out[key] = deep_merge(dict(out[key]), value)
        else:
            out[key] = value
    return out


_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def expand_vars(value: str, variables: Mapping[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        if key in variables:
            return str(variables[key])
        return os.environ.get(key, match.group(0))
    return _VAR_RE.sub(replace, value)


def expand_argv(argv: Sequence[str], variables: Mapping[str, str]) -> list[str]:
    return [expand_vars(str(item), variables) for item in argv]


def is_auto(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip() in AUTO_VALUES
    return value in AUTO_VALUES


def ensure_relative(root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def executable_exists(value: str) -> bool:
    path = Path(value)
    if path.is_absolute():
        return path.exists()
    return shutil.which(value) is not None


def git_info(root: Path) -> dict[str, Any]:
    result: dict[str, Any] = {
        "available": False,
        "commit": None,
        "branch": None,
        "dirty": None,
        "remote": None,
        "diff_sha256": None,
    }
    try:
        top = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            check=True, capture_output=True, text=True, timeout=10
        ).stdout.strip()
        result["available"] = True
        result["root"] = top
        result["commit"] = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True, timeout=10
        ).stdout.strip()
        result["branch"] = subprocess.run(
            ["git", "-C", str(root), "branch", "--show-current"],
            check=True, capture_output=True, text=True, timeout=10
        ).stdout.strip()
        status = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain=v1"],
            check=True, capture_output=True, text=True, timeout=10
        ).stdout
        result["dirty"] = bool(status.strip())
        diff = subprocess.run(
            ["git", "-C", str(root), "diff", "--binary", "HEAD"],
            check=True, capture_output=True, timeout=20
        ).stdout
        result["diff_sha256"] = sha256_bytes(diff)
        remote = subprocess.run(
            ["git", "-C", str(root), "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=10
        )
        if remote.returncode == 0:
            result["remote"] = remote.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return result


def run_capture(argv: Sequence[str], cwd: Path | None = None, timeout: int = 20) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            list(argv), cwd=str(cwd) if cwd else None, capture_output=True,
            text=True, errors="replace", timeout=timeout, check=False
        )
        return proc.returncode, proc.stdout, proc.stderr
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)


def tool_identity(executable: str) -> dict[str, Any]:
    path = shutil.which(executable) or executable
    p = Path(path)
    identity: dict[str, Any] = {"requested": executable, "resolved": str(p), "exists": p.exists()}
    cache_key: tuple[str, int, int] | None = None
    persistent_key: str | None = None
    if p.exists() and p.is_file():
        try:
            stat = p.stat()
            resolved = str(p.resolve())
            cache_key = (resolved, stat.st_size, stat.st_mtime_ns)
            cached = _TOOL_ID_CACHE.get(cache_key)
            if cached is not None:
                result = dict(cached)
                result["requested"] = executable
                return result
            persistent_key = resolved.lower() if os.name == "nt" else resolved
            persistent = _load_persistent_tool_cache().get("entries", {}).get(persistent_key)
            if (
                isinstance(persistent, dict)
                and persistent.get("size") == stat.st_size
                and persistent.get("mtime_ns") == stat.st_mtime_ns
                and isinstance(persistent.get("sha256"), str)
            ):
                result = dict(persistent)
                result.update({"requested": executable, "resolved": resolved, "exists": True})
                _TOOL_ID_CACHE[cache_key] = dict(result)
                return result
            identity.update({
                "resolved": resolved,
                "sha256": sha256_file(p),
                "size": stat.st_size,
                "mtime_ns": stat.st_mtime_ns,
            })
        except OSError:
            pass
    for flag in ("--version", "-V", "-version"):
        rc, out, err = run_capture([str(p), flag], timeout=10)
        text = (out + "\n" + err).strip()
        if rc == 0 and text:
            identity["version"] = text.splitlines()[0][:500]
            identity["version_flag"] = flag
            break
    if cache_key is not None:
        _TOOL_ID_CACHE[cache_key] = dict(identity)
    if persistent_key is not None and identity.get("sha256"):
        cache = _load_persistent_tool_cache()
        cache["entries"][persistent_key] = {
            key: value for key, value in identity.items() if key != "requested"
        }
        _store_persistent_tool_cache()
    return identity


def copytree_missing(src: Path, dst: Path, *, overwrite: bool = False) -> list[str]:
    copied: list[str] = []
    for path in sorted(src.rglob("*")):
        rel = path.relative_to(src)
        target = dst / rel
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and not overwrite:
            continue
        shutil.copy2(path, target)
        copied.append(rel.as_posix())
    return copied


def redact_mapping(data: Any) -> Any:
    secret_words = ("token", "password", "secret", "api_key", "apikey")
    if isinstance(data, Mapping):
        out = {}
        for key, value in data.items():
            if any(word in str(key).lower() for word in secret_words):
                out[key] = "<redacted>"
            else:
                out[key] = redact_mapping(value)
        return out
    if isinstance(data, list):
        return [redact_mapping(v) for v in data]
    return data


def write_markdown_table(rows: Sequence[Mapping[str, Any]], columns: Sequence[str]) -> str:
    if not rows:
        return "_None._\n"
    header = "| " + " | ".join(columns) + " |\n"
    separator = "| " + " | ".join("---" for _ in columns) + " |\n"
    body = ""
    for row in rows:
        body += "| " + " | ".join(str(row.get(column, "")).replace("|", "\\|") for column in columns) + " |\n"
    return header + separator + body
