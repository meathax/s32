from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any, Mapping

from . import SCHEMA_VERSION, __version__
from .util import ensure_relative, is_auto, load_json, stable_hash


CONFIG_REL = Path(".mister/project.json")
SCHEMA_REL = Path(".mister/project.schema.json")
OBS_REL = Path("docs/OBSERVABILITY.json")
STATE_REL = Path(".mister/state.json")


def _version_tuple(value: Any) -> tuple[int, int, int] | None:
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", value.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


class ConfigError(ValueError):
    pass


def config_path(root: Path) -> Path:
    return root / CONFIG_REL


def load_config(root: Path) -> dict[str, Any]:
    path = config_path(root)
    data = load_json(path)
    if data is None:
        raise ConfigError(f"Missing {CONFIG_REL.as_posix()}; bootstrap the repository first.")
    if not isinstance(data, dict):
        raise ConfigError("Project configuration must be a JSON object.")
    return data


def save_config(root: Path, config: dict[str, Any]) -> None:
    from .util import atomic_write_json

    atomic_write_json(config_path(root), config)


def task_config(config: dict[str, Any], name: str) -> dict[str, Any]:
    tasks = config.get("tasks", {})
    if not isinstance(tasks, dict):
        raise ConfigError("tasks must be an object.")
    task = tasks.get(name)
    if not isinstance(task, dict):
        raise ConfigError(f"Task {name!r} is not defined.")
    return task


def task_is_ready(config: dict[str, Any], name: str) -> bool:
    try:
        task = task_config(config, name)
    except ConfigError:
        return False
    argv = task.get("argv")
    return bool(task.get("enabled")) and isinstance(argv, list) and bool(argv) and all(
        isinstance(item, str) and item for item in argv
    )


def _object(config: Mapping[str, Any], key: str, errors: list[str]) -> dict[str, Any]:
    value = config.get(key)
    if not isinstance(value, dict):
        errors.append(f"{key} must be an object.")
        return {}
    return value


def _string(value: Any, path: str, errors: list[str], *, allow_empty: bool = False) -> None:
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        errors.append(f"{path} must be a non-empty string." if not allow_empty else f"{path} must be a string.")


def _bool(value: Any, path: str, errors: list[str]) -> None:
    if not isinstance(value, bool):
        errors.append(f"{path} must be boolean.")


def _positive_int(value: Any, path: str, errors: list[str], *, minimum: int = 1) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        errors.append(f"{path} must be an integer >= {minimum}.")


def _string_list(value: Any, path: str, errors: list[str], *, nonempty: bool = False) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        errors.append(f"{path} must be an array of non-empty strings.")
        return []
    if nonempty and not value:
        errors.append(f"{path} must contain at least one item.")
    if len(set(value)) != len(value):
        errors.append(f"{path} must not contain duplicates.")
    return list(value)


def _required_project_fields(config: dict[str, Any]) -> list[tuple[str, Any]]:
    project = config.get("project", {}) if isinstance(config.get("project"), dict) else {}
    mame = config.get("mame", {}) if isinstance(config.get("mame"), dict) else {}
    rtl = config.get("rtl", {}) if isinstance(config.get("rtl"), dict) else {}
    return [
        ("project.name", project.get("name")),
        ("project.game", project.get("game")),
        ("project.board", project.get("board")),
        ("mame.shortname", mame.get("shortname")),
        ("mame.driver_source", mame.get("driver_source")),
        ("rtl.top", rtl.get("top")),
        ("rtl.simulation_top", rtl.get("simulation_top")),
    ]


