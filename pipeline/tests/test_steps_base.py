from pathlib import Path

import pytest

from maqs.config import load_config
from maqs.context import BuildContext
from maqs.steps.base import run_step
from maqs.tools import ToolError, ToolMissing
from maqs.validate import Expectation
from tests.helpers import write_pmtiles

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


class FakeStep:
    name = "fake"

    def __init__(self, fail=False, raises=None, writes=True):
        self.calls = 0
        self.fail = fail
        self.raises = raises
        self.writes = writes

    def outputs(self, ctx):
        return [ctx.out_dir / f"{ctx.label}-fake.pmtiles"]

    def expectation(self, ctx):
        return Expectation(0, 14, frozenset({"mvt"}))

    def build(self, ctx):
        self.calls += 1
        if self.fail:
            raise ToolError(["versatiles", "convert"], 1, "kaboom")
        if self.raises:
            raise self.raises
        if self.writes:
            write_pmtiles(self.outputs(ctx)[0], max_zoom=14)
        return ["versatiles", "convert", "x"]


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region("test"),
    )


def test_out_dir_and_label_for_region(ctx):
    assert ctx.out_dir == ctx.dist / "test" and ctx.label == "test"


def test_builds_then_skips_then_forces(ctx):
    step = FakeStep()
    first = run_step(step, ctx)
    assert first.status == "built" and step.calls == 1 and first.outputs[0].tiles == 1
    assert first.command == ["versatiles", "convert", "x"] and first.seconds >= 0
    second = run_step(step, ctx)
    assert second.status == "skipped" and step.calls == 1
    assert second.outputs[0].file == "test-fake.pmtiles"
    ctx.force = True
    third = run_step(step, ctx)
    assert third.status == "built" and step.calls == 2


def test_skipped_output_is_still_validated(ctx):
    step = FakeStep()
    run_step(step, ctx)
    out = step.outputs(ctx)[0]
    out.write_bytes(out.read_bytes()[:50])  # a crashed earlier run left a truncated file
    result = run_step(step, ctx)
    assert result.status == "failed" and "truncated" in result.error and "--force" in result.error


def test_tool_error_becomes_failed_result(ctx):
    result = run_step(FakeStep(fail=True), ctx)
    assert result.status == "failed" and "kaboom" in result.error and result.outputs == []
    assert result.command == ["versatiles", "convert"]


def test_os_error_in_build_becomes_failed_result(ctx):
    error = PermissionError(13, "Permission denied", "/dist/test/test-fake.pmtiles")
    result = run_step(FakeStep(raises=error), ctx)
    assert result.status == "failed" and result.outputs == [] and result.command == []
    assert result.error == str(error) and "Permission denied" in result.error


def test_missing_tool_becomes_failed_result(ctx):
    result = run_step(FakeStep(raises=ToolMissing("versatiles")), ctx)
    assert result.status == "failed" and result.outputs == []
    assert result.error == "versatiles not found on PATH"


def test_unwritable_out_dir_becomes_failed_result(ctx):
    ctx.dist.mkdir(parents=True)
    (ctx.dist / "test").write_text("a file where the output directory should be")
    step = FakeStep()
    result = run_step(step, ctx)
    assert result.status == "failed" and step.calls == 0 and "test" in result.error


def test_build_that_writes_nothing_fails_validation(ctx):
    result = run_step(FakeStep(writes=False), ctx)
    assert result.status == "failed" and result.command == ["versatiles", "convert", "x"]
    assert "No such file or directory" in result.error and "test-fake.pmtiles" in result.error


def test_unexpected_errors_still_propagate(ctx):
    with pytest.raises(KeyError):
        run_step(FakeStep(raises=KeyError("bug")), ctx)


def test_base_pack_context(tmp_path):
    cfg = load_config(REAL)
    ctx = BuildContext(
        config=cfg,
        dist=tmp_path,
        cache=tmp_path,
        force=False,
        base_pack=cfg.base_pack("triveneto"),
    )
    assert ctx.out_dir == tmp_path / "base" and ctx.label == "base-triveneto"
