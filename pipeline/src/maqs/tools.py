"""The only way the pipeline runs external CLIs: logged, pinned, shell-free."""

from __future__ import annotations

import logging
import re
import shlex
import shutil
import subprocess
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("maqs.tools")

PINS: dict[str, str] = {
    "versatiles": "5.0.0",
    "pmtiles": "1.31.2",
    "osmium": "1.19.1",
    "tippecanoe": "2.79.0",
}

VERSION_ARGS: dict[str, list[str]] = {
    "versatiles": ["--version"],
    "pmtiles": ["version"],
    "osmium": ["--version"],
    "tippecanoe": ["--version"],
}

_VERSION_RE = re.compile(r"(\d+\.\d+\.\d+)")


class ToolMissing(RuntimeError):
    """A pinned tool is not on PATH."""

    def __init__(self, name: str) -> None:
        self.tool = name
        super().__init__(f"{name} not found on PATH")


class ToolError(RuntimeError):
    """A tool exited non-zero. Carries the command and the tail of its stderr."""

    def __init__(self, argv: list[str], returncode: int, stderr_tail: str) -> None:
        self.argv = argv
        self.returncode = returncode
        self.stderr_tail = stderr_tail
        super().__init__(f"{argv[0]} exited {returncode}: {stderr_tail.strip()[-500:]}")


def find_tool(name: str) -> Path:
    found = shutil.which(name)
    if not found:
        raise ToolMissing(name)
    return Path(found)


def run(
    argv: Sequence[str | Path], *, cwd: Path | None = None, capture: bool = True
) -> subprocess.CompletedProcess[str]:
    """Run a command without a shell; raise ToolError on non-zero exit."""
    command = [str(a) for a in argv]
    log.info("run: %s", shlex.join(command))
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            capture_output=capture,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise ToolError(command, -1, str(exc)) from exc
    if result.returncode != 0:
        tail = (result.stderr or "")[-4000:]
        raise ToolError(command, result.returncode, tail)
    return result


def parse_version(name: str, output: str) -> str | None:
    if name == "pmtiles" and output.strip().startswith("pmtiles dev"):
        return "dev"
    match = _VERSION_RE.search(output.splitlines()[0] if output else "")
    return match.group(1) if match else None


def tool_version(name: str) -> str | None:
    try:
        result = run([find_tool(name), *VERSION_ARGS[name]])
    except ToolError as exc:
        # tippecanoe --version exits 1 while printing the version; use whatever came out.
        return parse_version(name, exc.stderr_tail)
    return parse_version(name, result.stdout or result.stderr)


@dataclass(frozen=True)
class ToolStatus:
    name: str
    pinned: str
    found: str | None
    path: Path | None
    ok: bool
    note: str


def check_tools(names: Iterable[str] = PINS) -> list[ToolStatus]:
    statuses: list[ToolStatus] = []
    for name in names:
        pinned = PINS[name]
        try:
            path = find_tool(name)
        except ToolMissing:
            note = f"{name} not found on PATH"
            statuses.append(ToolStatus(name, pinned, None, None, False, note))
            continue
        found = tool_version(name)
        if found == pinned:
            statuses.append(ToolStatus(name, pinned, found, path, True, "ok"))
        elif name == "pmtiles" and found == "dev":
            note = "Homebrew build reports 'dev': version unverifiable, assumed pinned"
            statuses.append(ToolStatus(name, pinned, found, path, True, note))
        else:
            note = f"found {found or 'unknown'}, pinned {pinned}"
            statuses.append(ToolStatus(name, pinned, found, path, False, note))
    return statuses