def validate_config(root: Path, config: dict[str, Any], *, action: str = "doctor") -> dict[str, list[str]]:
    """Validate the dependency-free runtime contract.

    The shipped JSON Schema is additionally checked during package/install verification.
    This validator intentionally duplicates the safety-critical constraints so project use
    never depends on a third-party Python package.
    """

    errors: list[str] = []
    warnings: list[str] = []

    if config.get("schema_version") != SCHEMA_VERSION:
        errors.append(
            f"schema_version must be {SCHEMA_VERSION}; found {config.get('schema_version')!r}. "
            "Run the global mister upgrade/bootstrap command."
        )

    runtime = _object(config, "runtime", errors)
    _string(runtime.get("managed_version"), "runtime.managed_version", errors)
    _string(runtime.get("minimum_version"), "runtime.minimum_version", errors)
    installed_version = _version_tuple(__version__)
    minimum_version = _version_tuple(runtime.get("minimum_version"))
    managed_version = _version_tuple(runtime.get("managed_version"))
    if minimum_version is None:
        errors.append("runtime.minimum_version must be a semantic version such as 5.1.1.")
    elif installed_version is not None and installed_version < minimum_version:
        errors.append(
            f"Project requires runtime {runtime.get('minimum_version')} or newer; installed runtime is {__version__}."
        )
    if managed_version is None:
        errors.append("runtime.managed_version must be a semantic version such as 5.1.1.")
    elif runtime.get("managed_version") != __version__:
        warnings.append(
            f"Project runtime was generated by {runtime.get('managed_version')}; installed runtime is {__version__}. "
            "Run the project upgrade before relying on cached evidence."
        )

    project = _object(config, "project", errors)
    for key in ("name", "game", "board", "status"):
        _string(project.get(key), f"project.{key}", errors)

    paths = _object(config, "paths", errors)
    for key in ("mame_exe", "mame_source", "mame_roms", "mame_mcp_root", "verilator", "quartus_root", "modelsim_root"):
        _string(paths.get(key), f"paths.{key}", errors, allow_empty=False)

    mame = _object(config, "mame", errors)
    for key in ("shortname", "driver_source", "machine", "capture_task", "version_expected"):
        _string(mame.get(key), f"mame.{key}", errors)
    _string_list(mame.get("rom_files"), "mame.rom_files", errors)
    _string_list(mame.get("source_inputs"), "mame.source_inputs", errors)
    _string_list(mame.get("supported_setnames"), "mame.supported_setnames", errors)
    _bool(mame.get("reference_mutation_forbidden"), "mame.reference_mutation_forbidden", errors)

    rtl = _object(config, "rtl", errors)
    for key in ("top", "simulation_top", "lint_task", "build_task", "capture_task", "regression_task"):
        _string(rtl.get(key), f"rtl.{key}", errors)
    _string_list(rtl.get("source_globs"), "rtl.source_globs", errors, nonempty=True)

    quartus = _object(config, "quartus", errors)
    for key in ("qpf", "revision", "top", "analysis_task", "full_task", "output_rbf", "report_dir"):
        _string(quartus.get(key), f"quartus.{key}", errors)
    _string_list(quartus.get("sdc_files"), "quartus.sdc_files", errors)
    gates = quartus.get("gates")
    if not isinstance(gates, dict):
        errors.append("quartus.gates must be an object.")
        gates = {}
    for key in ("require_fresh_reports", "allow_unconstrained_paths"):
        _bool(gates.get(key), f"quartus.gates.{key}", errors)
    for key in ("max_errors", "max_critical_warnings"):
        value = gates.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            errors.append(f"quartus.gates.{key} must be an integer >= 0.")
    for key in ("min_setup_slack_ns", "min_hold_slack_ns"):
        value = gates.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            errors.append(f"quartus.gates.{key} must be numeric.")

    capture = _object(config, "capture", errors)
    if capture.get("raw_schema") != "mister-raw-trace-v4":
        errors.append("capture.raw_schema must be 'mister-raw-trace-v4'.")
    if capture.get("canonical_schema") != "mister-canonical-trace-v4":
        errors.append("capture.canonical_schema must be 'mister-canonical-trace-v4'.")
    for key, minimum in (
        ("context_events", 1), ("diagnostic_resync_window", 0), ("max_raw_trace_bytes", 1024),
        ("retain_successful_runs", 0), ("retain_failed_runs", 1),
    ):
        _positive_int(capture.get(key), f"capture.{key}", errors, minimum=minimum)
    _bool(capture.get("write_sha256_sidecars"), "capture.write_sha256_sidecars", errors)

    resources = _object(config, "resources", errors)
    for key, minimum in (
        ("max_heavy_jobs", 1), ("reserve_logical_cpus", 0), ("job_cap", 1), ("global_lock_timeout_s", 1),
    ):
        _positive_int(resources.get(key), f"resources.{key}", errors, minimum=minimum)
    job_count = resources.get("job_count")
    if job_count != "auto" and (isinstance(job_count, bool) or not isinstance(job_count, int) or job_count < 1):
        errors.append("resources.job_count must be 'auto' or a positive integer.")
    if resources.get("max_heavy_jobs", 1) != 1:
        warnings.append(
            "resources.max_heavy_jobs is not 1. Concurrent MAME/Verilator/ModelSim/Quartus work may "
            "invalidate timing measurements and make the workstation unresponsive."
        )

    tasks = _object(config, "tasks", errors)
    if not tasks:
        errors.append("At least one task is required.")
    for name, task in tasks.items():
        if not isinstance(name, str) or not name:
            errors.append("Task names must be non-empty strings.")
            continue
        if re.fullmatch(r"[A-Za-z0-9_.-]+", name) is None:
            errors.append(
                f"Task name {name!r} is unsafe; use only letters, digits, underscore, hyphen and dot."
            )
            continue
        if not isinstance(task, dict):
            errors.append(f"tasks.{name} must be an object.")
            continue
        _bool(task.get("enabled"), f"tasks.{name}.enabled", errors)
        argv = task.get("argv")
        if not isinstance(argv, list) or any(not isinstance(item, str) or not item for item in argv):
            errors.append(f"tasks.{name}.argv must be an array of strings containing non-empty argv elements; shell command strings are rejected.")
            argv = []
        if task.get("enabled") and not argv:
            errors.append(f"tasks.{name} is enabled but argv is empty.")
        _string(task.get("cwd"), f"tasks.{name}.cwd", errors)
        _positive_int(task.get("timeout_s"), f"tasks.{name}.timeout_s", errors)
        _bool(task.get("heavy"), f"tasks.{name}.heavy", errors)
        env = task.get("env", {})
        if not isinstance(env, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in env.items()):
            errors.append(f"tasks.{name}.env must be an object of string values.")
        cache = task.get("cache")
        if cache is not None:
            if not isinstance(cache, dict):
                errors.append(f"tasks.{name}.cache must be an object.")
            else:
                _bool(cache.get("enabled"), f"tasks.{name}.cache.enabled", errors)
                _string_list(cache.get("inputs"), f"tasks.{name}.cache.inputs", errors)
                _string_list(cache.get("outputs"), f"tasks.{name}.cache.outputs", errors)
                if cache.get("enabled") and not cache.get("outputs"):
                    warnings.append(
                        f"tasks.{name}.cache is enabled without declared outputs; cache hits will be refused."
                    )

    scenarios = _object(config, "scenarios", errors)
    if not scenarios:
        errors.append("At least one scenario is required.")
    for name, scenario in scenarios.items():
        if not isinstance(scenario, dict):
            errors.append(f"scenarios.{name} must be an object.")
            continue
        _bool(scenario.get("enabled"), f"scenarios.{name}.enabled", errors)
        _string(scenario.get("description"), f"scenarios.{name}.description", errors, allow_empty=True)
        domains = _string_list(scenario.get("domains"), f"scenarios.{name}.domains", errors, nonempty=True)
        _positive_int(scenario.get("capture_count"), f"scenarios.{name}.capture_count", errors, minimum=2)
        seed = scenario.get("seed")
        if isinstance(seed, bool) or not isinstance(seed, int) or seed < 0:
            errors.append(f"scenarios.{name}.seed must be an integer >= 0.")
        input_file = scenario.get("input_file")
        _string(input_file, f"scenarios.{name}.input_file", errors)
        if isinstance(input_file, str) and input_file and not ensure_relative(root, input_file).exists():
            warnings.append(f"scenarios.{name}.input_file does not exist: {input_file}")
        stop = scenario.get("stop")
        if not isinstance(stop, dict):
            errors.append(f"scenarios.{name}.stop must be an object.")
        else:
            if stop.get("kind") not in {"canonical_event_count", "frame_count", "checkpoint", "adapter_defined"}:
                errors.append(f"scenarios.{name}.stop.kind is unsupported.")
            if not isinstance(stop.get("value"), (int, str)) or isinstance(stop.get("value"), bool):
                errors.append(f"scenarios.{name}.stop.value must be a positive integer or non-empty string.")
        _bool(scenario.get("mame_cache"), f"scenarios.{name}.mame_cache", errors)
        _bool(scenario.get("release"), f"scenarios.{name}.release", errors)
        if not domains:
            continue

    workflow = _object(config, "workflow", errors)
    default_scenario = workflow.get("default_scenario")
    _string(default_scenario, "workflow.default_scenario", errors)
    if isinstance(default_scenario, str) and default_scenario not in scenarios:
        errors.append(f"workflow.default_scenario {default_scenario!r} is not defined.")
    for key in ("auto_fix", "checkpoint_bisection", "require_clean_observability", "stop_on_evidence_gap"):
        _bool(workflow.get(key), f"workflow.{key}", errors)
    _positive_int(workflow.get("max_iterations_per_session"), "workflow.max_iterations_per_session", errors)
    release_scenarios = _string_list(workflow.get("release_scenarios"), "workflow.release_scenarios", errors, nonempty=True)
    for scenario_name in release_scenarios:
        if scenario_name not in scenarios:
            errors.append(f"Release scenario {scenario_name!r} is not defined.")

    donors = config.get("donors")
    if not isinstance(donors, list):
        errors.append("donors must be an array.")

    hardware = _object(config, "hardware", errors)
    for key in ("mister_host", "deployment_task"):
        _string(hardware.get(key), f"hardware.{key}", errors)
    _bool(hardware.get("hardware_required_for_release"), "hardware.hardware_required_for_release", errors)

    mister = _object(config, "mister", errors)
    _string_list(mister.get("mra_files"), "mister.mra_files", errors)
    _string(mister.get("rbf_name"), "mister.rbf_name", errors)
    _bool(mister.get("require_mra_for_release"), "mister.require_mra_for_release", errors)
    _bool(mister.get("require_rom_mapping"), "mister.require_rom_mapping", errors)

    release = _object(config, "release", errors)
    for key in ("require_provenance", "require_fresh_rbf", "require_clean_observability", "allow_hardware_pending"):
        _bool(release.get(key), f"release.{key}", errors)

    unresolved_critical: list[str] = []
    for dotted, value in _required_project_fields(config):
        if is_auto(value):
            unresolved_critical.append(f"{dotted} is unresolved ({value!r}).")
    if action in {"converge", "resume", "release"}:
        errors.extend(unresolved_critical)
    else:
        warnings.extend(unresolved_critical)

    if action in {"converge", "resume", "release"}:
        for task_name in (mame.get("capture_task", "mame_capture"), rtl.get("capture_task", "rtl_capture")):
            if not isinstance(task_name, str) or not task_is_ready(config, task_name):
                errors.append(f"Required capture task {task_name!r} is not configured and enabled.")
        rom_files = mame.get("rom_files")
        if not isinstance(rom_files, list) or not rom_files:
            errors.append(
                "mame.rom_files must identify every ROM archive/file needed by the selected set so reference-cache identity cannot ignore ROM changes."
            )
        source_root = Path(str(paths.get("mame_source", "")))
        driver_source = mame.get("driver_source")
        if isinstance(driver_source, str) and not is_auto(driver_source):
            driver_path = Path(driver_source)
            if not driver_path.is_absolute():
                driver_path = source_root / driver_path
            if not driver_path.is_file():
                errors.append(f"Configured MAME driver source does not exist: {driver_path}")
        rom_root = Path(str(paths.get("mame_roms", "")))
        if isinstance(rom_files, list):
            for item in rom_files:
                if not isinstance(item, str) or not item:
                    continue
                rom_path = Path(item)
                if not rom_path.is_absolute():
                    rom_path = rom_root / rom_path
                if not rom_path.is_file():
                    errors.append(f"Configured ROM identity file does not exist: {rom_path}")

    if action == "release":
        for label, task_name in (("RTL lint", rtl.get("lint_task")), ("regression", rtl.get("regression_task"))):
            if not isinstance(task_name, str) or not task_is_ready(config, task_name):
                errors.append(f"A configured and enabled {label} task is required for release.")
        full_task = quartus.get("full_task")
        if not isinstance(full_task, str) or not task_is_ready(config, full_task):
            errors.append("A configured and enabled Quartus full-compile task is required for release.")
        for field in ("report_dir", "output_rbf"):
            if is_auto(quartus.get(field)):
                errors.append(f"quartus.{field} must be resolved for release.")
        if mister.get("require_mra_for_release", True):
            if not mister.get("mra_files"):
                errors.append("mister.mra_files must list at least one MRA for release.")
            if is_auto(mister.get("rbf_name")):
                errors.append("mister.rbf_name must be resolved for release.")

    return {"errors": errors, "warnings": warnings}


