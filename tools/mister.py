#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

SCRIPT = Path(__file__).resolve()
TOOLS = SCRIPT.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from misterlib.config import ConfigError, load_config, save_config
from misterlib.discovery import discover, write_discovery
from misterlib.observability import load_contract, validate_contract, validate_input_events
from misterlib.mra import validate_mras
from misterlib.process import TaskError, TaskRunner
from misterlib.provenance import add_donor, fetch_donor, scan_donor, validate_provenance
from misterlib.quartus import parse_quartus_reports, write_quartus_report
from misterlib.traces import TraceError, compare_normalized, normalize_trace, write_diff_report
from misterlib.util import atomic_write_json, ensure_relative, load_json
from misterlib.workflow import Workflow, WorkflowError


EXIT_OK = 0
EXIT_DIVERGED = 2
EXIT_BLOCKED = 3
EXIT_FAILED = 4


def find_root(start: Path) -> Path:
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".mister/project.json").exists():
            return candidate
    raise ConfigError("No .mister/project.json found in this directory or its parents.")


def print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="mister",
        description="Deterministic MiSTer FPGA MAME/Verilator/Quartus workflow executor.",
    )
    p.add_argument("--root", type=Path, default=Path.cwd(), help="Project directory.")
    sub = p.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="Validate project, tasks and local tools.")
    doctor.add_argument("--action", choices=["doctor", "converge", "resume", "release"], default="doctor")
    doctor.add_argument("--scenario")
    sub.add_parser("discover", help="Scan the repository and write .mister/discovery.json.")
    sub.add_parser("status", help="Show durable workflow state.")

    task = sub.add_parser("task", help="Run one configured argv task.")
    task.add_argument("name")
    task.add_argument("--force", action="store_true")

    conv = sub.add_parser("converge", help="Run one complete deterministic differential iteration.")
    conv.add_argument("--scenario")
    conv.add_argument("--force-reference", action="store_true")

    sub.add_parser("resume", help="Resume from durable state; never aliases to status.")

    norm = sub.add_parser("normalize", help="Normalize one raw trace under the observability contract.")
    norm.add_argument("side", choices=["mame", "rtl"])
    norm.add_argument("input", type=Path)
    norm.add_argument("output", type=Path)
    norm.add_argument("--domain", action="append", dest="domains")

    diff = sub.add_parser("diff", help="Strictly compare two already-normalized traces.")
    diff.add_argument("reference", type=Path)
    diff.add_argument("rtl", type=Path)
    diff.add_argument("--domain", action="append", dest="domains")
    diff.add_argument("--json", type=Path, default=Path(".mister/reports/manual-diff.json"))
    diff.add_argument("--markdown", type=Path, default=Path(".mister/reports/manual-diff.md"))
    diff.add_argument("--resync-window", type=int, default=0)

    donor = sub.add_parser("donor", help="Scan or validate donor provenance.")
    donor_sub = donor.add_subparsers(dest="donor_command", required=True)
    donor_add = donor_sub.add_parser("add")
    donor_add.add_argument("path", type=Path)
    donor_add.add_argument("--url")
    donor_add.add_argument("--label")
    donor_fetch = donor_sub.add_parser("fetch")
    donor_fetch.add_argument("url")
    donor_fetch.add_argument("--ref", default="HEAD")
    donor_fetch.add_argument("--label")
    donor_sub.add_parser("validate")

    quartus = sub.add_parser("quartus-report", help="Parse fresh Quartus reports and enforce gates.")
    quartus.add_argument("--report-dir", type=Path)
    quartus.add_argument("--build-started-ns", type=int)

    sub.add_parser("mra-report", help="Validate MRA setnames and RBF mapping.")

    release = sub.add_parser("release", help="Run release scenarios, regressions, Quartus and hardware gates.")

    fix = sub.add_parser("record-fix", help="Create a searchable solved-divergence record.")
    fix.add_argument("--title", required=True)
    fix.add_argument("--cause", required=True)
    fix.add_argument("--fix", required=True)
    fix.add_argument("--evidence", required=True)
    fix.add_argument("--regression", required=True)

    validate = sub.add_parser("validate-contract", help="Validate observability and scenario input contracts.")
    validate.add_argument("--scenario")
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        root = find_root(args.root)
        config = load_config(root)
        workflow = Workflow(root, config)

        if args.command == "doctor":
            result = workflow.doctor(action=args.action, scenario_name=args.scenario)
            print_json(result)
            return EXIT_OK if result["status"] == "PASS" else EXIT_BLOCKED

        if args.command == "discover":
            result = discover(root, config)
            path = write_discovery(root, result)
            print_json({"status": "PASS", "path": str(path), "discovery": result})
            return EXIT_OK

        if args.command == "status":
            print_json(workflow.status())
            return EXIT_OK

        if args.command == "task":
            result = TaskRunner(root, config).run(args.name, force=args.force)
            print_json(result)
            return EXIT_OK

        if args.command == "converge":
            result = workflow.converge(
                scenario_name=args.scenario,
                force_reference=args.force_reference,
            )
            print_json(result)
            if result.get("status") == "MATCH":
                return EXIT_OK
            if result.get("status") == "DIVERGED":
                return EXIT_DIVERGED
            return EXIT_BLOCKED

        if args.command == "resume":
            result = workflow.resume()
            print_json(result)
            if result.get("status") == "MATCH":
                return EXIT_OK
            if result.get("status") in {"DIVERGED", "WAITING_FOR_PATCH"}:
                return EXIT_DIVERGED
            return EXIT_BLOCKED

        if args.command == "normalize":
            contract = load_contract(root)
            output = args.output if args.output.is_absolute() else root / args.output
            input_path = args.input if args.input.is_absolute() else root / args.input
            capture_cfg = config.get("capture", {})
            result = normalize_trace(
                input_path,
                output,
                side=args.side,
                contract=contract,
                selected_domains=args.domains,
                max_bytes=int(capture_cfg.get("max_raw_trace_bytes", 4 * 1024**3)),
                write_sidecar=bool(capture_cfg.get("write_sha256_sidecars", True)),
            )
            print_json(result)
            return EXIT_OK

        if args.command == "diff":
            contract = load_contract(root)
            reference = args.reference if args.reference.is_absolute() else root / args.reference
            rtl = args.rtl if args.rtl.is_absolute() else root / args.rtl
            capture_cfg = config.get("capture", {})
            report = compare_normalized(
                reference,
                rtl,
                domains=args.domains,
                contract=contract,
                context_events=int(capture_cfg.get("context_events", 8)),
                resync_window=args.resync_window,
            )
            json_path = args.json if args.json.is_absolute() else root / args.json
            md_path = args.markdown if args.markdown.is_absolute() else root / args.markdown
            write_diff_report(report, json_path, md_path)
            print_json(report)
            return EXIT_OK if report["status"] == "MATCH" else EXIT_DIVERGED

        if args.command == "donor":
            if args.donor_command == "add":
                record = scan_donor(args.path, source_url=args.url, label=args.label)
                path = add_donor(root, record)
                print_json({"status": "PASS", "path": str(path), "donor": record})
                return EXIT_OK
            if args.donor_command == "fetch":
                path, record = fetch_donor(
                    root, source_url=args.url, ref=args.ref, label=args.label
                )
                print_json({"status": "PASS", "path": str(path), "donor": record})
                return EXIT_OK
            result = validate_provenance(root)
            print_json(result)
            return EXIT_OK if not result["errors"] else EXIT_BLOCKED

        if args.command == "quartus-report":
            cfg = config.get("quartus", {})
            report_dir = args.report_dir
            if report_dir is None:
                value = cfg.get("report_dir")
                if not isinstance(value, str) or value in {"", "AUTO"}:
                    raise WorkflowError("quartus.report_dir is unresolved.")
                report_dir = ensure_relative(root, value)
            elif not report_dir.is_absolute():
                report_dir = root / report_dir
            report = parse_quartus_reports(
                report_dir,
                build_started_ns=args.build_started_ns,
                gates=cfg.get("gates", {}),
            )
            path = write_quartus_report(root, report)
            print_json({"path": str(path), "report": report})
            return EXIT_OK if report.get("status") == "PASS" else EXIT_BLOCKED

        if args.command == "mra-report":
            qcfg = config.get("quartus", {})
            rbf_value = qcfg.get("output_rbf")
            rbf_path = None
            if isinstance(rbf_value, str) and rbf_value not in {"", "AUTO"}:
                rbf_path = ensure_relative(root, rbf_value)
            result = validate_mras(root, config, rbf_path=rbf_path)
            atomic_write_json(root / ".mister/reports/mra.json", result)
            print_json(result)
            return EXIT_OK if result["status"] == "PASS" else EXIT_BLOCKED

        if args.command == "release":
            result = workflow.release()
            print_json(result)
            return EXIT_OK if result.get("status") == "RELEASE_READY" else EXIT_BLOCKED

        if args.command == "record-fix":
            path = workflow.record_fix(
                title=args.title,
                cause=args.cause,
                fix=args.fix,
                evidence=args.evidence,
                regression=args.regression,
            )
            print_json({"status": "PASS", "path": str(path)})
            return EXIT_OK

        if args.command == "validate-contract":
            contract = load_contract(root)
            scenario_name = args.scenario or config.get("workflow", {}).get("default_scenario")
            scenario = config.get("scenarios", {}).get(scenario_name, {})
            domains = scenario.get("domains") if isinstance(scenario, dict) else None
            result = validate_contract(contract, domains, require_strict=True)
            if isinstance(scenario, dict) and isinstance(scenario.get("input_file"), str):
                input_result = validate_input_events(ensure_relative(root, scenario["input_file"]))
                result["errors"].extend(input_result["errors"])
                result["warnings"].extend(input_result["warnings"])
            print_json(result)
            return EXIT_OK if not result["errors"] else EXIT_BLOCKED

        raise AssertionError(f"Unhandled command {args.command}")
    except (ConfigError, WorkflowError, TaskError, TraceError, ValueError) as exc:
        print(json.dumps({"status": "ERROR", "error": str(exc)}, indent=2), file=sys.stderr)
        return EXIT_FAILED
    except KeyboardInterrupt:
        print(json.dumps({"status": "INTERRUPTED"}, indent=2), file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
