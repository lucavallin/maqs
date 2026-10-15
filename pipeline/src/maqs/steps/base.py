"""The Step protocol and the runner that applies the skip rule and validation."""

from __future__ import annotations

import logging
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal, Protocol

from maqs.context import BuildContext
from maqs.tools import ToolError, ToolMissing
from maqs.validate import (
    Expectation,
    OutputInfo,
    SqliteExpectation,
    ValidationError,
    validate_output,
)

log = logging.getLogger("maqs.steps")


MAX_REPORTED_ANOMALIES = 1000


@dataclass(frozen=True)
class Anomaly:
    """A data problem (broken relation, missing tag) the build records and carries on past."""

    kind: str
    id: str
    message: str


@dataclass
class StepOutcome:
    command: list[str] = field(default_factory=list)
    anomalies: list[Anomaly] = field(default_factory=list)


class Step(Protocol):
    name: str

    def outputs(self, ctx: BuildContext) -> list[Path]: ...

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation | SqliteExpectation: ...

    def build(self, ctx: BuildContext) -> StepOutcome: ...


@dataclass
class StepResult:
    name: str
    status: Literal["built", "skipped", "failed"]
    seconds: float
    command: list[str] = field(default_factory=list)
    outputs: list[OutputInfo] = field(default_factory=list)
    error: str | None = None
    anomalies: list[Anomaly] = field(default_factory=list)
    anomaly_count: int = 0
    anomaly_kinds: dict[str, int] = field(default_factory=dict)


def _kind_counts(anomalies: list[Anomaly]) -> dict[str, int]:
    """Full per-kind totals, in kind order, so the report stays exact when the list is capped."""
    return dict(sorted(Counter(a.kind for a in anomalies).items()))


def _failed(
    step: Step,
    started: float,
    command: list[str],
    outputs: list[OutputInfo],
    error: str,
    anomalies: list[Anomaly] | None = None,
    anomaly_count: int = 0,
    anomaly_kinds: dict[str, int] | None = None,
) -> StepResult:
    return StepResult(
        step.name,
        "failed",
        time.monotonic() - started,
        command,
        outputs,
        error,
        anomalies or [],
        anomaly_count,
        anomaly_kinds or {},
    )


def run_step(step: Step, ctx: BuildContext) -> StepResult:
    """Build (unless skipped) and validate one step; expected failures become a failed result.

    Tool, filesystem and validation failures are recorded so the build report is still written
    and `--region all` moves on to the next region. Anything else is a bug and propagates.
    """
    started = time.monotonic()
    outputs = step.outputs(ctx)
    command: list[str] = []
    anomalies: list[Anomaly] = []
    anomaly_count = 0
    anomaly_kinds: dict[str, int] = {}
    status: Literal["built", "skipped"]
    if all(p.exists() for p in outputs) and not ctx.force:
        log.info("%s: skipped: outputs present", step.name)
        status = "skipped"
    else:
        try:
            ctx.out_dir.mkdir(parents=True, exist_ok=True)
            outcome = step.build(ctx)
        except (ToolError, ToolMissing, OSError) as exc:
            log.error("%s: %s", step.name, exc)
            argv = list(exc.argv) if isinstance(exc, ToolError) else []
            return _failed(step, started, argv, [], str(exc))
        command = outcome.command
        anomalies = outcome.anomalies[:MAX_REPORTED_ANOMALIES]
        anomaly_count = len(outcome.anomalies)
        anomaly_kinds = _kind_counts(outcome.anomalies)
        status = "built"
    infos: list[OutputInfo] = []
    for path in outputs:
        try:
            infos.append(validate_output(path, step.expectation(ctx, path)))
        except (ValidationError, OSError) as exc:
            hint = " Rerun with --force to rebuild it." if status == "skipped" else ""
            log.error("%s: validation failed: %s", step.name, exc)
            return _failed(
                step,
                started,
                command,
                infos,
                f"{exc}{hint}",
                anomalies,
                anomaly_count,
                anomaly_kinds,
            )
    return StepResult(
        step.name,
        status,
        time.monotonic() - started,
        command,
        infos,
        anomalies=anomalies,
        anomaly_count=anomaly_count,
        anomaly_kinds=anomaly_kinds,
    )
