import subprocess
import sys
from pathlib import Path

import pytest

from maqs import tools
from maqs.tools import ToolError, ToolMissing, check_tools, parse_version, run


def test_run_returns_output_for_a_successful_command():
    result = run([sys.executable, "-c", "print('hi')"])
    assert result.stdout.strip() == "hi"


def test_run_raises_tool_error_with_stderr_tail():
    with pytest.raises(ToolError) as exc:
        run([sys.executable, "-c", "import sys; sys.stderr.write('boom\\n'); sys.exit(3)"])
    assert exc.value.returncode == 3
    assert "boom" in exc.value.stderr_tail
    assert exc.value.argv[0] == sys.executable


def test_run_never_uses_a_shell(monkeypatch):
    seen = {}

    def fake(argv, **kwargs):
        seen["argv"] = argv
        seen["shell"] = kwargs.get("shell", False)
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake)
    run(["echo", "a b"])
    assert seen["argv"] == ["echo", "a b"] and seen["shell"] is False


@pytest.mark.parametrize(
    "name, output, expected",
    [
        ("versatiles", "versatiles 5.0.0\n", "5.0.0"),
        ("osmium", "osmium version 1.19.1\nlibosmium version 2.23.1\n", "1.19.1"),
        ("tippecanoe", "tippecanoe v2.79.0\n", "2.79.0"),
        ("pmtiles", "pmtiles 1.31.2, commit abc, built at ...\n", "1.31.2"),
        ("pmtiles", "pmtiles dev, commit none, built at unknown\n", "dev"),
        ("versatiles", "garbage", None),
    ],
)
def test_parse_version(name, output, expected):
    assert parse_version(name, output) == expected


def test_check_tools_reports_missing_and_mismatched(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))
    versions = {"versatiles": "4.9.0", "pmtiles": "1.31.2"}
    monkeypatch.setattr(tools, "tool_version", lambda name: versions[name])
    statuses = {s.name: s for s in check_tools(["versatiles", "pmtiles"])}
    assert statuses["versatiles"].ok is False and "4.9.0" in statuses["versatiles"].note
    assert statuses["pmtiles"].ok is True


def test_check_tools_accepts_pmtiles_dev_with_a_note(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/opt/homebrew/bin/pmtiles"))
    monkeypatch.setattr(tools, "tool_version", lambda name: "dev")
    (status,) = check_tools(["pmtiles"])
    assert status.ok is True and "unverifiable" in status.note


def test_check_tools_reports_missing(monkeypatch):
    def missing(name):
        raise ToolMissing(name)

    monkeypatch.setattr(tools, "find_tool", missing)
    (status,) = check_tools(["versatiles"])
    assert status.ok is False and status.found is None and "not found" in status.note


def test_run_wraps_a_missing_binary_in_tool_error(tmp_path):
    missing = tmp_path / "no-such-tool"
    with pytest.raises(ToolError) as exc:
        run([missing, "--version"])
    assert exc.value.returncode == -1
    assert exc.value.argv == [str(missing), "--version"]
    assert "No such file" in exc.value.stderr_tail


def test_run_wraps_a_bad_cwd_in_tool_error(tmp_path):
    with pytest.raises(ToolError) as exc:
        run([sys.executable, "-c", "pass"], cwd=tmp_path / "nope")
    assert exc.value.returncode == -1


def _fake_run(stdout="", stderr="", error=None):
    def fake(argv, **kwargs):
        if error:
            raise error
        return subprocess.CompletedProcess(argv, 0, stdout, stderr)

    return fake


def test_tool_version_reads_stdout(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/fake/versatiles"))
    monkeypatch.setattr(tools, "run", _fake_run(stdout="versatiles 5.0.0\n"))
    assert tools.tool_version("versatiles") == "5.0.0"


def test_tool_version_falls_back_to_stderr_on_success(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/fake/tippecanoe"))
    monkeypatch.setattr(tools, "run", _fake_run(stderr="tippecanoe v2.79.0\n"))
    assert tools.tool_version("tippecanoe") == "2.79.0"


def test_tool_version_parses_stderr_of_a_failing_version_command(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/fake/tippecanoe"))
    error = ToolError(["tippecanoe", "--version"], 1, "tippecanoe v2.79.0\n")
    monkeypatch.setattr(tools, "run", _fake_run(error=error))
    assert tools.tool_version("tippecanoe") == "2.79.0"
