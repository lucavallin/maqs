"""The Step protocol and the runner that applies the skip rule and validation."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal, Protocol

from maqs.context import BuildContext
from maqs.tools import ToolError
from maqs.validate import Expectation, OutputInfo, ValidationError, validate_output

log = logging.getLogger("maqs.steps")


class BuildError(Exception):
    """At least one step failed; the CLI raises this after writing the report."""


class Step(Protocol):
    name: str

    def outputs(self, ctx: BuildContext) -> list[Path]: ...

    def expectation(self, ctx: BuildContext) -> Expectation: ...

    def build(self, ctx: BuildContext) -> list[str]: ...


@dataclass
class StepResult:
    name: str
    status: Literal["built", "skipped", "failed"]
    seconds: float
    command: list[str] = field(default_factory=list)
    outputs: list[OutputInfo] = field(default_factory=list)
    error: str | None = None


def run_step(step: Step, ctx: BuildContext) -> StepResult:
    started = time.monotonic()
    outputs = step.outputs(ctx)
    command: list[str] = []
    status: Literal["built", "skipped"]
    if all(p.exists() for p in outputs) and not ctx.force:
        log.info("%s: skipped: outputs present", step.name)
        status = "skipped"
    else:
        ctx.out_dir.mkdir(parents=True, exist_ok=True)
        try:
            command = step.build(ctx)
        except ToolError as exc:
            log.error("%s: %s", step.name, exc)
            elapsed = time.monotonic() - started
            return StepResult(step.name, "failed", elapsed, list(exc.argv), [], str(exc))
        status = "built"
    infos: list[OutputInfo] = []
    expect = step.expectation(ctx)
    for path in outputs:
        try:
            infos.append(validate_output(path, expect))
        except (ValidationError, FileNotFoundError) as exc:
            hint = " Rerun with --force to rebuild it." if status == "skipped" else ""
            log.error("%s: validation failed: %s", step.name, exc)
            elapsed = time.monotonic() - started
            return StepResult(step.name, "failed", elapsed, command, infos, f"{exc}{hint}")
    return StepResult(step.name, status, time.monotonic() - started, command, infos)
