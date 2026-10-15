import sqlite3
from pathlib import Path

import pytest

from maqs.config import RowRange, load_config
from maqs.context import BuildContext
from maqs.sqlite_out import COUNT_TABLES, TABLES, Metadata, write_sqlite
from maqs.steps.base import Anomaly, StepOutcome, run_step
from maqs.tools import ToolError, ToolMissing
from maqs.validate import Expectation, SqliteExpectation
from tests.helpers import write_pmtiles

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


class FakeStep:
    name = "fake"

    def __init__(self, fail=False, raises=None, writes=True, anomalies=None):
        self.calls = 0
        self.fail = fail
        self.raises = raises
        self.writes = writes
        self.anomalies = anomalies or []

    def outputs(self, ctx):
        return [ctx.out_dir / f"{ctx.label}-fake.pmtiles"]

    def expectation(self, ctx, output):
        return Expectation(0, 14, frozenset({"mvt"}))

    def build(self, ctx):
        self.calls += 1
        if self.fail:
            raise ToolError(["versatiles", "convert"], 1, "kaboom")
        if self.raises:
            raise self.raises
        if self.writes:
            write_pmtiles(self.outputs(ctx)[0], max_zoom=14)
        return StepOutcome(["versatiles", "convert", "x"], list(self.anomalies))


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


def test_anomalies_are_kept_and_capped(ctx):
    found = [Anomaly("gap", f"relation/{i}", "gap of 12 m") for i in range(1200)]
    result = run_step(FakeStep(anomalies=found), ctx)
    assert result.status == "built" and result.anomaly_count == 1200
    assert len(result.anomalies) == 1000
    assert result.anomalies[0] == Anomaly("gap", "relation/0", "gap of 12 m")


def test_failed_validation_keeps_the_anomalies(ctx):
    found = [Anomaly("gap", "relation/1", "gap of 12 m")]
    result = run_step(FakeStep(writes=False, anomalies=found), ctx)
    assert result.status == "failed" and result.anomalies == found and result.anomaly_count == 1


def test_each_output_gets_its_own_expectation(ctx):
    class TwoOutputs(FakeStep):
        def outputs(self, ctx):
            return [ctx.out_dir / "a.pmtiles", ctx.out_dir / "b.pmtiles"]

        def expectation(self, ctx, output):
            return Expectation(0, 14 if output.name == "a.pmtiles" else 12, frozenset({"mvt"}))

        def build(self, ctx):
            write_pmtiles(ctx.out_dir / "a.pmtiles", max_zoom=14)
            write_pmtiles(ctx.out_dir / "b.pmtiles", max_zoom=12)
            return StepOutcome(["x"])

    result = run_step(TwoOutputs(), ctx)
    assert result.status == "built" and [o.max_zoom for o in result.outputs] == [14, 12]


def test_row_count_outside_expected_range_fails_and_keeps_the_file(ctx):
    class SqliteStep(FakeStep):
        def outputs(self, ctx):
            return [ctx.out_dir / "test-trails.sqlite"]

        def expectation(self, ctx, output):
            return SqliteExpectation(
                "trails",
                "test",
                TABLES["trails"],
                COUNT_TABLES["trails"],
                {"trails": RowRange(5, 10)},
            )

        def build(self, ctx):
            meta = Metadata("trails", "test", "2026-10-15", None)
            write_sqlite(self.outputs(ctx)[0], "trails", meta, lambda conn: None)
            return StepOutcome(["x"])

    step = SqliteStep()
    result = run_step(step, ctx)
    assert result.status == "failed"
    assert "trails has 0 rows, expected 5..10" in result.error
    assert step.outputs(ctx)[0].exists()


def test_malformed_sqlite_output_becomes_a_failed_result(ctx):
    class BadMetadataStep(FakeStep):
        def outputs(self, ctx):
            return [ctx.out_dir / "test-trails.sqlite"]

        def expectation(self, ctx, output):
            return SqliteExpectation("trails", "test", TABLES["trails"], COUNT_TABLES["trails"])

        def build(self, ctx):
            write_sqlite(
                self.outputs(ctx)[0],
                "trails",
                Metadata("trails", "test", "d", None),
                lambda c: None,
            )
            conn = sqlite3.connect(self.outputs(ctx)[0])
            conn.execute("DROP TABLE metadata")
            conn.execute("CREATE TABLE metadata (layer TEXT)")
            conn.commit()
            conn.close()
            return StepOutcome(["x"])

    result = run_step(BadMetadataStep(), ctx)
    assert result.status == "failed" and "no such column" in result.error


def test_base_pack_context(tmp_path):
    ctx = BuildContext(config=load_config(REAL), dist=tmp_path, cache=tmp_path, force=False)
    assert ctx.region is None
    assert ctx.out_dir == tmp_path / "base" and ctx.label == "base"
