from __future__ import annotations

import json
import os
import shutil
import sys
import traceback
from pathlib import Path
from typing import Any

from .cache import ReferenceCache
from .config import (
    OBS_REL,
    compute_jobs,
    config_fingerprint,
    scenario_config,
    task_is_ready,
    validate_config,
)
from .observability import load_contract, validate_contract, validate_input_events
from .mra import validate_mras
from .process import TaskError, TaskRunner
from .provenance import validate_provenance
from .quartus import parse_quartus_reports, write_quartus_report
from .state import StateStore
from .traces import (
    TraceError,
    compare_normalized,
    normalize_trace,
    render_diff_markdown,
    write_diff_report,
    write_jsonl,
)
from .util import (
    atomic_write_json,
    atomic_write_text,
    ensure_relative,
    git_info,
    hash_optional_file,
    hash_tree,
    load_json,
    redact_mapping,
    sha256_file,
    stable_hash,
    timestamp_id,
    tool_identity,
    utc_now,
)


class WorkflowError(RuntimeError):
    pass


class Workflow:
    def __init__(self, root: Path, config: dict[str, Any]):
        self.root = root.resolve()
        self.config = config
        self.state = StateStore(self.root)
        self.runner = TaskRunner(self.root, config)
        self.reference_cache = ReferenceCache()

    def _contract(self) -> dict[str, Any]:
        return load_contract(self.root)

    def doctor(self, *, action: str = "doctor", scenario_name: str | None = None) -> dict[str, Any]:
        config_result = validate_config(self.root, self.config, action=action)
        errors = list(config_result["errors"])
        warnings = list(config_result["warnings"])
        contract: dict[str, Any] | None = None

        selected_scenario = scenario_name
        domains: list[str] = []
        if action in {"converge", "resume", "release"}:
            try:
                selected_scenario, scenario = scenario_config(self.config, selected_scenario)
                domains = list(scenario.get("domains", []))
            except Exception as exc:
                errors.append(str(exc))
                scenario = {}
            try:
                contract = self._contract()
                checked = validate_contract(contract, domains or None, require_strict=True)
                errors.extend(checked["errors"])
                warnings.extend(checked["warnings"])
            except Exception as exc:
                errors.append(str(exc))
            input_file = scenario.get("input_file") if isinstance(scenario, dict) else None
            if isinstance(input_file, str):
                checked_input = validate_input_events(ensure_relative(self.root, input_file))
                errors.extend(checked_input["errors"])
                warnings.extend(checked_input["warnings"])

        paths = self.config.get("paths", {})
        tools = {
            "mame": tool_identity(str(paths.get("mame_exe", ""))),
            "verilator": tool_identity(str(paths.get("verilator", "verilator"))),
        }
        if action in {"converge", "resume", "release"}:
            if not tools["mame"].get("exists"):
                errors.append(f"MAME executable was not found: {paths.get('mame_exe')}")
            else:
                expected = str(self.config.get("mame", {}).get("version_expected", "")).strip()
                actual = str(tools["mame"].get("version", "")).strip()
                if expected and expected not in {"AUTO", "REPLACE_ME"}:
                    if not actual:
                        errors.append(
                            f"Could not verify the configured MAME version {expected!r}; the executable returned no usable version string."
                        )
                    elif expected.lower() not in actual.lower():
                        errors.append(
                            f"MAME version mismatch: expected {expected!r}, observed {actual!r}. "
                            "Do not compare runs made by an unpinned MAME build."
                        )
            if not tools["verilator"].get("exists"):
                warnings.append(
                    f"Configured Verilator executable was not found: {paths.get('verilator')}. "
                    "A task may still invoke Verilator through another build wrapper."
                )

        provenance = validate_provenance(self.root)
        require_provenance = bool(self.config.get("release", {}).get("require_provenance", True))
        if action == "release" and require_provenance:
            errors.extend(provenance["errors"])
        else:
            warnings.extend(provenance["errors"])
        warnings.extend(provenance["warnings"])
        report = {
            "schema": "mister-doctor-v4",
            "created_utc": utc_now(),
            "action": action,
            "root": str(self.root),
            "scenario": selected_scenario,
            "jobs": compute_jobs(self.config),
            "tools": tools,
            "errors": errors,
            "warnings": warnings,
            "status": "PASS" if not errors else "BLOCKED",
        }
        path = self.root / ".mister/reports/doctor.json"
        atomic_write_json(path, report)
        return report

    def _source_fingerprint(self) -> str:
        globs = self.config.get("rtl", {}).get("source_globs", [])
        if not isinstance(globs, list):
            globs = []
        return hash_tree(self.root, [str(x) for x in globs])

    def _scenario_identity(
        self,
        scenario_name: str,
        scenario: dict[str, Any],
        contract: dict[str, Any],
    ) -> dict[str, Any]:
        input_path = ensure_relative(self.root, scenario["input_file"])
        mame_cfg = self.config.get("mame", {})
        paths = self.config.get("paths", {})
        mame_exe = Path(str(paths.get("mame_exe", "")))
        source_root = Path(str(paths.get("mame_source", "")))
        rom_root = Path(str(paths.get("mame_roms", "")))
        source_hashes: dict[str, str] = {}
        for item in mame_cfg.get("source_inputs", []):
            path = Path(str(item))
            if not path.is_absolute():
                path = source_root / path
            source_hashes[str(path)] = hash_optional_file(path)
        driver = mame_cfg.get("driver_source")
        if isinstance(driver, str) and driver not in {"AUTO", ""}:
            driver_path = Path(driver)
            if not driver_path.is_absolute():
                driver_path = source_root / driver_path
            source_hashes.setdefault(str(driver_path), hash_optional_file(driver_path))
        rom_hashes: dict[str, str] = {}
        for item in mame_cfg.get("rom_files", []):
            path = Path(str(item))
            if not path.is_absolute():
                path = rom_root / path
            rom_hashes[str(path)] = hash_optional_file(path)
        adapter_inputs = []
        task = self.config.get("tasks", {}).get(mame_cfg.get("capture_task", "mame_capture"), {})
        cache_inputs = task.get("cache", {}).get("inputs", []) if isinstance(task, dict) else []
        if isinstance(cache_inputs, list):
            adapter_inputs = [str(x) for x in cache_inputs]
        return {
            "schema": "mister-reference-identity-v4",
            "scenario": scenario_name,
            "scenario_config": scenario,
            "input_sha256": hash_optional_file(input_path),
            "mame_shortname": mame_cfg.get("shortname"),
            "mame_tool": tool_identity(str(mame_exe)),
            "mame_source_hashes": source_hashes,
            "rom_hashes": rom_hashes,
            "adapter_hash": hash_tree(self.root, adapter_inputs) if adapter_inputs else "NO_ADAPTER_INPUTS",
            "observability_hash": stable_hash(contract),
            "project_config_hash": config_fingerprint(self.config),
        }

    def fingerprints(
        self,
        scenario_name: str,
        scenario: dict[str, Any],
        contract: dict[str, Any],
    ) -> dict[str, Any]:
        identity = self._scenario_identity(scenario_name, scenario, contract)
        return {
            "source": self._source_fingerprint(),
            "config": config_fingerprint(self.config),
            "observability": stable_hash(contract),
            "scenario": stable_hash(scenario),
            "reference_identity": stable_hash(identity),
            "git": git_info(self.root),
        }

    def _capture(
        self,
        *,
        side: str,
        task_name: str,
        scenario_name: str,
        scenario: dict[str, Any],
        index: int,
        run_dir: Path,
    ) -> tuple[Path, dict[str, Any]]:
        side_dir = run_dir / side / f"capture-{index}"
        side_dir.mkdir(parents=True, exist_ok=True)
        raw_path = side_dir / "raw.jsonl"
        normalized_path = side_dir / "normalized.jsonl"
        env = {
            "MISTER_SIDE": side,
            "MISTER_SCENARIO": scenario_name,
            "MISTER_CAPTURE_INDEX": str(index),
            "MISTER_SEED": str(scenario.get("seed", 1)),
            "MISTER_TRACE_OUT": str(raw_path),
            "MISTER_INPUT_FILE": str(ensure_relative(self.root, scenario["input_file"])),
            "MISTER_STOP_KIND": str(scenario.get("stop", {}).get("kind", "")),
            "MISTER_STOP_VALUE": str(scenario.get("stop", {}).get("value", "")),
        }
        result = self.runner.run(task_name, run_dir=side_dir / "task", extra_env=env, force=True)
        if not raw_path.exists():
            raise WorkflowError(
                f"Capture task '{task_name}' succeeded but did not create MISTER_TRACE_OUT: {raw_path}"
            )
        if raw_path.stat().st_size == 0:
            raise WorkflowError(f"Capture task '{task_name}' created an empty trace: {raw_path}")
        contract = self._contract()
        capture_cfg = self.config.get("capture", {})
        max_bytes = capture_cfg.get("max_raw_trace_bytes")
        if isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or max_bytes <= 0:
            max_bytes = None
        normalize_report = normalize_trace(
            raw_path,
            normalized_path,
            side=side,
            contract=contract,
            selected_domains=scenario.get("domains"),
            max_bytes=max_bytes,
            write_sidecar=bool(capture_cfg.get("write_sha256_sidecars", True)),
        )
        atomic_write_json(side_dir / "normalize-report.json", normalize_report)
        return normalized_path, {"task": result, "normalize": normalize_report}

    def _prove_side_determinism(
        self,
        side: str,
        traces: list[Path],
        *,
        scenario: dict[str, Any],
        contract: dict[str, Any],
        run_dir: Path,
    ) -> dict[str, Any]:
        if len(traces) < 2:
            raise WorkflowError(f"{side} requires at least two independent captures.")
        baseline = traces[0]
        comparisons = []
        status = "MATCH"
        for index, candidate in enumerate(traces[1:], 1):
            report = compare_normalized(
                baseline,
                candidate,
                domains=scenario.get("domains"),
                contract=contract,
                context_events=4,
                resync_window=0,
            )
            comparisons.append(report)
            if report["status"] != "MATCH":
                status = "NONDETERMINISTIC"
        output = {
            "schema": "mister-determinism-report-v4",
            "created_utc": utc_now(),
            "side": side,
            "status": status,
            "capture_count": len(traces),
            "comparisons": comparisons,
        }
        atomic_write_json(run_dir / side / "determinism.json", output)
        if status != "MATCH":
            first = next(r for r in comparisons if r["status"] != "MATCH")
            atomic_write_text(
                run_dir / side / "determinism.md",
                f"# {side} nondeterminism\n\n" + render_diff_markdown(first) + "\n",
            )
        return output

    def _restore_reference_cache(
        self,
        identity: dict[str, Any],
        run_dir: Path,
    ) -> tuple[Path, dict[str, Any]] | None:
        key = self.reference_cache.key(identity)
        destination = run_dir / "mame/cached-reference.normalized.jsonl"
        manifest = self.reference_cache.restore(key, destination)
        if manifest is None:
            return None
        return destination, {
            "schema": "mister-determinism-report-v4",
            "created_utc": utc_now(),
            "side": "mame",
            "status": "MATCH",
            "capture_count": 2,
            "cache_key": key,
            "cached": True,
            "cache_manifest": manifest,
        }

    def _store_reference_cache(
        self,
        identity: dict[str, Any],
        trace: Path,
        determinism: dict[str, Any],
    ) -> str:
        key = self.reference_cache.key(identity)
        self.reference_cache.store(
            key, trace, identity=identity, determinism_report=determinism
        )
        return key

    def _issue_bundle(
        self,
        run_dir: Path,
        diff: dict[str, Any],
        fingerprints: dict[str, Any],
    ) -> Path:
        issue = run_dir / "issue"
        issue.mkdir(parents=True, exist_ok=True)
        atomic_write_json(issue / "diff.json", diff)
        atomic_write_text(issue / "diff.md", render_diff_markdown(diff) + "\n")
        atomic_write_json(issue / "config.snapshot.json", redact_mapping(self.config))
        atomic_write_json(issue / "observability.snapshot.json", self._contract())
        atomic_write_json(issue / "fingerprints.json", fingerprints)
        atomic_write_json(issue / "git.json", git_info(self.root))
        divergence = diff.get("first_divergence") or {}
        left_context = divergence.get("left_context") or []
        right_context = divergence.get("right_context") or []
        if left_context:
            write_jsonl(issue / "mame-context.jsonl", left_context)
        if right_context:
            write_jsonl(issue / "rtl-context.jsonl", right_context)
        prompt = f"""# Codex diagnosis contract

Investigate the first causal producer of this divergence.

- Domain: {divergence.get('domain')}
- Event index: {divergence.get('index')}
- Differing fields: {', '.join(divergence.get('mismatch_fields', []))}

Rules:

1. Do not patch the displayed consumer until its producer chain is traced backward.
2. Compare MAME source/runtime evidence with the exact RTL observation phase.
3. Treat timing, lane order, masks, IRQ acknowledgement, wait states and reset state as suspects.
4. Make one bounded synthesizable fix only after evidence is sufficient.
5. Add a focused regression, rerun this exact case, then cold-run the scenario.
6. Record the solved issue under docs/debug/.
"""
        atomic_write_text(issue / "NEXT-ACTION.md", prompt)
        return issue

    def converge(
        self,
        *,
        scenario_name: str | None = None,
        force_reference: bool = False,
    ) -> dict[str, Any]:
        selected, scenario = scenario_config(self.config, scenario_name)
        doctor = self.doctor(action="converge", scenario_name=selected)
        if doctor["errors"]:
            raise WorkflowError("Workflow is blocked:\n- " + "\n- ".join(doctor["errors"]))
        contract = self._contract()
        run_id = f"{timestamp_id()}-{selected}"
        run_dir = self.root / ".mister/runs" / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        fingerprints = self.fingerprints(selected, scenario, contract)
        self.state.begin_run(run_id, selected, fingerprints)
        manifest: dict[str, Any] = {
            "schema": "mister-run-manifest-v4",
            "run_id": run_id,
            "created_utc": utc_now(),
            "scenario": selected,
            "root": str(self.root),
            "fingerprints": fingerprints,
            "config": redact_mapping(self.config),
            "status": "RUNNING",
            "stages": [],
        }
        atomic_write_json(run_dir / "manifest.json", manifest)

        try:
            lint_task = self.config.get("rtl", {}).get("lint_task")
            if isinstance(lint_task, str) and task_is_ready(self.config, lint_task):
                self.state.transition("LINT", "RUNNING", event="run_lint")
                result = self.runner.run(lint_task, run_dir=run_dir / "lint")
                manifest["stages"].append({"stage": "lint", "result": result})

            build_task = self.config.get("rtl", {}).get("build_task")
            if isinstance(build_task, str) and task_is_ready(self.config, build_task):
                self.state.transition("BUILD_RTL", "RUNNING", event="build_rtl")
                result = self.runner.run(build_task, run_dir=run_dir / "build")
                manifest["stages"].append({"stage": "build_rtl", "result": result})

            reference_identity = self._scenario_identity(selected, scenario, contract)
            use_cache = bool(scenario.get("mame_cache", True)) and not force_reference
            cached = self._restore_reference_cache(reference_identity, run_dir) if use_cache else None
            if cached:
                mame_trace, mame_determinism = cached
                manifest["stages"].append({"stage": "mame_reference", "cached": True})
            else:
                self.state.transition("CAPTURE_MAME", "RUNNING", event="capture_mame")
                mame_task = str(self.config.get("mame", {}).get("capture_task", "mame_capture"))
                mame_traces = []
                mame_results = []
                for index in range(int(scenario.get("capture_count", 2))):
                    trace, result = self._capture(
                        side="mame", task_name=mame_task, scenario_name=selected,
                        scenario=scenario, index=index, run_dir=run_dir,
                    )
                    mame_traces.append(trace)
                    mame_results.append(result)
                mame_determinism = self._prove_side_determinism(
                    "mame", mame_traces, scenario=scenario, contract=contract, run_dir=run_dir
                )
                if mame_determinism["status"] != "MATCH":
                    self.state.data["waiting_for"] = "deterministic MAME reference"
                    self.state.data["last_run"] = run_id
                    self.state.data["active_run"] = None
                    self.state.data["workflow"] = "idle"
                    self.state.transition(
                        "DETERMINISM_MAME", "BLOCKED", event="mame_nondeterministic",
                        details={"run_id": run_id},
                    )
                    manifest["status"] = "MAME_NONDETERMINISTIC"
                    manifest["completed_utc"] = utc_now()
                    atomic_write_json(run_dir / "manifest.json", manifest)
                    return {"status": "MAME_NONDETERMINISTIC", "run_id": run_id, "run_dir": str(run_dir)}
                mame_trace = mame_traces[0]
                cache_key = None
                if bool(scenario.get("mame_cache", True)) and bool(
                    self.config.get("capture", {}).get("write_sha256_sidecars", True)
                ):
                    cache_key = self._store_reference_cache(
                        reference_identity, mame_trace, mame_determinism
                    )
                manifest["stages"].append({
                    "stage": "mame_reference", "cached": False, "cache_key": cache_key,
                    "captures": mame_results,
                })

            self.state.transition("CAPTURE_RTL", "RUNNING", event="capture_rtl")
            rtl_task = str(self.config.get("rtl", {}).get("capture_task", "rtl_capture"))
            rtl_traces = []
            rtl_results = []
            for index in range(int(scenario.get("capture_count", 2))):
                trace, result = self._capture(
                    side="rtl", task_name=rtl_task, scenario_name=selected,
                    scenario=scenario, index=index, run_dir=run_dir,
                )
                rtl_traces.append(trace)
                rtl_results.append(result)
            rtl_determinism = self._prove_side_determinism(
                "rtl", rtl_traces, scenario=scenario, contract=contract, run_dir=run_dir
            )
            if rtl_determinism["status"] != "MATCH":
                self.state.data["waiting_for"] = "deterministic RTL simulation"
                self.state.data["last_run"] = run_id
                self.state.data["active_run"] = None
                self.state.data["workflow"] = "idle"
                self.state.transition(
                    "DETERMINISM_RTL", "BLOCKED", event="rtl_nondeterministic",
                    details={"run_id": run_id},
                )
                manifest["status"] = "RTL_NONDETERMINISTIC"
                manifest["completed_utc"] = utc_now()
                manifest["stages"].append({"stage": "rtl_capture", "captures": rtl_results})
                atomic_write_json(run_dir / "manifest.json", manifest)
                return {"status": "RTL_NONDETERMINISTIC", "run_id": run_id, "run_dir": str(run_dir)}

            self.state.transition("COMPARE", "RUNNING", event="compare_reference_rtl")
            report = compare_normalized(
                mame_trace,
                rtl_traces[0],
                domains=scenario.get("domains"),
                contract=contract,
                context_events=int(self.config.get("capture", {}).get("context_events", 8)),
                resync_window=int(self.config.get("capture", {}).get("diagnostic_resync_window", 16)),
            )
            report_dir = run_dir / "compare"
            write_diff_report(report, report_dir / "diff.json", report_dir / "diff.md")
            manifest["stages"].append({
                "stage": "rtl_capture", "captures": rtl_results,
                "determinism": rtl_determinism,
            })
            manifest["stages"].append({"stage": "compare", "report": str(report_dir / "diff.json")})

            if report["status"] == "MATCH":
                manifest["status"] = "MATCH"
                manifest["completed_utc"] = utc_now()
                atomic_write_json(run_dir / "manifest.json", manifest)
                self.state.data["last_match"] = {
                    "scenario": selected,
                    "run_id": run_id,
                    "event_counts": {
                        domain: result.get("left_count")
                        for domain, result in report.get("domains", {}).items()
                    },
                    "fingerprints": fingerprints,
                }
                self.state.data["first_divergence"] = None
                self.state.data["waiting_for"] = None
                self.state.complete_run(run_id, "MATCH")
                return {
                    "status": "MATCH",
                    "run_id": run_id,
                    "run_dir": str(run_dir),
                    "report": str(report_dir / "diff.md"),
                }

            issue = self._issue_bundle(run_dir, report, fingerprints)
            manifest["status"] = "DIVERGED"
            manifest["completed_utc"] = utc_now()
            manifest["issue_bundle"] = str(issue)
            atomic_write_json(run_dir / "manifest.json", manifest)
            self.state.data["first_divergence"] = report.get("first_divergence")
            self.state.data["waiting_for"] = "evidence-backed RTL diagnosis and one bounded fix"
            self.state.data["last_run"] = run_id
            self.state.data["active_run"] = None
            self.state.data["workflow"] = "idle"
            self.state.transition(
                "DIAGNOSE", "DIVERGED", event="first_divergence",
                details={"run_id": run_id, "issue_bundle": str(issue)},
            )
            return {
                "status": "DIVERGED",
                "run_id": run_id,
                "run_dir": str(run_dir),
                "issue_bundle": str(issue),
                "first_divergence": report.get("first_divergence"),
            }
        except Exception as exc:
            manifest["status"] = "FAILED"
            manifest["completed_utc"] = utc_now()
            manifest["error"] = str(exc)
            manifest["traceback"] = traceback.format_exc()
            atomic_write_json(run_dir / "manifest.json", manifest)
            self.state.fail(self.state.data.get("stage", "FAILED"), str(exc))
            raise

    def resume(self) -> dict[str, Any]:
        state = self.state.data
        scenario_value = state.get("scenario") or self.config.get("workflow", {}).get("default_scenario")
        selected, scenario_cfg = scenario_config(self.config, str(scenario_value))
        contract = self._contract()
        current = self.fingerprints(selected, scenario_cfg, contract)
        previous = state.get("fingerprints", {})
        resume_keys = ("source", "config", "observability", "scenario", "reference_identity")
        unchanged = bool(previous) and all(current.get(key) == previous.get(key) for key in resume_keys)

        if state.get("status") == "DIVERGED" and unchanged:
            return {
                "status": "WAITING_FOR_PATCH",
                "scenario": selected,
                "last_run": state.get("last_run"),
                "waiting_for": state.get("waiting_for"),
                "first_divergence": state.get("first_divergence"),
            }
        if state.get("status") == "MATCH" and unchanged:
            return {
                "status": "MATCH",
                "scenario": selected,
                "last_run": state.get("last_run"),
                "message": "The saved scenario still matches the current source, configuration and evidence fingerprints.",
            }
        return self.converge(scenario_name=selected)

    def status(self) -> dict[str, Any]:
        return {
            "schema": "mister-status-v4",
            "created_utc": utc_now(),
            "root": str(self.root),
            "state": self.state.data,
            "doctor": self.doctor(action="doctor"),
        }

    def record_fix(
        self,
        *,
        title: str,
        cause: str,
        fix: str,
        evidence: str,
        regression: str,
    ) -> Path:
        debug_dir = self.root / "docs/debug"
        debug_dir.mkdir(parents=True, exist_ok=True)
        existing = sorted(debug_dir.glob("[0-9][0-9][0-9]-*.md"))
        numbers = []
        for item in existing:
            try:
                numbers.append(int(item.name.split("-", 1)[0]))
            except (ValueError, IndexError):
                continue
        number = max(numbers, default=0) + 1
        safe = "".join(ch.lower() if ch.isalnum() else "-" for ch in title).strip("-")
        while "--" in safe:
            safe = safe.replace("--", "-")
        path = debug_dir / f"{number:03d}-{safe or 'fix'}.md"
        text = f"""# {title}

**Recorded:** {utc_now()}

## Symptom

{evidence}

## First causal divergence

{cause}

## RTL correction

{fix}

## Regression

{regression}

## Recognition signature

Document the canonical event signature that should make this issue searchable on future cores.
"""
        atomic_write_text(path, text)
        return path

    def quartus_report(self, *, build_started_ns: int | None = None) -> dict[str, Any]:
        cfg = self.config.get("quartus", {})
        report_dir_value = cfg.get("report_dir")
        if not isinstance(report_dir_value, str) or report_dir_value in {"", "AUTO"}:
            raise WorkflowError("quartus.report_dir is unresolved.")
        report_dir = ensure_relative(self.root, report_dir_value)
        report = parse_quartus_reports(
            report_dir,
            build_started_ns=build_started_ns,
            gates=cfg.get("gates", {}),
        )
        write_quartus_report(self.root, report)
        return report

    def release(self) -> dict[str, Any]:
        doctor = self.doctor(action="release")
        if doctor["errors"]:
            raise WorkflowError("Release is blocked:\n- " + "\n- ".join(doctor["errors"]))
        workflow_cfg = self.config.get("workflow", {})
        scenario_results: list[dict[str, Any]] = []
        for name in workflow_cfg.get("release_scenarios", []):
            result = self.converge(scenario_name=str(name))
            scenario_results.append(result)
            if result.get("status") != "MATCH":
                return {
                    "status": "BLOCKED",
                    "reason": f"Release scenario {name!r} did not match.",
                    "scenarios": scenario_results,
                }

        rtl_cfg = self.config.get("rtl", {})
        for task_name in (rtl_cfg.get("lint_task"), rtl_cfg.get("regression_task")):
            if isinstance(task_name, str) and task_is_ready(self.config, task_name):
                self.runner.run(task_name, run_dir=self.root / ".mister/release" / task_name, force=True)

        quartus_cfg = self.config.get("quartus", {})
        full_task = quartus_cfg.get("full_task")
        quartus_result: dict[str, Any] | None = None
        build_started_ns: int | None = None
        if isinstance(full_task, str) and task_is_ready(self.config, full_task):
            build_started_ns = __import__("time").time_ns()
            self.runner.run(full_task, run_dir=self.root / ".mister/release/quartus", force=True)
            quartus_result = self.quartus_report(build_started_ns=build_started_ns)
            if quartus_result.get("status") != "PASS":
                return {
                    "status": "BLOCKED",
                    "reason": "Quartus gates failed.",
                    "quartus": quartus_result,
                    "scenarios": scenario_results,
                }

        rbf_value = quartus_cfg.get("output_rbf")
        rbf: dict[str, Any] | None = None
        if isinstance(rbf_value, str) and rbf_value not in {"", "AUTO"}:
            rbf_path = ensure_relative(self.root, rbf_value)
            if not rbf_path.exists():
                return {"status": "BLOCKED", "reason": f"Expected RBF is missing: {rbf_path}"}
            if build_started_ns is not None and rbf_path.stat().st_mtime_ns < build_started_ns:
                return {"status": "BLOCKED", "reason": f"RBF is stale: {rbf_path}"}
            rbf = {
                "path": str(rbf_path),
                "size": rbf_path.stat().st_size,
                "sha256": sha256_file(rbf_path),
            }

        mra_result = validate_mras(self.root, self.config, rbf_path=Path(rbf["path"]) if rbf else None)
        atomic_write_json(self.root / ".mister/release/mra.json", mra_result)
        if self.config.get("mister", {}).get("require_mra_for_release", True) and mra_result["status"] != "PASS":
            return {
                "status": "BLOCKED",
                "reason": "MRA/RBF mapping gates failed.",
                "mra": mra_result,
                "scenarios": scenario_results,
                "quartus": quartus_result,
                "rbf": rbf,
            }

        hardware_cfg = self.config.get("hardware", {})
        hardware_task = hardware_cfg.get("deployment_task", "hardware_test")
        hardware_result: dict[str, Any] | None = None
        if isinstance(hardware_task, str) and task_is_ready(self.config, hardware_task):
            hardware_result = self.runner.run(
                hardware_task, run_dir=self.root / ".mister/release/hardware", force=True
            )
        hardware_required = bool(hardware_cfg.get("hardware_required_for_release", True))
        allow_pending = bool(self.config.get("release", {}).get("allow_hardware_pending", True))
        status = "RELEASE_READY"
        if hardware_required and hardware_result is None:
            if not allow_pending:
                return {
                    "status": "BLOCKED",
                    "reason": "Real-MiSTer hardware verification is required and release.allow_hardware_pending is false.",
                    "scenarios": scenario_results,
                    "quartus": quartus_result,
                    "rbf": rbf,
                    "mra": mra_result,
                }
            status = "SOFTWARE_VERIFIED_HARDWARE_PENDING"

        release = {
            "schema": "mister-release-v4",
            "created_utc": utc_now(),
            "status": status,
            "scenarios": scenario_results,
            "quartus": quartus_result,
            "rbf": rbf,
            "mra": mra_result,
            "hardware": hardware_result,
            "git": git_info(self.root),
            "config_hash": config_fingerprint(self.config),
            "source_hash": self._source_fingerprint(),
        }
        atomic_write_json(self.root / ".mister/release/release.json", release)
        self.state.transition("RELEASE", status, event="release_gate", details={"status": status})
        return release
