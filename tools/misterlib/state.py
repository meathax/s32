from __future__ import annotations

from pathlib import Path
from typing import Any

from . import SCHEMA_VERSION
from .config import STATE_REL
from .util import atomic_write_json, load_json, utc_now


DEFAULT_STATE: dict[str, Any] = {
    "schema_version": 4,
    "workflow": "idle",
    "stage": "UNINITIALIZED",
    "status": "NEW",
    "scenario": None,
    "iteration": 0,
    "active_run": None,
    "last_run": None,
    "last_match": None,
    "first_divergence": None,
    "waiting_for": None,
    "fingerprints": {},
    "history": [],
    "updated_utc": None,
}


class StateStore:
    def __init__(self, root: Path):
        self.path = root / STATE_REL
        self.data = self._load()

    def _load(self) -> dict[str, Any]:
        data = load_json(self.path, default=None)
        if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
            return dict(DEFAULT_STATE)
        merged = dict(DEFAULT_STATE)
        merged.update(data)
        return merged

    def save(self) -> None:
        self.data["updated_utc"] = utc_now()
        atomic_write_json(self.path, self.data)

    def transition(
        self,
        stage: str,
        status: str,
        *,
        event: str,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.data["stage"] = stage
        self.data["status"] = status
        entry = {
            "utc": utc_now(),
            "stage": stage,
            "status": status,
            "event": event,
            "details": details or {},
        }
        history = list(self.data.get("history", []))
        history.append(entry)
        self.data["history"] = history[-200:]
        self.save()

    def begin_run(self, run_id: str, scenario: str, fingerprints: dict[str, Any]) -> None:
        self.data["workflow"] = "converge"
        self.data["active_run"] = run_id
        self.data["scenario"] = scenario
        self.data["iteration"] = int(self.data.get("iteration", 0)) + 1
        self.data["fingerprints"] = fingerprints
        self.data["waiting_for"] = None
        self.transition("VALIDATE", "RUNNING", event="begin_run", details={"run_id": run_id})

    def complete_run(self, run_id: str, status: str) -> None:
        self.data["last_run"] = run_id
        self.data["active_run"] = None
        self.data["workflow"] = "idle"
        self.transition("COMPLETE", status, event="complete_run", details={"run_id": run_id})

    def fail(self, stage: str, message: str) -> None:
        self.data["waiting_for"] = None
        self.data["active_run"] = None
        self.data["workflow"] = "idle"
        self.transition(stage, "FAILED", event="failure", details={"message": message})