def config_fingerprint(config: dict[str, Any]) -> str:
    return stable_hash(config)


def scenario_config(config: dict[str, Any], name: str | None) -> tuple[str, dict[str, Any]]:
    scenarios = config.get("scenarios", {})
    selected = name or config.get("workflow", {}).get("default_scenario")
    if selected not in scenarios:
        available = ", ".join(sorted(scenarios)) if isinstance(scenarios, dict) else ""
        raise ConfigError(f"Unknown scenario {selected!r}. Available: {available}")
    scenario = scenarios[selected]
    if not isinstance(scenario, dict):
        raise ConfigError(f"Scenario {selected!r} is invalid.")
    if not scenario.get("enabled", True):
        raise ConfigError(f"Scenario {selected!r} is disabled.")
    return str(selected), scenario


def compute_jobs(config: dict[str, Any]) -> int:
    resources = config.get("resources", {})
    explicit = resources.get("job_count", "auto")
    if isinstance(explicit, int) and not isinstance(explicit, bool) and explicit > 0:
        return explicit
    logical = os.cpu_count() or 4
    reserve = max(0, int(resources.get("reserve_logical_cpus", 4)))
    cap = max(1, int(resources.get("job_cap", 16)))
    return max(1, min(cap, logical - reserve))


def unresolved_markers(config: dict[str, Any]) -> list[str]:
    found: list[str] = []

    def visit(value: Any, path: str) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                visit(child, f"{path}.{key}" if path else key)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                visit(child, f"{path}[{index}]")
        elif isinstance(value, str) and value.strip() in {"AUTO", "REPLACE_ME"}:
            found.append(path)

    visit(config, "")
    return found
