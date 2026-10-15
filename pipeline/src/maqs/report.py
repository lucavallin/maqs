"""build-report.json: what was built, from what, with which tools, and whether it is valid."""

from __future__ import annotations

import json
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path

from maqs.steps.base import StepResult

REPORT_VERSION = 1


def report_path(out_dir: Path) -> Path:
    return out_dir / "build-report.json"


def build_report(
    label: str,
    results: list[StepResult],
    tool_versions: dict[str, str | None],
    built_at: datetime | None = None,
) -> dict:
    stamp = (built_at or datetime.now(UTC)).strftime("%Y-%m-%dT%H:%M:%SZ")
    steps = []
    failures = []
    for r in results:
        outputs = []
        for o in r.outputs:
            d = asdict(o)
            d.pop("metadata")
            outputs.append(d)
        step = {
            "name": r.name,
            "status": r.status,
            "seconds": round(r.seconds, 3),
            "command": r.command,
            "outputs": outputs,
        }
        if r.error:
            step["error"] = r.error
            failures.append(f"{r.name}: {r.error}")
        steps.append(step)
    return {
        "report_version": REPORT_VERSION,
        "region": label,
        "built_at": stamp,
        "tools": tool_versions,
        "steps": steps,
        "validation": {"ok": not failures, "failures": failures},
    }


def write_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(path)
