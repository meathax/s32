from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Mapping

from .config import compute_jobs, task_config
from .locking import FileLock
from .util import (
    atomic_write_json,
    autopilot_data_root,
    expand_argv,
    expand_vars,
    hash_tree,
    sha256_file,
    stable_hash,
    timestamp_id,
    tool_identity,
    utc_now,
)


class TaskError(RuntimeError):
    pass


def global_data_root() -> Path:
    return autopilot_data_root()


def _terminate_tree(proc: subprocess.Popen[Any]) -> None:
    if proc.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        time.sleep(1)
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


class TaskRunner:
    """Run configured argv tasks without a shell and with content-verified caching."""

    def __init__(self, root: Path, config: dict[str, Any]):
        self.root = root.resolve()
        self.config = config
        self.data_root = global_data_root()

    def _variables(
        self,
        run_dir: Path | None,
        extra_env: Mapping[str, str] | None,
    ) -> dict[str, str]:
        paths = self.config.get("paths", {})
        variables = {
            "PROJECT": str(self.root),
            "RUN_DIR": str(run_dir or self.root / ".mister/runs/manual"),
            "MAME_EXE": str(paths.get("mame_exe", "")),
            "MAME_SOURCE": str(paths.get("mame_source", "")),
            "MAME_ROMS": str(paths.get("mame_roms", "")),
            "VERILATOR": str(paths.get("verilator", "verilator")),
            "QUARTUS_ROOT": str(paths.get("quartus_root", "")),
            "MISTER_JOBS": str(compute_jobs(self.config)),
            "PYTHON": sys.executable,
        }
        if extra_env:
            variables.update({str(k): str(v) for k, v in extra_env.items()})
        return variables

    def fingerprint(self, name: str, task: dict[str, Any]) -> str:
        cache = task.get("cache", {})
        inputs = cache.get("inputs", []) if isinstance(cache, dict) else []
        if not isinstance(inputs, list):
            inputs = []
        source_hash = hash_tree(self.root, [str(x) for x in inputs]) if inputs else "NO_INPUTS"
        variables = self._variables(None, None)
        argv = task.get("argv", [])
        expanded_argv = expand_argv(argv, variables) if isinstance(argv, list) else argv
        executable = expanded_argv[0] if isinstance(expanded_argv, list) and expanded_argv else ""
        identity = tool_identity(str(executable)) if executable else {}
        configured_env = task.get("env", {}) if isinstance(task.get("env", {}), dict) else {}
        expanded_env = {
            str(key): expand_vars(str(value), variables)
            for key, value in configured_env.items()
        }
        return stable_hash(
            {
                "task": name,
                "argv": expanded_argv,
                "cwd": expand_vars(str(task.get("cwd", ".")), variables),
                "env": expanded_env,
                "source_hash": source_hash,
                "tool": identity,
                "jobs": variables["MISTER_JOBS"],
            }
        )

    def _cache_outputs(self, task: dict[str, Any], variables: Mapping[str, str]) -> list[Path]:
        cache_cfg = task.get("cache", {})
        declared = cache_cfg.get("outputs", []) if isinstance(cache_cfg, dict) else []
        if not isinstance(declared, list):
            raise TaskError("task.cache.outputs must be an array of paths or glob patterns.")
        outputs: list[Path] = []
        for item in declared:
            value = expand_vars(str(item), variables)
            candidate = Path(value)
            if candidate.is_absolute():
                matches = [candidate] if candidate.exists() else []
            else:
                matches = list(self.root.glob(value))
            outputs.extend(path.resolve() for path in matches if path.exists())
        return sorted(set(outputs), key=lambda path: str(path).lower())

    def _display_path(self, path: Path) -> str:
        try:
            return path.relative_to(self.root).as_posix()
        except ValueError:
            return str(path)

    @staticmethod
    def _directory_hash(path: Path) -> tuple[str, int, int]:
        records: list[dict[str, Any]] = []
        total_size = 0
        file_count = 0
        for child in sorted(path.rglob("*"), key=lambda item: item.as_posix().lower()):
            if not child.is_file():
                continue
            rel = child.relative_to(path).as_posix()
            size = child.stat().st_size
            records.append({"path": rel, "size": size, "sha256": sha256_file(child)})
            total_size += size
            file_count += 1
        return stable_hash(records), file_count, total_size

    def _output_manifest(
        self,
        task: dict[str, Any],
        variables: Mapping[str, str],
    ) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for path in self._cache_outputs(task, variables):
            if path.is_file():
                stat = path.stat()
                records.append(
                    {
                        "path": self._display_path(path),
                        "kind": "file",
                        "size": stat.st_size,
                        "sha256": sha256_file(path),
                    }
                )
            elif path.is_dir():
                digest, file_count, total_size = self._directory_hash(path)
                records.append(
                    {
                        "path": self._display_path(path),
                        "kind": "directory",
                        "file_count": file_count,
                        "total_size": total_size,
                        "tree_sha256": digest,
                    }
                )
        return records

    def run(
        self,
        name: str,
        *,
        run_dir: Path | None = None,
        extra_env: Mapping[str, str] | None = None,
        force: bool = False,
    ) -> dict[str, Any]:
        task = task_config(self.config, name)
        if not task.get("enabled"):
            raise TaskError(f"Task '{name}' is disabled.")
        argv = task.get("argv")
        if not isinstance(argv, list) or not argv or any(not isinstance(x, str) for x in argv):
            raise TaskError(f"Task '{name}' requires a non-empty argv array of strings.")
        timeout_s = int(task.get("timeout_s", 3600))
        if timeout_s <= 0:
            raise TaskError(f"Task '{name}' has an invalid timeout.")

        run_dir = (run_dir or self.root / ".mister/runs" / f"task-{name}-{timestamp_id()}").resolve()
        run_dir.mkdir(parents=True, exist_ok=True)
        variables = self._variables(run_dir, extra_env)
        expanded_argv = expand_argv(argv, variables)
        cwd = Path(expand_vars(str(task.get("cwd", ".")), variables))
        if not cwd.is_absolute():
            cwd = self.root / cwd
        cwd = cwd.resolve()
        if not cwd.exists():
            raise TaskError(f"Task '{name}' working directory does not exist: {cwd}")

        env = os.environ.copy()
        env.update(variables)
        configured_env = task.get("env", {})
        if not isinstance(configured_env, dict):
            raise TaskError(f"Task '{name}'.env must be an object.")
        env.update({str(k): expand_vars(str(v), variables) for k, v in configured_env.items()})
        env.setdefault("MAKEFLAGS", f"-j{variables['MISTER_JOBS']}")
        env.setdefault("CMAKE_BUILD_PARALLEL_LEVEL", variables["MISTER_JOBS"])

        fingerprint = self.fingerprint(name, task)
        cache_cfg = task.get("cache", {})
        cache_requested = bool(isinstance(cache_cfg, dict) and cache_cfg.get("enabled"))
        declared_outputs = cache_cfg.get("outputs", []) if isinstance(cache_cfg, dict) else []
        cache_enabled = cache_requested and isinstance(declared_outputs, list) and bool(declared_outputs)
        cache_dir = self.root / ".mister/cache/tasks" / name / fingerprint
        cached_result_path = cache_dir / "result.json"
        if cache_enabled and not force and cached_result_path.exists():
            try:
                cached = json.loads(cached_result_path.read_text(encoding="utf-8-sig"))
            except (OSError, json.JSONDecodeError):
                cached = {}
            expected_manifest = cached.get("cache_output_manifest")
            current_manifest = self._output_manifest(task, variables)
            if (
                cached.get("returncode") == 0
                and isinstance(expected_manifest, list)
                and expected_manifest
                and current_manifest == expected_manifest
            ):
                result = dict(cached)
                result.update(
                    {
                        "cached": True,
                        "cache_verified": True,
                        "cache_source_run_dir": cached.get("run_dir"),
                        "reused_utc": utc_now(),
                        "run_dir": str(run_dir),
                    }
                )
                atomic_write_json(run_dir / "task-result.json", result)
                return result

        pre_output_manifest = self._output_manifest(task, variables) if cache_enabled else []

        stdout_path = run_dir / "stdout.log"
        stderr_path = run_dir / "stderr.log"
        start_record = {
            "schema": "mister-task-start-v4",
            "task": name,
            "created_utc": utc_now(),
            "argv": expanded_argv,
            "cwd": str(cwd),
            "timeout_s": timeout_s,
            "heavy": bool(task.get("heavy")),
            "fingerprint": fingerprint,
        }
        atomic_write_json(run_dir / "task-start.json", start_record)

        creationflags = 0
        popen_kwargs: dict[str, Any] = {}
        if os.name == "nt":
            creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        else:
            popen_kwargs["start_new_session"] = True

        lock_path = self.data_root / "locks/heavy.lock"
        lock_timeout = int(self.config.get("resources", {}).get("global_lock_timeout_s", 7200))
        lock = FileLock(lock_path, timeout_s=lock_timeout) if task.get("heavy") else None

        started = time.monotonic()
        returncode = -1
        timed_out = False
        try:
            context = lock if lock is not None else _NullContext()
            with context:
                with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
                    proc = subprocess.Popen(
                        expanded_argv,
                        cwd=str(cwd),
                        env=env,
                        stdin=subprocess.DEVNULL,
                        stdout=stdout,
                        stderr=stderr,
                        shell=False,
                        creationflags=creationflags,
                        **popen_kwargs,
                    )
                    try:
                        returncode = int(proc.wait(timeout=timeout_s))
                    except subprocess.TimeoutExpired:
                        timed_out = True
                        _terminate_tree(proc)
                        try:
                            returncode = int(proc.wait(timeout=30))
                        except subprocess.TimeoutExpired:
                            returncode = -9
                    except BaseException:
                        # A cancelled Codex turn or Ctrl+C must not leave Verilator,
                        # MAME, ModelSim or Quartus running after the executor exits.
                        _terminate_tree(proc)
                        try:
                            proc.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            pass
                        raise
        except OSError as exc:
            raise TaskError(f"Failed to start task '{name}': {exc}") from exc

        result: dict[str, Any] = {
            "schema": "mister-task-result-v4",
            "task": name,
            "completed_utc": utc_now(),
            "argv": expanded_argv,
            "cwd": str(cwd),
            "returncode": returncode,
            "timed_out": timed_out,
            "duration_s": round(time.monotonic() - started, 3),
            "stdout": str(stdout_path),
            "stderr": str(stderr_path),
            "fingerprint": fingerprint,
            "cached": False,
            "run_dir": str(run_dir),
        }

        if cache_enabled and returncode == 0 and not timed_out:
            output_manifest = self._output_manifest(task, variables)
            if not output_manifest:
                result["cache_skipped_reason"] = "declared cache outputs were not created"
            elif output_manifest == pre_output_manifest and pre_output_manifest:
                result["cache_skipped_reason"] = (
                    "declared outputs were unchanged by this successful task; stale outputs were not cached"
                )
            else:
                result["cache_output_manifest"] = output_manifest
                cache_dir.mkdir(parents=True, exist_ok=True)
                atomic_write_json(cached_result_path, result)
        atomic_write_json(run_dir / "task-result.json", result)

        if timed_out:
            raise TaskError(f"Task '{name}' timed out after {timeout_s}s. Logs: {run_dir}")
        if returncode != 0:
            raise TaskError(f"Task '{name}' failed with exit code {returncode}. Logs: {run_dir}")
        return result


class _NullContext:
    def __enter__(self) -> "_NullContext":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        return None
