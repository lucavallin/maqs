# Pipeline Skeleton and Tile Layers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `uv`-managed Python pipeline that builds, validates and reports the basemap, terrain, optional terrain-hd and bundled base-pack PMTiles for any region in `config/regions.yaml`, identically on macOS and `ubuntu-latest`, with the `test` region building in under 5 minutes.

**Architecture:** A thin orchestrator: one `Step` per layer that shells out to a pinned CLI (`versatiles`, `pmtiles`) through a single `run()` helper; a `BuildContext` carrying region, directories and flags; a PMTiles-header reader for validation (no parsing of tool output); a JSON build report per region. CI runs lint, unit tests, and a network smoke build of the `test` region whose outputs become the Swift fixtures as an artifact.

**Tech Stack:** Python 3.12, `uv`, `click`, `pyyaml`, `pytest`, `ruff`; CLIs `versatiles` 5.0.0, `pmtiles` 1.31.2 (plus `osmium-tool` 1.19.1 and `tippecanoe` 2.79.0 installed now for plan 2); GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-08-pipeline-skeleton-and-tile-layers-design.md`

## Global Constraints

- Python `>=3.12`; `uv` manages the environment; `uv.lock` is committed; no dependency beyond `click` and `pyyaml` at runtime, `pytest` and `ruff` for dev.
- Tool pins: `versatiles` 5.0.0, `pmtiles` 1.31.2, `osmium-tool` 1.19.1, `tippecanoe` 2.79.0. `maqs check-tools` fails on mismatch (pmtiles from Homebrew reports `dev`; see Task 3).
- One map provider: `https://download.versatiles.org/osm-landcover.versatiles` (basemap, base packs) and `https://download.versatiles.org/elevation.versatiles` (terrain). `terrain-hd` reads `https://download.mapterhorn.com/6-<x>-<y>.pmtiles`.
- Basemap and base packs are written with `--compress gzip` (MapLibre rejects brotli). Terrain is left as stored (uncompressed WebP).
- Hard caps: every output `< 1.9 * 2**30` bytes; every base pack `< 15_000_000` bytes; warn when the test region's basemap + terrain exceed `5_000_000` bytes.
- Region ids match `^[a-z0-9]+(-[a-z0-9]+)*$`; a region is the smallest pack unit; `fixture: true` regions are never in a base pack.
- Outputs go to `dist/<region>/`, downloads to `.cache/`; both gitignored; nothing generated is committed.
- No `shell=True`; every CLI call goes through `maqs.tools.run`; unit tests never touch the network or the real binaries.
- Code, comments, commits and docs in English; conventional commit messages; no AI attribution rule (the standard `Co-Authored-By` trailer is fine).

## Review Focus

1. **A crashed run leaves a truncated output; the next run must not trust it.** The skip rule checks existence only, so skipped outputs are still validated (header read + size); a truncated file fails validation and the user is told to rerun with `--force`. Test in Task 6.
2. **A `terrain-hd` archive with no tiles in the bbox.** Mapterhorn's z13+ coverage is partial; `pmtiles extract` on an empty selection must not produce a bogus part. The step dry-runs each archive, skips those reporting zero tiles, and fails if every archive is empty. Test in Task 8.
3. **A bbox that is inverted, out of range, or crosses the antimeridian.** The config loader rejects it with a message naming the region and the offending value instead of letting `versatiles` produce an empty archive. Test in Task 2.
4. **A tool at the wrong version produces different output silently** (compression, metadata). `build` runs the version check before any step and refuses to continue on a mismatch; `pmtiles dev` is accepted with a warning only on macOS Homebrew installs. Test in Task 3.
5. **An unknown `--region` id or a base-pack id passed as a region.** The CLI exits 2 with the list of valid ids; it never falls through to building nothing and reporting success. Test in Task 10.

---

### Task 1: Project scaffold

**Files:**
- Create: `pipeline/pyproject.toml`, `pipeline/.python-version`, `pipeline/src/maqs/__init__.py`, `pipeline/src/maqs/cli.py`, `pipeline/tests/__init__.py`, `pipeline/tests/test_cli_smoke.py`
- Modify: `.gitignore` (nothing needed: `.cache/`, `dist/`, `.venv/` are already ignored)

**Interfaces:**
- Produces: console script `maqs` → `maqs.cli:main` (a `click.Group`); package version `maqs.__version__ = "0.1.0"`.

- [ ] **Step 1: Write the failing smoke test**

```python
# pipeline/tests/test_cli_smoke.py
from click.testing import CliRunner

from maqs.cli import main


def test_help_lists_commands():
    result = CliRunner().invoke(main, ["--help"])
    assert result.exit_code == 0
    for command in ("build", "regions", "check-tools"):
        assert command in result.output
```

- [ ] **Step 2: Create the project files**

```toml
# pipeline/pyproject.toml
[project]
name = "maqs"
version = "0.1.0"
description = "Builds the maqs map data packs: tile extracts, data layers, validation and reports."
requires-python = ">=3.12"
dependencies = ["click>=8.1", "pyyaml>=6.0"]

[project.scripts]
maqs = "maqs.cli:main"

[dependency-groups]
dev = ["pytest>=8.0", "ruff>=0.6"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/maqs"]

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = ["network: builds against live sources; skipped unless --run-network"]

[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP", "SIM", "PTH"]
```

```
# pipeline/.python-version
3.12
```

```python
# pipeline/src/maqs/__init__.py
"""maqs pipeline: builds, validates and reports the map data packs."""

__version__ = "0.1.0"
```

```python
# pipeline/src/maqs/cli.py
"""Command-line entry point. Commands are wired to real work in later tasks."""

import click


@click.group()
@click.version_option(package_name="maqs")
def main() -> None:
    """Build and inspect maqs data packs."""


@main.command()
def build() -> None:
    """Build layers for a region."""
    raise click.ClickException("not implemented yet")


@main.command()
def regions() -> None:
    """List configured regions."""
    raise click.ClickException("not implemented yet")


@main.command("check-tools")
def check_tools() -> None:
    """Verify the pinned external tools are installed."""
    raise click.ClickException("not implemented yet")
```

```python
# pipeline/tests/__init__.py
```

- [ ] **Step 3: Create the environment and run the test**

Run (from `pipeline/`): `uv sync && uv run pytest -q`
Expected: `1 passed`. `uv.lock` now exists.

- [ ] **Step 4: Lint**

Run: `uv run ruff check . && uv run ruff format --check .`
Expected: no findings (run `uv run ruff format .` if formatting differs).

- [ ] **Step 5: Commit**

```bash
git add pipeline/pyproject.toml pipeline/.python-version pipeline/uv.lock pipeline/src pipeline/tests
git commit -m "feat(pipeline): scaffold the maqs package and CLI"
```

---

### Task 2: Region configuration

**Files:**
- Create: `config/regions.yaml`, `pipeline/src/maqs/config.py`, `pipeline/tests/test_config.py`

**Interfaces:**
- Produces:
  - `Bbox = tuple[float, float, float, float]` (lon_min, lat_min, lon_max, lat_max)
  - `@dataclass(frozen=True) Region(id: str, name: dict[str, str], bbox: Bbox, osm: dict[str, str] | None, clip: dict | None, fixture: bool, hd_max_zoom: int | None)`
  - `@dataclass(frozen=True) BasePack(id: str, regions: tuple[str, ...], max_zoom: int)`
  - `@dataclass(frozen=True) Config(schema_version: int, hd_max_zoom: int, base_packs: tuple[BasePack, ...], regions: tuple[Region, ...])` with `region(id) -> Region` (raises `KeyError`), `base_pack(id) -> BasePack`, `base_pack_bbox(pack) -> Bbox`, `geofabrik_extracts() -> list[str]`, `region_ids(include_fixtures: bool) -> list[str]`
  - `class ConfigError(ValueError)`
  - `load_config(path: Path) -> Config`, `union_bbox(bboxes: Iterable[Bbox]) -> Bbox`, `DEFAULT_CONFIG_PATH = Path("config/regions.yaml")` (relative to the repo root; the CLI resolves it in Task 10)

- [ ] **Step 1: Write the config file**

```yaml
# config/regions.yaml
schema_version: 1
hd_max_zoom: 13
base_packs:
  - id: triveneto
    regions: [triveneto]
    max_zoom: 10
regions:
  - id: test
    name: { it: Nevegal (test), en: Nevegal (test) }
    bbox: [12.21, 46.08, 12.29, 46.13]
    fixture: true
    osm: { geofabrik: europe/italy/nord-est }
  - id: triveneto
    name: { it: Triveneto, en: Triveneto }
    bbox: [10.3818, 44.7923, 13.9187, 47.0921]
    osm: { geofabrik: europe/italy/nord-est }
    clip: { admin: [43648, 179296, 45757] }
  - id: veneto
    name: { it: Veneto, en: Veneto }
    bbox: [10.6231, 44.7923, 13.1021, 46.6806]
    osm: { geofabrik: europe/italy/nord-est }
    clip: { admin: [43648] }
  - id: friuli-venezia-giulia
    name: { it: Friuli-Venezia Giulia, en: Friuli-Venezia Giulia }
    bbox: [12.3214, 45.5809, 13.9187, 46.6480]
    osm: { geofabrik: europe/italy/nord-est }
    clip: { admin: [179296] }
  - id: trentino-alto-adige
    name: { it: Trentino-Alto Adige/Südtirol, en: Trentino-South Tyrol }
    bbox: [10.3818, 45.6729, 12.4780, 47.0921]
    osm: { geofabrik: europe/italy/nord-est }
    clip: { admin: [45757] }
```

- [ ] **Step 2: Write the failing tests**

```python
# pipeline/tests/test_config.py
from pathlib import Path

import pytest

from maqs.config import ConfigError, load_config, union_bbox

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


def write(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "regions.yaml"
    p.write_text(text)
    return p


MINIMAL = """
schema_version: 1
hd_max_zoom: 13
base_packs: []
regions:
  - id: a
    name: { it: A, en: A }
    bbox: [10.0, 45.0, 11.0, 46.0]
"""


def test_loads_the_real_config():
    cfg = load_config(REAL)
    assert cfg.schema_version == 1
    assert cfg.region("test").fixture is True
    assert cfg.region("veneto").osm == {"geofabrik": "europe/italy/nord-est"}
    assert cfg.region("veneto").clip == {"admin": [43648]}
    assert cfg.base_pack("triveneto").regions == ("triveneto",)
    assert cfg.geofabrik_extracts() == ["europe/italy/nord-est"]
    assert "test" not in cfg.region_ids(include_fixtures=False)
    assert "test" in cfg.region_ids(include_fixtures=True)


def test_minimal_config(tmp_path):
    cfg = load_config(write(tmp_path, MINIMAL))
    r = cfg.region("a")
    assert r.bbox == (10.0, 45.0, 11.0, 46.0)
    assert r.fixture is False and r.osm is None and r.clip is None and r.hd_max_zoom is None


def test_union_bbox():
    assert union_bbox([(10, 45, 11, 46), (10.5, 44, 12, 45.5)]) == (10, 44, 12, 46)


def test_base_pack_bbox_is_the_union_of_its_regions(tmp_path):
    text = MINIMAL + """
  - id: b
    name: { it: B, en: B }
    bbox: [12.0, 44.0, 13.0, 45.0]
"""
    text = text.replace("base_packs: []", "base_packs:\n  - { id: ab, regions: [a, b], max_zoom: 10 }")
    cfg = load_config(write(tmp_path, text))
    assert cfg.base_pack_bbox(cfg.base_pack("ab")) == (10.0, 44.0, 13.0, 46.0)


@pytest.mark.parametrize(
    "bbox, message",
    [
        ("[11.0, 45.0, 10.0, 46.0]", "lon_min must be < lon_max"),
        ("[10.0, 46.0, 11.0, 45.0]", "lat_min must be < lat_max"),
        ("[-181.0, 45.0, 11.0, 46.0]", "longitude out of range"),
        ("[10.0, 45.0, 11.0, 91.0]", "latitude out of range"),
        ("[10.0, 45.0, 11.0]", "bbox must have 4 numbers"),
    ],
)
def test_rejects_bad_bbox(tmp_path, bbox, message):
    with pytest.raises(ConfigError, match=message) as exc:
        load_config(write(tmp_path, MINIMAL.replace("[10.0, 45.0, 11.0, 46.0]", bbox)))
    assert "region 'a'" in str(exc.value)


def test_rejects_bad_id(tmp_path):
    with pytest.raises(ConfigError, match="id 'Bad_Id' must match"):
        load_config(write(tmp_path, MINIMAL.replace("id: a", "id: Bad_Id")))


def test_rejects_duplicate_id(tmp_path):
    text = MINIMAL + """
  - id: a
    name: { it: A, en: A }
    bbox: [10.0, 45.0, 11.0, 46.0]
"""
    with pytest.raises(ConfigError, match="duplicate region id 'a'"):
        load_config(write(tmp_path, text))


def test_rejects_base_pack_with_unknown_or_fixture_region(tmp_path):
    text = MINIMAL.replace("base_packs: []", "base_packs:\n  - { id: x, regions: [nope], max_zoom: 10 }")
    with pytest.raises(ConfigError, match="base pack 'x' names unknown region 'nope'"):
        load_config(write(tmp_path, text))
    text = MINIMAL.replace("base_packs: []", "base_packs:\n  - { id: x, regions: [a], max_zoom: 10 }")
    text = text.replace("bbox: [10.0, 45.0, 11.0, 46.0]", "bbox: [10.0, 45.0, 11.0, 46.0]\n    fixture: true")
    with pytest.raises(ConfigError, match="base pack 'x' names fixture region 'a'"):
        load_config(write(tmp_path, text))


def test_rejects_unknown_schema_version(tmp_path):
    with pytest.raises(ConfigError, match="schema_version 2 is not supported"):
        load_config(write(tmp_path, MINIMAL.replace("schema_version: 1", "schema_version: 2")))


def test_unknown_region_raises_key_error(tmp_path):
    cfg = load_config(write(tmp_path, MINIMAL))
    with pytest.raises(KeyError):
        cfg.region("zzz")
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `uv run pytest tests/test_config.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.config'`

- [ ] **Step 4: Implement `config.py`**

```python
# pipeline/src/maqs/config.py
"""Loads and validates config/regions.yaml.

A region is the smallest unit a pack is cut at. Base packs are named lists of regions
bundled inside apps. Nothing here is Italy-specific: a region anywhere is one entry.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import yaml

Bbox = tuple[float, float, float, float]

ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SUPPORTED_SCHEMA_VERSION = 1
DEFAULT_CONFIG_PATH = Path("config/regions.yaml")


class ConfigError(ValueError):
    """The configuration file is invalid; the message says what and where."""


@dataclass(frozen=True)
class Region:
    id: str
    name: dict[str, str]
    bbox: Bbox
    osm: dict[str, str] | None
    clip: dict | None
    fixture: bool
    hd_max_zoom: int | None


@dataclass(frozen=True)
class BasePack:
    id: str
    regions: tuple[str, ...]
    max_zoom: int


@dataclass(frozen=True)
class Config:
    schema_version: int
    hd_max_zoom: int
    base_packs: tuple[BasePack, ...]
    regions: tuple[Region, ...]

    def region(self, region_id: str) -> Region:
        for r in self.regions:
            if r.id == region_id:
                return r
        raise KeyError(region_id)

    def base_pack(self, pack_id: str) -> BasePack:
        for p in self.base_packs:
            if p.id == pack_id:
                return p
        raise KeyError(pack_id)

    def base_pack_bbox(self, pack: BasePack) -> Bbox:
        return union_bbox(self.region(rid).bbox for rid in pack.regions)

    def geofabrik_extracts(self) -> list[str]:
        seen: list[str] = []
        for r in self.regions:
            if r.osm and r.osm.get("geofabrik") and r.osm["geofabrik"] not in seen:
                seen.append(r.osm["geofabrik"])
        return seen

    def region_ids(self, include_fixtures: bool) -> list[str]:
        return [r.id for r in self.regions if include_fixtures or not r.fixture]


def union_bbox(bboxes: Iterable[Bbox]) -> Bbox:
    boxes = list(bboxes)
    if not boxes:
        raise ConfigError("union of zero bboxes")
    return (
        min(b[0] for b in boxes),
        min(b[1] for b in boxes),
        max(b[2] for b in boxes),
        max(b[3] for b in boxes),
    )


def _parse_bbox(raw: object, where: str) -> Bbox:
    if not isinstance(raw, list) or len(raw) != 4:
        raise ConfigError(f"{where}: bbox must have 4 numbers, got {raw!r}")
    try:
        lon_min, lat_min, lon_max, lat_max = (float(v) for v in raw)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{where}: bbox must have 4 numbers, got {raw!r}") from exc
    for lon in (lon_min, lon_max):
        if not -180.0 <= lon <= 180.0:
            raise ConfigError(f"{where}: longitude out of range: {lon}")
    for lat in (lat_min, lat_max):
        if not -90.0 <= lat <= 90.0:
            raise ConfigError(f"{where}: latitude out of range: {lat}")
    if lon_min >= lon_max:
        raise ConfigError(f"{where}: lon_min must be < lon_max (antimeridian-crossing boxes are not supported)")
    if lat_min >= lat_max:
        raise ConfigError(f"{where}: lat_min must be < lat_max")
    return (lon_min, lat_min, lon_max, lat_max)


def _parse_region(raw: dict, hd_default: int) -> Region:
    rid = raw.get("id")
    if not isinstance(rid, str) or not ID_RE.match(rid):
        raise ConfigError(f"region id {rid!r} must match {ID_RE.pattern}")
    where = f"region '{rid}'"
    name = raw.get("name")
    if not isinstance(name, dict) or not {"it", "en"} <= set(name):
        raise ConfigError(f"{where}: name must have 'it' and 'en'")
    hd = raw.get("hd_max_zoom")
    if hd is not None and (not isinstance(hd, int) or hd < 13):
        raise ConfigError(f"{where}: hd_max_zoom must be an integer >= 13")
    return Region(
        id=rid,
        name={k: str(v) for k, v in name.items()},
        bbox=_parse_bbox(raw.get("bbox"), where),
        osm=raw.get("osm"),
        clip=raw.get("clip"),
        fixture=bool(raw.get("fixture", False)),
        hd_max_zoom=hd,
    )


def _parse_base_pack(raw: dict, regions: dict[str, Region]) -> BasePack:
    pid = raw.get("id")
    if not isinstance(pid, str) or not ID_RE.match(pid):
        raise ConfigError(f"base pack id {pid!r} must match {ID_RE.pattern}")
    names = raw.get("regions")
    if not isinstance(names, list) or not names:
        raise ConfigError(f"base pack '{pid}' must list at least one region")
    for n in names:
        if n not in regions:
            raise ConfigError(f"base pack '{pid}' names unknown region '{n}'")
        if regions[n].fixture:
            raise ConfigError(f"base pack '{pid}' names fixture region '{n}'")
    max_zoom = raw.get("max_zoom", 10)
    if not isinstance(max_zoom, int) or not 0 <= max_zoom <= 14:
        raise ConfigError(f"base pack '{pid}': max_zoom must be an integer in 0..14")
    return BasePack(id=pid, regions=tuple(names), max_zoom=max_zoom)


def load_config(path: Path) -> Config:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: top level must be a mapping")
    version = data.get("schema_version")
    if version != SUPPORTED_SCHEMA_VERSION:
        raise ConfigError(f"schema_version {version} is not supported (expected {SUPPORTED_SCHEMA_VERSION})")
    hd_default = data.get("hd_max_zoom", 13)
    if not isinstance(hd_default, int) or hd_default < 13:
        raise ConfigError("hd_max_zoom must be an integer >= 13")
    regions: dict[str, Region] = {}
    for raw in data.get("regions") or []:
        region = _parse_region(raw, hd_default)
        if region.id in regions:
            raise ConfigError(f"duplicate region id '{region.id}'")
        regions[region.id] = region
    if not regions:
        raise ConfigError("at least one region is required")
    packs = tuple(_parse_base_pack(raw, regions) for raw in data.get("base_packs") or [])
    if len({p.id for p in packs}) != len(packs):
        raise ConfigError("duplicate base pack id")
    return Config(
        schema_version=version,
        hd_max_zoom=hd_default,
        base_packs=packs,
        regions=tuple(regions.values()),
    )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_config.py -q`
Expected: all pass.

- [ ] **Step 6: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add config/regions.yaml pipeline/src/maqs/config.py pipeline/tests/test_config.py
git commit -m "feat(pipeline): region configuration with validation and base packs"
```

---

### Task 3: Tool runner and version pins

**Files:**
- Create: `pipeline/src/maqs/tools.py`, `pipeline/tests/test_tools.py`

**Interfaces:**
- Produces:
  - `PINS: dict[str, str] = {"versatiles": "5.0.0", "pmtiles": "1.31.2", "osmium": "1.19.1", "tippecanoe": "2.79.0"}`
  - `class ToolError(RuntimeError)` with attributes `argv: list[str]`, `returncode: int`, `stderr_tail: str`
  - `class ToolMissing(RuntimeError)`
  - `find_tool(name: str) -> Path` (uses `shutil.which`; raises `ToolMissing`)
  - `run(argv: Sequence[str | Path], *, cwd: Path | None = None, capture: bool = True) -> subprocess.CompletedProcess[str]`
  - `parse_version(name: str, output: str) -> str | None` (returns `"dev"` for the Homebrew pmtiles build)
  - `tool_version(name: str) -> str | None`
  - `@dataclass ToolStatus(name: str, pinned: str, found: str | None, path: Path | None, ok: bool, note: str)`
  - `check_tools(names: Iterable[str] = PINS) -> list[ToolStatus]`

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_tools.py
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
    monkeypatch.setattr(tools, "tool_version", lambda name: {"versatiles": "4.9.0", "pmtiles": "1.31.2"}[name])
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_tools.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.tools'`

- [ ] **Step 3: Implement `tools.py`**

```python
# pipeline/src/maqs/tools.py
"""The only way the pipeline runs external CLIs: logged, pinned, shell-free."""

from __future__ import annotations

import logging
import re
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
    log.info("run: %s", " ".join(command))
    result = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        capture_output=capture,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        tail = (result.stderr or "")[-4000:]
        raise ToolError(command, result.returncode, tail)
    return result


def parse_version(name: str, output: str) -> str | None:
    if name == "pmtiles" and output.startswith("pmtiles dev"):
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
            statuses.append(ToolStatus(name, pinned, None, None, False, f"{name} not found on PATH"))
            continue
        found = tool_version(name)
        if found == pinned:
            statuses.append(ToolStatus(name, pinned, found, path, True, "ok"))
        elif name == "pmtiles" and found == "dev":
            statuses.append(
                ToolStatus(name, pinned, found, path, True, "Homebrew build reports 'dev': version unverifiable, assumed pinned")
            )
        else:
            statuses.append(ToolStatus(name, pinned, found, path, False, f"found {found or 'unknown'}, pinned {pinned}"))
    return statuses
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_tools.py -q`
Expected: all pass.

- [ ] **Step 5: Check the real binaries on this machine**

Run: `uv run python -c "from maqs.tools import check_tools; [print(s) for s in check_tools()]"`
Expected: `versatiles` 5.0.0 ok, `pmtiles` dev ok with the note, `osmium` 1.19.1 ok, `tippecanoe` 2.79.0 ok. If `tippecanoe --version` is parsed as `None`, adjust `tool_version` to read stderr (its version goes to stderr) and re-run the unit tests.

- [ ] **Step 6: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/tools.py pipeline/tests/test_tools.py
git commit -m "feat(pipeline): shell-free tool runner with version pins"
```

---

### Task 4: PMTiles header reader

**Files:**
- Create: `pipeline/src/maqs/pmtiles_header.py`, `pipeline/tests/helpers.py`, `pipeline/tests/test_pmtiles_header.py`

**Interfaces:**
- Produces:
  - `COMPRESSION = {0: "unknown", 1: "none", 2: "gzip", 3: "brotli", 4: "zstd"}`, `TILE_TYPE = {0: "unknown", 1: "mvt", 2: "png", 3: "jpeg", 4: "webp", 5: "avif", 6: "mlt"}`
  - `@dataclass(frozen=True) Header(root_dir_offset, root_dir_length, metadata_offset, metadata_length, leaf_dirs_offset, leaf_dirs_length, tile_data_offset, tile_data_length, addressed_tiles, tile_entries, tile_contents, clustered: bool, internal_compression: str, tile_compression: str, tile_type: str, min_zoom: int, max_zoom: int, bbox: tuple[float, float, float, float])`
  - `class PMTilesError(ValueError)`
  - `read_header(path: Path) -> Header`, `read_metadata(path: Path, header: Header) -> dict`
  - test helper `write_pmtiles(path, *, tile_type=1, min_zoom=0, max_zoom=0, tile_compression=2, internal_compression=2, metadata: dict | None = None, tile: bytes = b"\x1a\x00") -> Path` producing a valid single-tile archive

- [ ] **Step 1: Write the test helper**

```python
# pipeline/tests/helpers.py
"""Builds tiny, valid PMTiles v3 archives so tests never need binaries in git."""

from __future__ import annotations

import gzip
import json
import struct
from pathlib import Path


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _compress(data: bytes, compression: int) -> bytes:
    if compression == 2:
        return gzip.compress(data, mtime=0)
    if compression == 1:
        return data
    raise ValueError(f"helper supports none/gzip only, got {compression}")


def write_pmtiles(
    path: Path,
    *,
    tile_type: int = 1,
    min_zoom: int = 0,
    max_zoom: int = 0,
    tile_compression: int = 2,
    internal_compression: int = 2,
    metadata: dict | None = None,
    tile: bytes = b"\x1a\x00",
    bbox: tuple[float, float, float, float] = (12.21, 46.08, 12.29, 46.13),
) -> Path:
    tile_blob = _compress(tile, tile_compression) if tile_compression != 1 else tile
    # one entry: tile id 0, run length 1, length, offset encoded as offset+1
    directory = _varint(1) + _varint(0) + _varint(1) + _varint(len(tile_blob)) + _varint(1)
    root = _compress(directory, internal_compression)
    meta = _compress(json.dumps(metadata or {}).encode(), internal_compression)
    root_offset = 127
    meta_offset = root_offset + len(root)
    leaf_offset = meta_offset + len(meta)
    data_offset = leaf_offset
    header = bytearray(b"PMTiles\x03")
    header += struct.pack(
        "<QQQQQQQQQQQ",
        root_offset, len(root), meta_offset, len(meta), leaf_offset, 0, data_offset, len(tile_blob), 1, 1, 1
    )
    header += bytes([1, internal_compression, tile_compression, tile_type, min_zoom, max_zoom])
    header += struct.pack("<iiii", *(int(v * 1e7) for v in bbox))
    header += bytes([min_zoom]) + struct.pack("<ii", int(((bbox[0] + bbox[2]) / 2) * 1e7), int(((bbox[1] + bbox[3]) / 2) * 1e7))
    assert len(header) == 127, len(header)
    path.write_bytes(bytes(header) + root + meta + tile_blob)
    return path
```

- [ ] **Step 2: Write the failing tests**

```python
# pipeline/tests/test_pmtiles_header.py
import pytest

from maqs.pmtiles_header import PMTilesError, read_header, read_metadata
from tests.helpers import write_pmtiles


def test_reads_a_generated_archive(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles", tile_type=1, min_zoom=0, max_zoom=14, metadata={"attribution": "x"})
    h = read_header(p)
    assert h.tile_type == "mvt" and h.tile_compression == "gzip" and h.internal_compression == "gzip"
    assert (h.min_zoom, h.max_zoom) == (0, 14)
    assert h.addressed_tiles == 1 and h.clustered is True
    assert h.bbox == pytest.approx((12.21, 46.08, 12.29, 46.13))
    assert read_metadata(p, h) == {"attribution": "x"}


def test_reads_webp_uncompressed(tmp_path):
    p = write_pmtiles(tmp_path / "t.pmtiles", tile_type=4, max_zoom=12, tile_compression=1)
    h = read_header(p)
    assert h.tile_type == "webp" and h.tile_compression == "none"


def test_rejects_bad_magic(tmp_path):
    p = tmp_path / "x.pmtiles"
    p.write_bytes(b"NOTPMTILES" + b"\x00" * 200)
    with pytest.raises(PMTilesError, match="not a PMTiles v3 archive"):
        read_header(p)


def test_rejects_truncated_file(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles")
    p.write_bytes(p.read_bytes()[:100])
    with pytest.raises(PMTilesError, match="truncated"):
        read_header(p)


def test_rejects_metadata_beyond_eof(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles", metadata={"k": "v" * 100})
    data = p.read_bytes()
    p.write_bytes(data[:-50])
    h = read_header(p)
    with pytest.raises(PMTilesError, match="truncated"):
        read_metadata(p, h)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `uv run pytest tests/test_pmtiles_header.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.pmtiles_header'`

- [ ] **Step 4: Implement the reader**

```python
# pipeline/src/maqs/pmtiles_header.py
"""Reads the fixed 127-byte PMTiles v3 header and the metadata JSON.

Spec: https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md (verified 2026-10-07).
Used for validation so the pipeline never parses a tool's human-readable output.
"""

from __future__ import annotations

import gzip
import json
import struct
from dataclasses import dataclass
from pathlib import Path

HEADER_SIZE = 127
COMPRESSION = {0: "unknown", 1: "none", 2: "gzip", 3: "brotli", 4: "zstd"}
TILE_TYPE = {0: "unknown", 1: "mvt", 2: "png", 3: "jpeg", 4: "webp", 5: "avif", 6: "mlt"}


class PMTilesError(ValueError):
    """The file is not a readable PMTiles v3 archive."""


@dataclass(frozen=True)
class Header:
    root_dir_offset: int
    root_dir_length: int
    metadata_offset: int
    metadata_length: int
    leaf_dirs_offset: int
    leaf_dirs_length: int
    tile_data_offset: int
    tile_data_length: int
    addressed_tiles: int
    tile_entries: int
    tile_contents: int
    clustered: bool
    internal_compression: str
    tile_compression: str
    tile_type: str
    min_zoom: int
    max_zoom: int
    bbox: tuple[float, float, float, float]


def read_header(path: Path) -> Header:
    with path.open("rb") as f:
        raw = f.read(HEADER_SIZE)
    if len(raw) < HEADER_SIZE:
        raise PMTilesError(f"{path}: truncated header ({len(raw)} of {HEADER_SIZE} bytes)")
    if raw[:7] != b"PMTiles" or raw[7] != 3:
        raise PMTilesError(f"{path}: not a PMTiles v3 archive")
    offsets = struct.unpack_from("<QQQQQQQQQQQ", raw, 8)
    clustered, internal, tile_comp, tile_type, min_zoom, max_zoom = raw[96:102]
    lon_min, lat_min, lon_max, lat_max = struct.unpack_from("<iiii", raw, 102)
    return Header(
        *offsets[:8],
        addressed_tiles=offsets[8],
        tile_entries=offsets[9],
        tile_contents=offsets[10],
        clustered=clustered == 1,
        internal_compression=COMPRESSION.get(internal, "unknown"),
        tile_compression=COMPRESSION.get(tile_comp, "unknown"),
        tile_type=TILE_TYPE.get(tile_type, "unknown"),
        min_zoom=min_zoom,
        max_zoom=max_zoom,
        bbox=(lon_min / 1e7, lat_min / 1e7, lon_max / 1e7, lat_max / 1e7),
    )


def read_metadata(path: Path, header: Header) -> dict:
    with path.open("rb") as f:
        f.seek(header.metadata_offset)
        raw = f.read(header.metadata_length)
    if len(raw) < header.metadata_length:
        raise PMTilesError(f"{path}: truncated metadata")
    if header.internal_compression == "gzip":
        raw = gzip.decompress(raw)
    elif header.internal_compression != "none":
        raise PMTilesError(f"{path}: unsupported internal compression {header.internal_compression}")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PMTilesError(f"{path}: metadata is not JSON") from exc
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_pmtiles_header.py -q`
Expected: all pass. If the generated-archive test fails on `bbox` or `addressed_tiles`, the helper's field order is wrong, not the reader: re-check the helper against the spec field list in `docs/decisions.md` ADR 0001.

- [ ] **Step 6: Cross-check against a real archive**

Run: `uv run python -c "from pathlib import Path; from maqs.pmtiles_header import read_header, read_metadata; h = read_header(Path('/private/tmp/claude-501/-Users-lucavallin-maqs/dcce1564-0945-4c3c-88d4-7f5997af8206/scratchpad/dist/test/test-basemap-gzip.pmtiles')); print(h); print(read_metadata(Path('/private/tmp/claude-501/-Users-lucavallin-maqs/dcce1564-0945-4c3c-88d4-7f5997af8206/scratchpad/dist/test/test-basemap-gzip.pmtiles'), h).get('tile_schema'))"`
Expected: `tile_type='mvt'`, `tile_compression='gzip'`, `min_zoom=0`, `max_zoom=14`, `addressed_tiles=26`, `shortbread@1.0`. (If the scratch file is gone, run `versatiles convert --bbox 12.23,46.09,12.27,46.12 --compress gzip https://download.versatiles.org/osm.versatiles /tmp/t.pmtiles` first and point at that.)

- [ ] **Step 7: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/pmtiles_header.py pipeline/tests/helpers.py pipeline/tests/test_pmtiles_header.py
git commit -m "feat(pipeline): PMTiles v3 header and metadata reader"
```

---

### Task 5: Validation

**Files:**
- Create: `pipeline/src/maqs/validate.py`, `pipeline/tests/test_validate.py`

**Interfaces:**
- Produces:
  - `SIZE_CAP = int(1.9 * 2**30)`, `BASE_PACK_CAP = 15_000_000`, `TEST_REGION_WARN = 5_000_000`
  - `@dataclass(frozen=True) Expectation(min_zoom: int, max_zoom: int, tile_types: frozenset[str], size_cap: int = SIZE_CAP)`
  - `@dataclass(frozen=True) OutputInfo(file: str, bytes: int, sha256: str, tile_type: str, min_zoom: int, max_zoom: int, tiles: int, compression: str, attribution: str | None, source_data_date: str | None, metadata: dict)`
  - `class ValidationError(Exception)`
  - `sha256(path: Path) -> str`
  - `validate_output(path: Path, expect: Expectation) -> OutputInfo` (raises `ValidationError` listing every failed check)

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_validate.py
import hashlib

import pytest

from maqs import validate
from maqs.validate import Expectation, ValidationError, sha256, validate_output
from tests.helpers import write_pmtiles

BASEMAP = Expectation(min_zoom=0, max_zoom=14, tile_types=frozenset({"mvt", "mlt"}))
TERRAIN = Expectation(min_zoom=0, max_zoom=12, tile_types=frozenset({"webp", "png"}))


def test_sha256_matches_hashlib(tmp_path):
    p = tmp_path / "f"
    p.write_bytes(b"maqs" * 1000)
    assert sha256(p) == hashlib.sha256(b"maqs" * 1000).hexdigest()


def test_valid_basemap_passes_and_reports(tmp_path):
    p = write_pmtiles(
        tmp_path / "x-basemap.pmtiles", tile_type=1, max_zoom=14,
        metadata={"attribution": "© OSM", "planetiler:osm:osmosisreplicationtime": "2026-06-07T23:59:58Z"},
    )
    info = validate_output(p, BASEMAP)
    assert info.file == "x-basemap.pmtiles" and info.tiles == 1 and info.compression == "gzip"
    assert info.attribution == "© OSM" and info.source_data_date == "2026-06-07T23:59:58Z"
    assert info.sha256 == sha256(p) and info.bytes == p.stat().st_size


def test_rejects_brotli(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    data = bytearray(p.read_bytes())
    data[98] = 3  # tile compression byte -> brotli
    p.write_bytes(bytes(data))
    with pytest.raises(ValidationError, match="tile compression brotli"):
        validate_output(p, BASEMAP)


def test_rejects_wrong_zoom_range(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=12)
    with pytest.raises(ValidationError, match="zoom range 0-12, expected 0-14"):
        validate_output(p, BASEMAP)


def test_rejects_wrong_tile_type(tmp_path):
    p = write_pmtiles(tmp_path / "t.pmtiles", tile_type=1, max_zoom=12, tile_compression=1)
    with pytest.raises(ValidationError, match="tile type mvt"):
        validate_output(p, TERRAIN)


def test_rejects_zero_tiles(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    data = bytearray(p.read_bytes())
    data[72:80] = (0).to_bytes(8, "little")  # addressed tiles
    p.write_bytes(bytes(data))
    with pytest.raises(ValidationError, match="zero tiles"):
        validate_output(p, BASEMAP)


def test_rejects_truncated_file(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    p.write_bytes(p.read_bytes()[:60])
    with pytest.raises(ValidationError, match="truncated"):
        validate_output(p, BASEMAP)


def test_size_cap_boundary(tmp_path, monkeypatch):
    p = write_pmtiles(tmp_path / "b.pmtiles", max_zoom=14)
    size = p.stat().st_size
    validate_output(p, Expectation(0, 14, frozenset({"mvt"}), size_cap=size + 1))
    with pytest.raises(ValidationError, match="exceeds the size cap"):
        validate_output(p, Expectation(0, 14, frozenset({"mvt"}), size_cap=size))


def test_lists_every_failure_at_once(tmp_path):
    p = write_pmtiles(tmp_path / "b.pmtiles", tile_type=4, max_zoom=12, tile_compression=1)
    with pytest.raises(ValidationError) as exc:
        validate_output(p, BASEMAP)
    assert "tile type webp" in str(exc.value) and "zoom range" in str(exc.value)


def test_constants():
    assert validate.SIZE_CAP == int(1.9 * 2**30)
    assert validate.BASE_PACK_CAP == 15_000_000
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_validate.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.validate'`

- [ ] **Step 3: Implement `validate.py`**

```python
# pipeline/src/maqs/validate.py
"""Checks every output before it can be reported or released."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

from maqs.pmtiles_header import PMTilesError, read_header, read_metadata

SIZE_CAP = int(1.9 * 2**30)
BASE_PACK_CAP = 15_000_000
TEST_REGION_WARN = 5_000_000
ALLOWED_COMPRESSION = {"none", "gzip"}


class ValidationError(Exception):
    """One or more checks failed; the message lists all of them."""


@dataclass(frozen=True)
class Expectation:
    min_zoom: int
    max_zoom: int
    tile_types: frozenset[str]
    size_cap: int = SIZE_CAP


@dataclass(frozen=True)
class OutputInfo:
    file: str
    bytes: int
    sha256: str
    tile_type: str
    min_zoom: int
    max_zoom: int
    tiles: int
    compression: str
    attribution: str | None
    source_data_date: str | None
    metadata: dict


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_output(path: Path, expect: Expectation) -> OutputInfo:
    failures: list[str] = []
    size = path.stat().st_size
    if size >= expect.size_cap:
        failures.append(f"{size} bytes exceeds the size cap of {expect.size_cap}")
    try:
        header = read_header(path)
        metadata = read_metadata(path, header)
    except PMTilesError as exc:
        raise ValidationError(f"{path.name}: {exc}" + ("; " + "; ".join(failures) if failures else "")) from exc
    if header.tile_compression not in ALLOWED_COMPRESSION:
        failures.append(f"tile compression {header.tile_compression} (MapLibre reads gzip or none only)")
    if header.internal_compression not in ALLOWED_COMPRESSION:
        failures.append(f"internal compression {header.internal_compression}")
    if (header.min_zoom, header.max_zoom) != (expect.min_zoom, expect.max_zoom):
        failures.append(
            f"zoom range {header.min_zoom}-{header.max_zoom}, expected {expect.min_zoom}-{expect.max_zoom}"
        )
    if header.tile_type not in expect.tile_types:
        failures.append(f"tile type {header.tile_type}, expected one of {sorted(expect.tile_types)}")
    if header.addressed_tiles == 0:
        failures.append("zero tiles")
    if failures:
        raise ValidationError(f"{path.name}: " + "; ".join(failures))
    return OutputInfo(
        file=path.name,
        bytes=size,
        sha256=sha256(path),
        tile_type=header.tile_type,
        min_zoom=header.min_zoom,
        max_zoom=header.max_zoom,
        tiles=header.addressed_tiles,
        compression=header.tile_compression,
        attribution=metadata.get("attribution"),
        source_data_date=metadata.get("planetiler:osm:osmosisreplicationtime"),
        metadata=metadata,
    )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_validate.py -q`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/validate.py pipeline/tests/test_validate.py
git commit -m "feat(pipeline): output validation with size cap, header checks and checksums"
```

---

### Task 6: Build context, step protocol and runner

**Files:**
- Create: `pipeline/src/maqs/context.py`, `pipeline/src/maqs/steps/__init__.py`, `pipeline/src/maqs/steps/base.py`, `pipeline/tests/test_steps_base.py`

**Interfaces:**
- Produces:
  - `@dataclass BuildContext(config: Config, dist: Path, cache: Path, force: bool, region: Region | None = None, base_pack: BasePack | None = None)` with `out_dir -> Path` (`dist/<region.id>` or `dist/base`), `label -> str`
  - `@dataclass StepResult(name: str, status: Literal["built", "skipped", "failed"], seconds: float, command: list[str], outputs: list[OutputInfo], error: str | None = None)`
  - `class Step(Protocol)`: `name: str`; `outputs(ctx) -> list[Path]`; `expectation(ctx) -> Expectation`; `build(ctx) -> list[str]` (returns the main argv it ran, for the report)
  - `run_step(step: Step, ctx: BuildContext) -> StepResult`: skip rule, timing, validation of every output (also when skipped), error capture; never raises for `ToolError`/`ValidationError`, converts them into `status="failed"`
  - `BuildError(Exception)`: raised by the CLI later when any result failed

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_steps_base.py
from pathlib import Path

import pytest

from maqs.config import load_config
from maqs.context import BuildContext
from maqs.steps.base import run_step
from maqs.tools import ToolError
from maqs.validate import Expectation
from tests.helpers import write_pmtiles

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


class FakeStep:
    name = "fake"

    def __init__(self, fail=False):
        self.calls = 0
        self.fail = fail

    def outputs(self, ctx):
        return [ctx.out_dir / f"{ctx.label}-fake.pmtiles"]

    def expectation(self, ctx):
        return Expectation(0, 14, frozenset({"mvt"}))

    def build(self, ctx):
        self.calls += 1
        if self.fail:
            raise ToolError(["versatiles", "convert"], 1, "kaboom")
        ctx.out_dir.mkdir(parents=True, exist_ok=True)
        write_pmtiles(self.outputs(ctx)[0], max_zoom=14)
        return ["versatiles", "convert", "x"]


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("test"))


def test_out_dir_and_label_for_region(ctx):
    assert ctx.out_dir == ctx.dist / "test" and ctx.label == "test"


def test_builds_then_skips_then_forces(ctx):
    step = FakeStep()
    first = run_step(step, ctx)
    assert first.status == "built" and step.calls == 1 and first.outputs[0].tiles == 1
    assert first.command == ["versatiles", "convert", "x"] and first.seconds >= 0
    second = run_step(step, ctx)
    assert second.status == "skipped" and step.calls == 1 and second.outputs[0].file == "test-fake.pmtiles"
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


def test_base_pack_context(tmp_path):
    cfg = load_config(REAL)
    ctx = BuildContext(config=cfg, dist=tmp_path, cache=tmp_path, force=False, base_pack=cfg.base_pack("triveneto"))
    assert ctx.out_dir == tmp_path / "base" and ctx.label == "base-triveneto"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_steps_base.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.context'`

- [ ] **Step 3: Implement `context.py` and `steps/base.py`**

```python
# pipeline/src/maqs/context.py
"""What every step needs to know about the current build."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from maqs.config import BasePack, Config, Region


@dataclass
class BuildContext:
    config: Config
    dist: Path
    cache: Path
    force: bool
    region: Region | None = None
    base_pack: BasePack | None = None

    @property
    def out_dir(self) -> Path:
        return self.dist / ("base" if self.base_pack else self.region.id)  # type: ignore[union-attr]

    @property
    def label(self) -> str:
        if self.base_pack:
            return f"base-{self.base_pack.id}"
        return self.region.id  # type: ignore[union-attr]
```

```python
# pipeline/src/maqs/steps/__init__.py
```

```python
# pipeline/src/maqs/steps/base.py
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
    status: Literal["built", "skipped", "failed"]
    if all(p.exists() for p in outputs) and not ctx.force:
        log.info("%s: skipped, outputs present", step.name)
        status = "skipped"
    else:
        ctx.out_dir.mkdir(parents=True, exist_ok=True)
        try:
            command = step.build(ctx)
        except ToolError as exc:
            log.error("%s: %s", step.name, exc)
            return StepResult(step.name, "failed", time.monotonic() - started, list(exc.argv), [], str(exc))
        status = "built"
    infos: list[OutputInfo] = []
    expect = step.expectation(ctx)
    for path in outputs:
        try:
            infos.append(validate_output(path, expect))
        except (ValidationError, FileNotFoundError) as exc:
            hint = " Rerun with --force to rebuild it." if status == "skipped" else ""
            log.error("%s: validation failed: %s", step.name, exc)
            return StepResult(step.name, "failed", time.monotonic() - started, command, infos, f"{exc}{hint}")
    return StepResult(step.name, status, time.monotonic() - started, command, infos)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_steps_base.py -q`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/context.py pipeline/src/maqs/steps
git add pipeline/tests/test_steps_base.py
git commit -m "feat(pipeline): build context, step protocol and runner with skip rule"
```

---

### Task 7: Basemap, terrain and base-pack steps

**Files:**
- Create: `pipeline/src/maqs/steps/tiles.py`, `pipeline/tests/test_steps_tiles.py`

**Interfaces:**
- Consumes: `BuildContext`, `Expectation`, `tools.run`, `tools.find_tool`
- Produces:
  - `OSM_SOURCE = "https://download.versatiles.org/osm-landcover.versatiles"`, `ELEVATION_SOURCE = "https://download.versatiles.org/elevation.versatiles"`
  - `format_bbox(bbox: Bbox) -> str` (`"10.6231,44.7923,13.1021,46.6806"`, no exponent notation)
  - `class BasemapStep` (`name = "basemap"`), `class TerrainStep` (`name = "terrain"`), `class BasePackStep` (`name = "base"`), each with `argv(ctx) -> list[str]` used by `build`
  - `TILE_STEPS: dict[str, type] = {"basemap": BasemapStep, "terrain": TerrainStep}`

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_steps_tiles.py
from pathlib import Path

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.steps import tiles
from maqs.steps.tiles import BasemapStep, BasePackStep, TerrainStep, format_bbox

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.fixture
def cfg():
    return load_config(REAL)


@pytest.fixture
def veneto(cfg, tmp_path):
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("veneto"))


@pytest.fixture
def versatiles_bin(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/versatiles"))


def test_format_bbox_is_plain_decimal():
    assert format_bbox((10.6231, 44.7923, 13.1021, 46.6806)) == "10.6231,44.7923,13.1021,46.6806"
    assert format_bbox((1e-7, 0.0, 180.0, 90.0)) == "0.0000001,0,180,90"


def test_basemap_argv_and_outputs(veneto, versatiles_bin):
    step = BasemapStep()
    assert step.outputs(veneto) == [veneto.dist / "veneto" / "veneto-basemap.pmtiles"]
    assert step.argv(veneto) == [
        "/usr/bin/versatiles", "convert",
        "--bbox", "10.6231,44.7923,13.1021,46.6806", "--bbox-border", "1", "--compress", "gzip",
        tiles.OSM_SOURCE, str(veneto.dist / "veneto" / "veneto-basemap.pmtiles"),
    ]
    e = step.expectation(veneto)
    assert (e.min_zoom, e.max_zoom) == (0, 14) and "mvt" in e.tile_types


def test_terrain_argv_and_outputs(veneto, versatiles_bin):
    step = TerrainStep()
    assert step.outputs(veneto) == [veneto.dist / "veneto" / "veneto-terrain.pmtiles"]
    assert step.argv(veneto) == [
        "/usr/bin/versatiles", "convert",
        "--bbox", "10.6231,44.7923,13.1021,46.6806", "--bbox-border", "1", "--max-zoom", "12",
        tiles.ELEVATION_SOURCE, str(veneto.dist / "veneto" / "veneto-terrain.pmtiles"),
    ]
    e = step.expectation(veneto)
    assert (e.min_zoom, e.max_zoom) == (0, 12) and e.tile_types == frozenset({"webp", "png"})


def test_base_pack_argv_outputs_and_cap(cfg, tmp_path, versatiles_bin):
    ctx = BuildContext(config=cfg, dist=tmp_path, cache=tmp_path, force=False, base_pack=cfg.base_pack("triveneto"))
    step = BasePackStep()
    assert step.outputs(ctx) == [tmp_path / "base" / "base-triveneto-basemap.pmtiles"]
    assert step.argv(ctx) == [
        "/usr/bin/versatiles", "convert",
        "--bbox", "10.3818,44.7923,13.9187,47.0921", "--max-zoom", "10", "--compress", "gzip",
        tiles.OSM_SOURCE, str(tmp_path / "base" / "base-triveneto-basemap.pmtiles"),
    ]
    e = step.expectation(ctx)
    assert (e.min_zoom, e.max_zoom) == (0, 10) and e.size_cap == 15_000_000


def test_build_runs_the_argv(veneto, versatiles_bin, monkeypatch):
    ran = []
    monkeypatch.setattr(tools, "run", lambda argv, **kw: ran.append([str(a) for a in argv]))
    step = BasemapStep()
    assert step.build(veneto) == step.argv(veneto)
    assert ran == [step.argv(veneto)]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_steps_tiles.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.steps.tiles'`

- [ ] **Step 3: Implement `steps/tiles.py`**

```python
# pipeline/src/maqs/steps/tiles.py
"""Tile layers cut from the VersaTiles planet archives by remote range requests (ADR 0004).

Basemap and base packs are recompressed to gzip because MapLibre Native rejects brotli
PMTiles; the elevation archive is already uncompressed WebP and is left untouched.
"""

from __future__ import annotations

from pathlib import Path

from maqs import tools
from maqs.config import Bbox
from maqs.context import BuildContext
from maqs.validate import BASE_PACK_CAP, Expectation

OSM_SOURCE = "https://download.versatiles.org/osm-landcover.versatiles"
ELEVATION_SOURCE = "https://download.versatiles.org/elevation.versatiles"
BASEMAP_MAX_ZOOM = 14
TERRAIN_MAX_ZOOM = 12


def format_bbox(bbox: Bbox) -> str:
    return ",".join(f"{v:.7f}".rstrip("0").rstrip(".") for v in bbox)


class _VersatilesStep:
    name = "tiles"
    suffix = ""

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-{self.suffix}.pmtiles"]

    def argv(self, ctx: BuildContext) -> list[str]:
        raise NotImplementedError

    def build(self, ctx: BuildContext) -> list[str]:
        argv = self.argv(ctx)
        tools.run(argv)
        return argv


class BasemapStep(_VersatilesStep):
    name = "basemap"
    suffix = "basemap"

    def argv(self, ctx: BuildContext) -> list[str]:
        assert ctx.region is not None
        return [
            str(tools.find_tool("versatiles")), "convert",
            "--bbox", format_bbox(ctx.region.bbox), "--bbox-border", "1", "--compress", "gzip",
            OSM_SOURCE, str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext) -> Expectation:
        return Expectation(0, BASEMAP_MAX_ZOOM, frozenset({"mvt", "mlt"}))


class TerrainStep(_VersatilesStep):
    name = "terrain"
    suffix = "terrain"

    def argv(self, ctx: BuildContext) -> list[str]:
        assert ctx.region is not None
        return [
            str(tools.find_tool("versatiles")), "convert",
            "--bbox", format_bbox(ctx.region.bbox), "--bbox-border", "1",
            "--max-zoom", str(TERRAIN_MAX_ZOOM),
            ELEVATION_SOURCE, str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext) -> Expectation:
        return Expectation(0, TERRAIN_MAX_ZOOM, frozenset({"webp", "png"}))


class BasePackStep(_VersatilesStep):
    name = "base"
    suffix = "basemap"

    def argv(self, ctx: BuildContext) -> list[str]:
        assert ctx.base_pack is not None
        bbox = ctx.config.base_pack_bbox(ctx.base_pack)
        return [
            str(tools.find_tool("versatiles")), "convert",
            "--bbox", format_bbox(bbox), "--max-zoom", str(ctx.base_pack.max_zoom), "--compress", "gzip",
            OSM_SOURCE, str(self.outputs(ctx)[0]),
        ]

    def expectation(self, ctx: BuildContext) -> Expectation:
        assert ctx.base_pack is not None
        return Expectation(0, ctx.base_pack.max_zoom, frozenset({"mvt", "mlt"}), size_cap=BASE_PACK_CAP)


TILE_STEPS: dict[str, type[_VersatilesStep]] = {"basemap": BasemapStep, "terrain": TerrainStep}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_steps_tiles.py -q`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/steps/tiles.py pipeline/tests/test_steps_tiles.py
git commit -m "feat(pipeline): basemap, terrain and base-pack steps"
```

---

### Task 8: terrain-hd step (Mapterhorn z6 archives)

**Files:**
- Create: `pipeline/src/maqs/steps/terrain_hd.py`, `pipeline/tests/test_steps_terrain_hd.py`

**Interfaces:**
- Consumes: `BuildContext`, `tools.run`, `tools.find_tool`, `Expectation`
- Produces:
  - `MAPTERHORN_BASE = "https://download.mapterhorn.com"`, `HD_MIN_ZOOM = 13`
  - `z6_tiles(bbox: Bbox) -> list[tuple[int, int]]` (x, y pairs of the zoom-6 Web Mercator tiles intersecting the bbox, sorted)
  - `archive_url(x: int, y: int) -> str`
  - `parse_dry_run_tiles(output: str) -> int` (the N in `fetching N tiles`)
  - `class TerrainHDStep` (`name = "terrain-hd"`): `outputs`, `expectation` (min 13, max per region or config), `build` (dry-run each archive, extract non-empty ones to `<out>.part-<x>-<y>`, merge when more than one, rename into place, delete parts)

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_steps_terrain_hd.py
from pathlib import Path

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.steps.terrain_hd import TerrainHDStep, archive_url, parse_dry_run_tiles, z6_tiles
from maqs.tools import ToolError

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


def test_z6_tiles_for_the_test_bbox_is_one_tile():
    assert z6_tiles((12.21, 46.08, 12.29, 46.13)) == [(34, 22)]


def test_z6_tiles_for_veneto_spans_four_archives():
    assert z6_tiles((10.6231, 44.7923, 13.1021, 46.6806)) == [(33, 22), (33, 23), (34, 22), (34, 23)]


def test_archive_url():
    assert archive_url(34, 22) == "https://download.mapterhorn.com/6-34-22.pmtiles"


def test_parse_dry_run_tiles():
    text = "2026/10/07 20:51:22 extract.go:450: fetching 4 tiles, 1 chunks, 1 requests\n"
    assert parse_dry_run_tiles(text) == 4
    assert parse_dry_run_tiles("no such line") == 0


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("veneto"))


def test_outputs_and_expectation(ctx, monkeypatch):
    step = TerrainHDStep()
    assert step.outputs(ctx) == [ctx.dist / "veneto" / "veneto-terrain-hd.pmtiles"]
    e = step.expectation(ctx)
    assert (e.min_zoom, e.max_zoom) == (13, 13)


def test_build_extracts_non_empty_archives_and_merges(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))
    calls = []

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        calls.append(argv)
        if "--dry-run" in argv:
            empty = "6-33-23" in argv[2] or "6-34-23" in argv[2]
            text = "fetching 0 tiles" if empty else "fetching 100 tiles, 2 chunks, 1 requests"

            class R:
                stdout, stderr = "", text

            return R()
        if argv[1] == "extract":
            Path(argv[3]).write_bytes(b"part")
        if argv[1] == "merge":
            Path(argv[-1]).write_bytes(b"merged")
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    step = TerrainHDStep()
    ctx.out_dir.mkdir(parents=True)
    command = step.build(ctx)
    extracts = [c for c in calls if c[1] == "extract" and "--dry-run" not in c]
    assert [c[2] for c in extracts] == [archive_url(33, 22), archive_url(34, 22)]
    assert all(c[-3:] == ["--bbox=10.6231,44.7923,13.1021,46.6806", "--minzoom=13", "--maxzoom=13"] for c in extracts)
    merges = [c for c in calls if c[1] == "merge"]
    assert len(merges) == 1 and command == merges[0]
    out = step.outputs(ctx)[0]
    assert out.read_bytes() == b"merged" and not list(ctx.out_dir.glob("*.part-*"))


def test_build_with_a_single_archive_skips_merge(tmp_path, monkeypatch):
    cfg = load_config(REAL)
    ctx = BuildContext(config=cfg, dist=tmp_path, cache=tmp_path, force=False, region=cfg.region("test"))
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        if "--dry-run" in argv:
            class R:
                stdout, stderr = "", "fetching 4 tiles, 1 chunks, 1 requests"

            return R()
        Path(argv[3]).write_bytes(b"part")
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    ctx.out_dir.mkdir(parents=True)
    command = TerrainHDStep().build(ctx)
    assert command[1] == "extract" and TerrainHDStep().outputs(ctx)[0].read_bytes() == b"part"


def test_build_fails_when_every_archive_is_empty(ctx, monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path("/usr/bin/pmtiles"))

    def fake_run(argv, **kw):
        class R:
            stdout, stderr = "", "fetching 0 tiles"

        return R()

    monkeypatch.setattr(tools, "run", fake_run)
    ctx.out_dir.mkdir(parents=True)
    with pytest.raises(ToolError, match="no high-resolution terrain tiles"):
        TerrainHDStep().build(ctx)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_steps_terrain_hd.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.steps.terrain_hd'`

- [ ] **Step 3: Implement `steps/terrain_hd.py`**

```python
# pipeline/src/maqs/steps/terrain_hd.py
"""Optional high-resolution terrain (z13+) from Mapterhorn's zoom-6 regional archives.

VersaTiles only hosts the planet at z0-12; Mapterhorn publishes z13-17 per zoom-6 tile as
`6-<x>-<y>.pmtiles`. Coverage is partial, so each archive is dry-run first and skipped
when it holds no tiles for the bbox. Opt-in: z14 for Veneto is ~1 GB (ADR 0001).
"""

from __future__ import annotations

import math
import re
from pathlib import Path

from maqs import tools
from maqs.config import Bbox
from maqs.context import BuildContext
from maqs.steps.tiles import format_bbox
from maqs.tools import ToolError
from maqs.validate import Expectation

MAPTERHORN_BASE = "https://download.mapterhorn.com"
HD_MIN_ZOOM = 13
_DRY_RUN_RE = re.compile(r"fetching (\d+) tiles")


def _tile_x(lon: float, z: int) -> int:
    return int(math.floor((lon + 180.0) / 360.0 * (1 << z)))


def _tile_y(lat: float, z: int) -> int:
    rad = math.radians(lat)
    return int(math.floor((1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * (1 << z)))


def z6_tiles(bbox: Bbox) -> list[tuple[int, int]]:
    lon_min, lat_min, lon_max, lat_max = bbox
    xs = range(_tile_x(lon_min, 6), _tile_x(lon_max, 6) + 1)
    ys = range(_tile_y(lat_max, 6), _tile_y(lat_min, 6) + 1)
    return sorted((x, y) for x in xs for y in ys)


def archive_url(x: int, y: int) -> str:
    return f"{MAPTERHORN_BASE}/6-{x}-{y}.pmtiles"


def parse_dry_run_tiles(output: str) -> int:
    match = _DRY_RUN_RE.search(output)
    return int(match.group(1)) if match else 0


class TerrainHDStep:
    name = "terrain-hd"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-terrain-hd.pmtiles"]

    def max_zoom(self, ctx: BuildContext) -> int:
        assert ctx.region is not None
        return ctx.region.hd_max_zoom or ctx.config.hd_max_zoom

    def expectation(self, ctx: BuildContext) -> Expectation:
        return Expectation(HD_MIN_ZOOM, self.max_zoom(ctx), frozenset({"webp", "png"}))

    def _extract_argv(self, url: str, part: Path, bbox: Bbox, max_zoom: int, dry_run: bool) -> list[str]:
        argv = [
            str(tools.find_tool("pmtiles")), "extract", url, str(part),
            f"--bbox={format_bbox(bbox)}", f"--minzoom={HD_MIN_ZOOM}", f"--maxzoom={max_zoom}",
        ]
        return [*argv, "--dry-run"] if dry_run else argv

    def build(self, ctx: BuildContext) -> list[str]:
        assert ctx.region is not None
        bbox, max_zoom = ctx.region.bbox, self.max_zoom(ctx)
        out = self.outputs(ctx)[0]
        parts: list[Path] = []
        for x, y in z6_tiles(bbox):
            url = archive_url(x, y)
            part = out.with_name(f"{out.name}.part-{x}-{y}")
            probe = tools.run(self._extract_argv(url, part, bbox, max_zoom, dry_run=True))
            if parse_dry_run_tiles((probe.stderr or "") + (probe.stdout or "")) == 0:
                continue
            tools.run(self._extract_argv(url, part, bbox, max_zoom, dry_run=False))
            parts.append(part)
        if not parts:
            raise ToolError(["pmtiles", "extract"], 1, f"no high-resolution terrain tiles cover {ctx.label}")
        if len(parts) == 1:
            parts[0].replace(out)
            return self._extract_argv(archive_url(*z6_tiles(bbox)[0]), out, bbox, max_zoom, dry_run=False)
        tmp = out.with_name(out.name + ".part-merged")
        argv = [str(tools.find_tool("pmtiles")), "merge", *(str(p) for p in parts), str(tmp)]
        tools.run(argv)
        tmp.replace(out)
        for p in parts:
            p.unlink(missing_ok=True)
        return argv
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_steps_terrain_hd.py -q`
Expected: all pass. If `test_build_with_a_single_archive_skips_merge` fails on the returned command, note that with one archive the step returns the extract argv rebuilt with the final output path; the test only checks `command[1] == "extract"`.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/steps/terrain_hd.py pipeline/tests/test_steps_terrain_hd.py
git commit -m "feat(pipeline): optional terrain-hd step from Mapterhorn z6 archives"
```

---

### Task 9: Build report

**Files:**
- Create: `pipeline/src/maqs/report.py`, `pipeline/tests/test_report.py`

**Interfaces:**
- Consumes: `StepResult`, `OutputInfo`, `tools.check_tools`
- Produces:
  - `REPORT_VERSION = 1`
  - `build_report(label: str, results: list[StepResult], tool_versions: dict[str, str | None], built_at: datetime | None = None) -> dict`
  - `write_report(path: Path, report: dict) -> None` (atomic: write `.tmp`, rename)
  - `report_path(out_dir: Path) -> Path` (`<out_dir>/build-report.json`)

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_report.py
import json
from datetime import UTC, datetime

from maqs.report import REPORT_VERSION, build_report, report_path, write_report
from maqs.steps.base import StepResult
from maqs.validate import OutputInfo


def info(name="test-basemap.pmtiles"):
    return OutputInfo(name, 10, "ab" * 32, "mvt", 0, 14, 26, "gzip", "© OSM", "2026-06-07T23:59:58Z", {"k": "v"})


def test_report_shape():
    results = [
        StepResult("basemap", "built", 7.7, ["versatiles", "convert"], [info()]),
        StepResult("terrain", "failed", 1.0, [], [], error="boom"),
    ]
    report = build_report("test", results, {"versatiles": "5.0.0", "pmtiles": "dev"}, built_at=datetime(2026, 10, 8, 14, 2, 11, tzinfo=UTC))
    assert report["report_version"] == REPORT_VERSION and report["region"] == "test"
    assert report["built_at"] == "2026-10-08T14:02:11Z"
    assert report["tools"] == {"versatiles": "5.0.0", "pmtiles": "dev"}
    basemap = report["steps"][0]
    assert basemap["status"] == "built" and basemap["seconds"] == 7.7 and basemap["command"] == ["versatiles", "convert"]
    out = basemap["outputs"][0]
    assert out["file"] == "test-basemap.pmtiles" and out["sha256"] == "ab" * 32 and out["tiles"] == 26
    assert out["attribution"] == "© OSM" and out["source_data_date"] == "2026-06-07T23:59:58Z"
    assert "metadata" not in out
    assert report["steps"][1]["error"] == "boom"
    assert report["validation"] == {"ok": False, "failures": ["terrain: boom"]}


def test_report_ok_when_nothing_failed():
    report = build_report("x", [StepResult("basemap", "skipped", 0.0, [], [info()])], {})
    assert report["validation"] == {"ok": True, "failures": []}


def test_write_report_is_json_and_atomic(tmp_path):
    path = report_path(tmp_path)
    write_report(path, {"a": 1})
    assert json.loads(path.read_text()) == {"a": 1}
    assert not (tmp_path / "build-report.json.tmp").exists()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_report.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.report'`

- [ ] **Step 3: Implement `report.py`**

```python
# pipeline/src/maqs/report.py
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
        step = {"name": r.name, "status": r.status, "seconds": round(r.seconds, 3), "command": r.command, "outputs": outputs}
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_report.py -q`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/report.py pipeline/tests/test_report.py
git commit -m "feat(pipeline): build report writer"
```

---

### Task 10: CLI wiring, test-region build, bbox tuning

**Files:**
- Modify: `pipeline/src/maqs/cli.py` (replace the stubs), `config/regions.yaml` (tune the `test` bbox if needed)
- Create: `pipeline/tests/test_cli.py`, `pipeline/tests/conftest.py`, `pipeline/tests/test_integration_network.py`

**Interfaces:**
- Consumes: everything above.
- Produces: the working commands `maqs build`, `maqs regions`, `maqs check-tools`; `run_build(config, *, target, layers, dist, cache, force) -> list[tuple[str, dict]]` (label, report) used by tests; exit codes 0 success, 1 build/validation failure, 2 usage error.

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/conftest.py
import pytest


def pytest_addoption(parser):
    parser.addoption("--run-network", action="store_true", default=False, help="run tests that hit live sources")


def pytest_collection_modifyitems(config, items):
    if config.getoption("--run-network"):
        return
    skip = pytest.mark.skip(reason="needs --run-network")
    for item in items:
        if "network" in item.keywords:
            item.add_marker(skip)
```

```python
# pipeline/tests/test_cli.py
import json
from pathlib import Path

from click.testing import CliRunner

from maqs import cli, tools
from maqs.cli import main
from maqs.tools import ToolStatus
from tests.helpers import write_pmtiles

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


def ok_tools(monkeypatch):
    statuses = [ToolStatus(n, v, v, Path(f"/fake/{n}"), True, "ok") for n, v in tools.PINS.items()]
    monkeypatch.setattr(cli, "check_tools", lambda: statuses)


def test_regions_lists_ids_extracts_and_base_packs(monkeypatch):
    result = CliRunner().invoke(main, ["--config", str(REAL), "regions"])
    assert result.exit_code == 0
    for s in ("test", "triveneto", "veneto", "europe/italy/nord-est", "base-triveneto", "10.3818,44.7923,13.9187,47.0921"):
        assert s in result.output


def test_check_tools_exit_codes(monkeypatch):
    ok_tools(monkeypatch)
    assert CliRunner().invoke(main, ["check-tools"]).exit_code == 0
    bad = [ToolStatus("versatiles", "5.0.0", "4.9.0", Path("/x"), False, "found 4.9.0, pinned 5.0.0")]
    monkeypatch.setattr(cli, "check_tools", lambda: bad)
    result = CliRunner().invoke(main, ["check-tools"])
    assert result.exit_code == 1 and "4.9.0" in result.output


def test_build_refuses_unknown_region(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "nope", "--dist", str(tmp_path)])
    assert result.exit_code == 2
    assert "unknown region 'nope'" in result.output and "veneto" in result.output


def test_build_refuses_a_base_pack_id_as_region(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "base-triveneto", "--dist", str(tmp_path)])
    assert result.exit_code == 2 and "--region base" in result.output


def test_build_refuses_unknown_layer(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--layers", "lava", "--dist", str(tmp_path)])
    assert result.exit_code == 2 and "unknown layer 'lava'" in result.output


def test_build_stops_on_tool_mismatch(monkeypatch, tmp_path):
    bad = [ToolStatus("versatiles", "5.0.0", "4.9.0", Path("/x"), False, "found 4.9.0, pinned 5.0.0")]
    monkeypatch.setattr(cli, "check_tools", lambda: bad)
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(tmp_path)])
    assert result.exit_code == 1 and "pinned 5.0.0" in result.output


def test_build_runs_steps_and_writes_report(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        out = Path(argv[-1])
        out.parent.mkdir(parents=True, exist_ok=True)
        if "elevation.versatiles" in argv[-2]:
            write_pmtiles(out, tile_type=4, max_zoom=12, tile_compression=1)
        else:
            write_pmtiles(out, tile_type=1, max_zoom=14, metadata={"attribution": "© OSM"})
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(tmp_path)])
    assert result.exit_code == 0, result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert [s["name"] for s in report["steps"]] == ["basemap", "terrain"]
    assert report["validation"]["ok"] is True
    assert (tmp_path / "test" / "test-basemap.pmtiles").exists()
    second = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(tmp_path)])
    assert second.exit_code == 0 and "skipped" in second.output


def test_build_exit_1_when_a_step_fails(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        raise tools.ToolError([str(a) for a in argv], 1, "network down")

    monkeypatch.setattr(tools, "run", fake_run)
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(tmp_path)])
    assert result.exit_code == 1 and "network down" in result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert report["validation"]["ok"] is False


def test_build_base_packs(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        out = Path(str(argv[-1]))
        out.parent.mkdir(parents=True, exist_ok=True)
        write_pmtiles(out, tile_type=1, max_zoom=10)
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "base", "--dist", str(tmp_path)])
    assert result.exit_code == 0, result.output
    assert (tmp_path / "base" / "base-triveneto-basemap.pmtiles").exists()
    assert (tmp_path / "base" / "build-report.json").exists()
```

```python
# pipeline/tests/test_integration_network.py
"""Builds the test region against the live VersaTiles archives. Run with --run-network."""

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from maqs.cli import main

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.mark.network
def test_test_region_builds_end_to_end(tmp_path):
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(tmp_path)])
    assert result.exit_code == 0, result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert report["validation"]["ok"] is True
    by_name = {s["name"]: s for s in report["steps"]}
    basemap, terrain = by_name["basemap"]["outputs"][0], by_name["terrain"]["outputs"][0]
    assert basemap["compression"] == "gzip" and basemap["max_zoom"] == 14 and basemap["tiles"] > 20
    assert terrain["tile_type"] == "webp" and terrain["max_zoom"] == 12
    assert basemap["bytes"] + terrain["bytes"] < 5_000_000
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_cli.py -q`
Expected: FAIL (the stub commands raise "not implemented yet"; `--config` is not an option yet).

- [ ] **Step 3: Implement the CLI**

```python
# pipeline/src/maqs/cli.py
"""Command-line entry point: build, regions, check-tools."""

from __future__ import annotations

import logging
from pathlib import Path

import click

from maqs.config import DEFAULT_CONFIG_PATH, Config, ConfigError, load_config
from maqs.context import BuildContext
from maqs.report import build_report, report_path, write_report
from maqs.steps.base import Step, run_step
from maqs.steps.terrain_hd import TerrainHDStep
from maqs.steps.tiles import TILE_STEPS, BasePackStep
from maqs.tools import PINS, check_tools
from maqs.validate import TEST_REGION_WARN

DEFAULT_LAYERS = ("basemap", "terrain")
LAYER_STEPS: dict[str, type] = {**TILE_STEPS, "terrain-hd": TerrainHDStep}


def _find_config(explicit: Path | None) -> Path:
    if explicit:
        return explicit
    here = Path.cwd().resolve()
    for candidate in (here, *here.parents):
        path = candidate / DEFAULT_CONFIG_PATH
        if path.exists():
            return path
    raise click.ClickException(f"{DEFAULT_CONFIG_PATH} not found in {here} or any parent; pass --config")


@click.group()
@click.version_option(package_name="maqs")
@click.option("--config", "config_path", type=click.Path(path_type=Path), default=None, help="Path to regions.yaml.")
@click.option("-v", "--verbose", is_flag=True, help="Debug logging.")
@click.pass_context
def main(ctx: click.Context, config_path: Path | None, verbose: bool) -> None:
    """Build and inspect maqs data packs."""
    logging.basicConfig(level=logging.DEBUG if verbose else logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    ctx.obj = {"config_path": config_path}


def _load(ctx: click.Context) -> Config:
    try:
        return load_config(_find_config(ctx.obj["config_path"]))
    except ConfigError as exc:
        raise click.ClickException(f"invalid configuration: {exc}") from exc


@main.command()
@click.pass_context
def regions(ctx: click.Context) -> None:
    """List configured regions, their OSM extracts, and the base packs."""
    cfg = _load(ctx)
    for r in cfg.regions:
        extract = r.osm.get("geofabrik", "-") if r.osm else "-"
        flag = " (fixture)" if r.fixture else ""
        click.echo(f"{r.id}{flag}: {r.name['en']} / {r.name['it']}  bbox={','.join(str(v) for v in r.bbox)}  osm={extract}")
    for p in cfg.base_packs:
        bbox = cfg.base_pack_bbox(p)
        click.echo(f"base-{p.id}: regions={','.join(p.regions)} max_zoom={p.max_zoom} bbox={','.join(str(v) for v in bbox)}")
    click.echo(f"geofabrik extracts: {', '.join(cfg.geofabrik_extracts()) or '-'}")


def _print_tool_statuses() -> bool:
    ok = True
    for s in check_tools():
        click.echo(f"{s.name:<11} pinned {s.pinned:<8} found {s.found or '-':<8} {s.note}")
        ok &= s.ok
    return ok


@main.command("check-tools")
def check_tools_command() -> None:
    """Verify the pinned external tools are installed at the pinned versions."""
    if not _print_tool_statuses():
        raise click.ClickException("tool check failed; run pipeline/bootstrap.sh")


def _parse_layers(raw: str) -> list[str]:
    layers = [s.strip() for s in raw.split(",") if s.strip()]
    for layer in layers:
        if layer not in LAYER_STEPS:
            raise click.UsageError(f"unknown layer '{layer}'; valid: {', '.join(LAYER_STEPS)}")
    return layers


def _targets(cfg: Config, target: str) -> list[BuildContext]:
    if target == "base":
        return [BuildContext(cfg, Path(), Path(), False, base_pack=p) for p in cfg.base_packs]
    if target == "all":
        return [BuildContext(cfg, Path(), Path(), False, region=cfg.region(rid)) for rid in cfg.region_ids(include_fixtures=True)]
    if target.startswith("base-"):
        raise click.UsageError("base packs are built with --region base")
    try:
        return [BuildContext(cfg, Path(), Path(), False, region=cfg.region(target))]
    except KeyError:
        valid = ", ".join([*cfg.region_ids(include_fixtures=True), "all", "base"])
        raise click.UsageError(f"unknown region '{target}'; valid: {valid}") from None


def run_build(
    cfg: Config, *, target: str, layers: list[str], dist: Path, cache: Path, force: bool
) -> list[tuple[str, dict]]:
    reports: list[tuple[str, dict]] = []
    versions = {s.name: s.found for s in check_tools()}
    for ctx in _targets(cfg, target):
        ctx.dist, ctx.cache, ctx.force = dist, cache, force
        steps: list[Step] = [BasePackStep()] if ctx.base_pack else [LAYER_STEPS[name]() for name in layers]
        results = [run_step(step, ctx) for step in steps]
        for r in results:
            click.echo(f"{ctx.label}: {r.name} {r.status} in {r.seconds:.1f}s" + (f" — {r.error}" if r.error else ""))
        if ctx.region and ctx.region.fixture:
            total = sum(o.bytes for r in results for o in r.outputs if o.file.endswith(("-basemap.pmtiles", "-terrain.pmtiles")))
            if total > TEST_REGION_WARN:
                click.echo(f"warning: {ctx.label} basemap+terrain is {total} bytes, over {TEST_REGION_WARN}; shrink its bbox")
        report = build_report(ctx.label, results, versions)
        write_report(report_path(ctx.out_dir), report)
        reports.append((ctx.label, report))
    return reports


@main.command()
@click.option("--region", "target", required=True, help="A region id, 'all', or 'base'.")
@click.option("--layers", default=",".join(DEFAULT_LAYERS), show_default=True, help="Comma-separated layer names.")
@click.option("--force", is_flag=True, help="Rebuild even when outputs exist.")
@click.option("--dist", type=click.Path(path_type=Path), default=Path("dist"), show_default=True)
@click.option("--cache", type=click.Path(path_type=Path), default=Path(".cache"), show_default=True)
@click.pass_context
def build(ctx: click.Context, target: str, layers: str, force: bool, dist: Path, cache: Path) -> None:
    """Build layers for a region (or all regions, or the base packs)."""
    cfg = _load(ctx)
    layer_names = _parse_layers(layers)
    _targets(cfg, target)  # validate before touching tools
    if not _print_tool_statuses():
        raise click.ClickException("tool check failed; run pipeline/bootstrap.sh")
    reports = run_build(cfg, target=target, layers=layer_names, dist=dist, cache=cache, force=force)
    failed = [label for label, report in reports if not report["validation"]["ok"]]
    if failed:
        raise click.ClickException(f"build failed for: {', '.join(failed)} (see build-report.json)")
    click.echo("ok")
```

Note: `ctx.obj` must exist for `_load`; `CliRunner` invokes `main` so the group callback always runs first.

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `uv run pytest -q`
Expected: all pass; the network test is reported as skipped.

- [ ] **Step 5: Run the real test-region build**

Run (from `pipeline/`): `uv run maqs build --region test --dist /tmp/maqs-dist --force`
Expected: `test: basemap built in ~10s`, `test: terrain built in ~5s`, `ok`. Then inspect: `python3 -c "import json; r=json.load(open('/tmp/maqs-dist/test/build-report.json')); print([(o['file'], o['bytes'], o['tiles']) for s in r['steps'] for o in s['outputs']])"`.

- [ ] **Step 6: Tune the test bbox**

If basemap + terrain exceed 5,000,000 bytes, shrink the `test` bbox in `config/regions.yaml` (keep it centred on Nevegal, 12.25 E 46.10 N) and rerun Step 5 until it is under 5 MB; if it is far under (say < 2 MB), widen it up to the spec's ~35 km² so plan 2 has enough trails. Record the final bbox and sizes for ADR 0009 (Task 13).

- [ ] **Step 7: Run the network integration test**

Run: `uv run pytest tests/test_integration_network.py --run-network -q`
Expected: `1 passed`.

- [ ] **Step 8: Build a real base pack and Veneto once, to confirm the numbers**

Run: `uv run maqs build --region base --dist /tmp/maqs-dist` and `uv run maqs build --region veneto --dist /tmp/maqs-dist`
Expected: base pack under 15 MB and `ok`; Veneto basemap ≈ 240 MB with ≈ 19,000 tiles and terrain ≈ 105 MB, `ok`. Note the figures for `docs/data-format.md`.

- [ ] **Step 9: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/cli.py pipeline/tests/test_cli.py pipeline/tests/conftest.py pipeline/tests/test_integration_network.py config/regions.yaml
git commit -m "feat(pipeline): build, regions and check-tools commands; test region builds end to end"
```

---

### Task 11: bootstrap.sh

**Files:**
- Create: `pipeline/bootstrap.sh`

**Interfaces:**
- Produces: `pipeline/bootstrap.sh [--check]`; pins at the top of the file equal `maqs.tools.PINS`; installs into Homebrew on macOS and into `/usr/local/bin` on Ubuntu (needs `sudo` on CI).

- [ ] **Step 1: Write the script**

```sh
#!/bin/sh
# Installs the pinned external CLIs the maqs pipeline uses, on macOS (Homebrew) and
# Ubuntu 24.04 (release binaries or source builds). `--check` only verifies versions.
# Pins here must match maqs/tools.py PINS; `maqs check-tools` is the authority.
set -eu

VERSATILES_VERSION="5.0.0"
PMTILES_VERSION="1.31.2"
OSMIUM_VERSION="1.19.1"
LIBOSMIUM_VERSION="2.23.1"
TIPPECANOE_VERSION="2.79.0"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

os="$(uname -s)"
arch="$(uname -m)"

have() { command -v "$1" >/dev/null 2>&1; }

version_of() {
  case "$1" in
    versatiles) versatiles --version 2>/dev/null | head -1 | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' ;;
    pmtiles)    pmtiles version 2>/dev/null | head -1 | sed -E 's/^pmtiles ([^,]+),.*/\1/' ;;
    osmium)     osmium --version 2>/dev/null | head -1 | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' ;;
    tippecanoe) tippecanoe --version 2>&1 | head -1 | sed -E 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/' ;;
  esac
}

report() {
  status=0
  for tool in versatiles pmtiles osmium tippecanoe; do
    if have "$tool"; then
      printf '%-11s %s\n' "$tool" "$(version_of "$tool")"
    else
      printf '%-11s missing\n' "$tool"; status=1
    fi
  done
  return $status
}

if [ "$CHECK_ONLY" = 1 ]; then report; exit $?; fi

install_macos() {
  have brew || { echo "Homebrew is required on macOS" >&2; exit 1; }
  brew tap versatiles-org/versatiles >/dev/null
  brew install versatiles pmtiles osmium-tool tippecanoe
}

install_ubuntu() {
  sudo apt-get update -q
  sudo apt-get install -y -q curl ca-certificates build-essential cmake git \
    libboost-program-options-dev libbz2-dev zlib1g-dev libexpat1-dev liblz4-dev \
    nlohmann-json3-dev libprotozero-dev libsqlite3-dev

  case "$arch" in
    x86_64) vt_arch="x86_64"; pm_arch="x86_64" ;;
    aarch64|arm64) vt_arch="aarch64"; pm_arch="arm64" ;;
    *) echo "unsupported arch $arch" >&2; exit 1 ;;
  esac

  tmp="$(mktemp -d)"
  if [ "$(version_of versatiles)" != "$VERSATILES_VERSION" ]; then
    curl -fsSL -o "$tmp/versatiles.deb" \
      "https://github.com/versatiles-org/versatiles-rs/releases/download/v${VERSATILES_VERSION}/versatiles-linux-gnu-${vt_arch}.deb"
    sudo dpkg -i "$tmp/versatiles.deb"
  fi
  if [ "$(version_of pmtiles)" != "$PMTILES_VERSION" ]; then
    curl -fsSL -o "$tmp/pmtiles.tgz" \
      "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_${pm_arch}.tar.gz"
    tar -xzf "$tmp/pmtiles.tgz" -C "$tmp" pmtiles
    sudo install -m 0755 "$tmp/pmtiles" /usr/local/bin/pmtiles
  fi
  if [ "$(version_of osmium)" != "$OSMIUM_VERSION" ]; then
    git clone -q --depth 1 -b "v${LIBOSMIUM_VERSION}" https://github.com/osmcode/libosmium "$tmp/libosmium"
    git clone -q --depth 1 -b "v${OSMIUM_VERSION}" https://github.com/osmcode/osmium-tool "$tmp/osmium-tool"
    cmake -S "$tmp/osmium-tool" -B "$tmp/osmium-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      -DOSMIUM_INCLUDE_DIR="$tmp/libosmium/include" >/dev/null
    cmake --build "$tmp/osmium-build" -j "$(nproc)" >/dev/null
    sudo install -m 0755 "$tmp/osmium-build/src/osmium" /usr/local/bin/osmium
  fi
  if [ "$(version_of tippecanoe)" != "$TIPPECANOE_VERSION" ]; then
    git clone -q --depth 1 -b "${TIPPECANOE_VERSION}" https://github.com/felt/tippecanoe "$tmp/tippecanoe"
    make -C "$tmp/tippecanoe" -j "$(nproc)" >/dev/null
    sudo make -C "$tmp/tippecanoe" install >/dev/null
  fi
  rm -rf "$tmp"
}

case "$os" in
  Darwin) install_macos ;;
  Linux)  install_ubuntu ;;
  *) echo "unsupported OS $os" >&2; exit 1 ;;
esac

report
```

- [ ] **Step 2: Run the check on this machine**

Run: `chmod +x pipeline/bootstrap.sh && pipeline/bootstrap.sh --check && (cd pipeline && uv run maqs check-tools)`
Expected: four lines with versions (pmtiles shows `dev`), exit 0; `maqs check-tools` exit 0.

- [ ] **Step 3: Lint the shell**

Run: `brew install shellcheck 2>/dev/null; shellcheck pipeline/bootstrap.sh`
Expected: no findings (fix any; `sed` version extraction and `$(nproc)` are the usual suspects).

- [ ] **Step 4: Commit**

```bash
git add pipeline/bootstrap.sh
git commit -m "feat(pipeline): bootstrap script installing pinned CLIs on macOS and Ubuntu"
```

The Ubuntu branch is proven by the CI workflow in Task 12; if a source build fails there, fix the script in that task and note the fix in `docs/architecture.md`.

---

### Task 12: CI workflow for the pipeline

**Files:**
- Create: `.github/workflows/pipeline.yml`

**Interfaces:**
- Produces: on push and pull request touching `pipeline/**`, `config/**`, or the workflow: job `unit` (ruff + pytest on Ubuntu) and job `smoke` (bootstrap, `maqs check-tools`, `maqs build --region test`, upload `dist/test` as artifact `test-region-fixtures`, retention 7 days). Tool binaries cached by pin. This is the artifact `swift.yml` (Phase 4) consumes.

- [ ] **Step 1: Verify the action tags exist**

Run: `for a in actions/checkout actions/cache actions/upload-artifact astral-sh/setup-uv; do echo "$a: $(gh api repos/$a/tags --jq '.[].name' | grep -E '^v[0-9]+$' | sort -V | tail -1)"; done`
Expected: a latest major tag per action (for example `v4`, `v4`, `v4`, `v6`). Use those exact tags below; do not guess.

- [ ] **Step 2: Write the workflow (replace the tags with Step 1's output)**

```yaml
# .github/workflows/pipeline.yml
name: pipeline

on:
  push:
    branches: [main]
    paths: ["pipeline/**", "config/**", ".github/workflows/pipeline.yml"]
  pull_request:
    paths: ["pipeline/**", "config/**", ".github/workflows/pipeline.yml"]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: pipeline-${{ github.ref }}
  cancel-in-progress: true

jobs:
  unit:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: pipeline } }
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v6
        with: { enable-cache: true }
      - run: uv sync --frozen
      - run: uv run ruff check . && uv run ruff format --check .
      - run: uv run pytest -q

  smoke:
    runs-on: ubuntu-latest
    needs: unit
    timeout-minutes: 30
    env:
      TOOLS_KEY: versatiles-5.0.0-pmtiles-1.31.2-osmium-1.19.1-tippecanoe-2.79.0
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v6
        with: { enable-cache: true }
      - name: Cache tool binaries
        id: tools-cache
        uses: actions/cache@v4
        with:
          path: |
            /usr/local/bin/versatiles
            /usr/local/bin/pmtiles
            /usr/local/bin/osmium
            /usr/local/bin/tippecanoe
            /usr/local/bin/tile-join
          key: tools-${{ runner.os }}-${{ runner.arch }}-${{ env.TOOLS_KEY }}
      - name: Bootstrap tools
        if: steps.tools-cache.outputs.cache-hit != 'true'
        run: pipeline/bootstrap.sh
      - name: Runtime libraries for cached binaries
        if: steps.tools-cache.outputs.cache-hit == 'true'
        run: sudo apt-get update -q && sudo apt-get install -y -q libboost-program-options1.83.0 liblz4-1 libexpat1 libbz2-1.0 libsqlite3-0
      - run: pipeline/bootstrap.sh --check
      - run: uv sync --frozen
        working-directory: pipeline
      - run: uv run maqs check-tools
        working-directory: pipeline
      - name: Build the test region
        run: uv run maqs build --region test --dist "$GITHUB_WORKSPACE/dist"
        working-directory: pipeline
      - run: cat dist/test/build-report.json
      - uses: actions/upload-artifact@v4
        with:
          name: test-region-fixtures
          path: dist/test
          retention-days: 7
          if-no-files-found: error
```

The versatiles `.deb` installs to `/usr/bin/versatiles`; if `bootstrap.sh --check` finds it there, add `/usr/bin/versatiles` to the cache path list or symlink it into `/usr/local/bin` in the script. The exact runtime library package names for cached binaries (`libboost-program-options1.83.0` on Ubuntu 24.04) must be confirmed from the smoke run's first failure, if any.

- [ ] **Step 3: Validate the YAML locally**

Run: `python3 -I -c "import yaml,sys; yaml.safe_load(open('.github/workflows/pipeline.yml')); print('yaml ok')"` (use `uv run --with pyyaml python` if system python lacks yaml).
Expected: `yaml ok`.

- [ ] **Step 4: Commit, push, and watch the run**

```bash
git add .github/workflows/pipeline.yml
git commit -m "ci: lint, unit tests and test-region smoke build for the pipeline"
git push origin main
gh run watch --exit-status
```

Expected: both jobs green; the artifact `test-region-fixtures` is listed on the run. If `smoke` fails in `bootstrap.sh` (source build or missing library), fix the script or the runtime-library step, commit, and push again until green. Record the cold-run and warm-run durations for `docs/architecture.md`.

---

### Task 13: Documentation and ADR 0009

**Files:**
- Create: `docs/data-format.md`, `docs/architecture.md`, `README.md`, `DATA_LICENSE.md`
- Modify: `docs/decisions.md` (append ADR 0009), `CLAUDE.md` (Commands section: mark the pipeline commands as real; add `--run-network`)

- [ ] **Step 1: Write `docs/data-format.md`**

```markdown
# Data formats

Every file maqs publishes, versioned. A format change bumps the version named in its section and states the compatibility rule. Plan 2 adds the SQLite layers and overlay tiles.

## Tile archives (PMTiles v3)

All tile outputs are [PMTiles v3](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md) archives, clustered, with `internal_compression` gzip and `tile_compression` gzip or none. MapLibre Native reads gzip or none only (brotli and zstd are rejected), so the pipeline recompresses VersaTiles' brotli basemap tiles to gzip.

| File | Layer | Tile type | Zoom | Tile compression | Source |
|---|---|---|---|---|---|
| `<region>-basemap.pmtiles` | basemap | MVT, Shortbread 1.0 (OSM + ESA WorldCover landcover) | 0–14 | gzip | `download.versatiles.org/osm-landcover.versatiles`, bbox + 1 tile border |
| `<region>-terrain.pmtiles` | terrain | WebP 512 px, terrarium-encoded DEM | 0–12 | none | `download.versatiles.org/elevation.versatiles` (Mapterhorn), bbox + 1 tile border |
| `<region>-terrain-hd.pmtiles` | terrain-hd (opt-in) | WebP 512 px, terrarium | 13–`hd_max_zoom` (13 by default) | none | `download.mapterhorn.com/6-<x>-<y>.pmtiles`, merged when the bbox spans several |
| `base-<pack>-basemap.pmtiles` | base pack (bundled in apps) | MVT, Shortbread 1.0 | 0–`max_zoom` (10) | gzip | as basemap, union bbox of the pack's regions, no border |

Terrarium decoding: `elevation_m = (R * 256 + G + B / 256) - 32768`. At zoom 12 one pixel is ~27 m at 46° N.

The archive metadata (`versatiles probe`, or the header reader in `pipeline/src/maqs/pmtiles_header.py`) carries the upstream `attribution` and, for the basemap, `planetiler:osm:osmosisreplicationtime`, which the build report copies out as `source_data_date`.

Measured sizes (2026-10-08, see `docs/decisions.md` ADR 0001 and 0009): test region basemap + terrain under 5 MB; Veneto 238 MB + 105 MB; Triveneto 431 MB + 291 MB; base pack `triveneto` 13 MB.

## Build report (`build-report.json`, `report_version` 1)

Written to `dist/<region>/build-report.json` (and `dist/base/`) on every run.

| Field | Meaning |
|---|---|
| `report_version` | 1 |
| `region` | region id, or `base-<pack>` |
| `built_at` | ISO 8601 UTC |
| `tools` | tool name → version string found (`dev` for the Homebrew pmtiles build) |
| `steps[]` | `name`, `status` (`built`, `skipped`, `failed`), `seconds`, `command` (argv), `outputs[]`, `error` when failed |
| `steps[].outputs[]` | `file`, `bytes`, `sha256`, `tile_type`, `min_zoom`, `max_zoom`, `tiles`, `compression`, `attribution`, `source_data_date` |
| `validation` | `ok` and the list of `failures` (`<step>: <message>`) |

Compatibility rule: readers ignore unknown fields; a new `report_version` means a field changed meaning or was removed.

## Validation rules

Every output: size < 1.9 GiB; readable PMTiles v3 header and metadata; tile compression gzip or none; zoom range exactly as the layer specifies; tile type as the layer specifies; at least one tile; SHA-256 recorded. Base packs: < 15 MB. Test region: warning when basemap + terrain exceed 5 MB.
```

- [ ] **Step 2: Write `docs/architecture.md`**

```markdown
# Architecture

## Pipeline (`pipeline/`)

A thin Python orchestrator around pinned CLIs. One map provider, VersaTiles, for every tile online and offline (ADR 0004); Geofabrik for OSM data (plan 2).

- **Entry point:** `uv run maqs build --region <id>|all|base [--layers …] [--force]`, plus `maqs regions` and `maqs check-tools`.
- **Configuration:** `config/regions.yaml` (`maqs/config.py`). A region is the smallest pack unit; `fixture: true` regions exist for tests only; `base_packs` are named lists of regions bundled inside apps; `osm.geofabrik` and `clip.admin` tell plan 2 where a region's OSM data comes from and how to cut it. Regions can be anywhere in the world.
- **Steps:** `maqs/steps/`. Each implements `outputs(ctx)`, `expectation(ctx)` and `build(ctx)`. The runner (`steps/base.py`) skips a step whose outputs all exist unless `--force`, then validates every output, including skipped ones, so a truncated file from a crashed run is caught and reported with a `--force` hint.
- **Tools:** `maqs/tools.py` is the only place a subprocess starts: no shell, exact command logged, non-zero exit raised as `ToolError`. Version pins live in `PINS` and in `bootstrap.sh`; `check-tools` fails on mismatch (Homebrew's `pmtiles` reports `dev` and is accepted with a note).
- **Validation and report:** `maqs/validate.py` reads the PMTiles header directly (`maqs/pmtiles_header.py`) and writes `build-report.json` (`maqs/report.py`). Formats are in `docs/data-format.md`.
- **Directories:** `.cache/` for downloads, `dist/<region>/` for outputs; both gitignored; nothing generated is ever committed.

### Tile layers

`versatiles convert --bbox … --bbox-border 1` reads the planet archives by HTTP range requests (no planet download): basemap with `--compress gzip` (MapLibre rejects brotli), terrain at z0–12 as stored. `terrain-hd` is opt-in and reads Mapterhorn's zoom-6 regional archives with `pmtiles extract`, after a dry run per archive to skip those with no coverage, merging when a region spans several.

### CI

`.github/workflows/pipeline.yml`: `unit` (ruff + pytest) then `smoke`, which bootstraps the pinned tools (cached by pin), builds the `test` region against the live archives, prints the report and uploads `dist/test` as the `test-region-fixtures` artifact. The Swift tests (Phase 4) download that artifact instead of committing binaries. Cold run ≈ <fill from Task 12>; warm run ≈ <fill from Task 12>.

## Swift package

Phase 4. See `docs/BRIEF.md` and ADR 0003 (MapLibre on iOS/iPadOS only; `MaqsCore`, `MaqsData`, `MaqsTerrain` also on macOS).
```

Replace the two `<fill from Task 12>` placeholders with the measured durations before committing.

- [ ] **Step 3: Write `README.md` and `DATA_LICENSE.md`**

```markdown
# maqs

Map data and a Swift package for native Apple apps: Shortbread basemap tiles, terrarium terrain, hiking trails, places and road curvature per region. Online-first, offline optional, zero hosting cost: code in this repo, data as GitHub Release assets, compute in GitHub Actions. One map provider, [VersaTiles](https://versatiles.org), for everything online and offline.

**Status:** Phase 1 in progress. The pipeline builds the basemap, terrain and bundled base packs; data layers, the release workflow and the Swift package follow. See `docs/BRIEF.md` for the plan and `docs/decisions.md` for every decision and the numbers behind it.

## Build a region locally

```sh
pipeline/bootstrap.sh            # installs versatiles, pmtiles, osmium-tool, tippecanoe (macOS or Ubuntu)
cd pipeline && uv sync
uv run maqs check-tools
uv run maqs build --region test  # ~20 s, outputs in dist/test/, report in dist/test/build-report.json
uv run maqs build --region veneto
uv run maqs regions
```

Outputs are PMTiles archives (`docs/data-format.md`). Adding a region anywhere in the world is one entry in `config/regions.yaml`.

## Develop

```sh
cd pipeline
uv run pytest -q                 # unit tests, no network
uv run pytest --run-network -q   # plus the live test-region build
uv run ruff check . && uv run ruff format .
```

## Licences

Code: Apache-2.0 (`LICENSE`). Data: OpenStreetMap under ODbL plus the attributions in `DATA_LICENSE.md`.
```

```markdown
# Data licence and attribution

The data maqs publishes is derived from the sources below. Anyone redistributing or displaying it must carry these notices; the Swift package's attribution view shows the ones for the active sources.

## OpenStreetMap (basemap, trails, places, curvature)

Map data © OpenStreetMap contributors, available under the [Open Database License (ODbL) 1.0](https://www.openstreetmap.org/copyright). Derived databases maqs publishes (the SQLite layers) are ODbL as well.

Required display text: **© OpenStreetMap contributors** linking to https://www.openstreetmap.org/copyright.

## ESA WorldCover 2021 (landcover in the basemap)

The basemap tiles merge ESA WorldCover 2021 land cover, © ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by the ESA WorldCover consortium, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), via https://esa-worldcover.org/en/data-access.

Required display text: **CC BY 4.0 ESA WorldCover 2021** (as the VersaTiles TileJSON attribution states).

## Mapterhorn (terrain)

Terrain tiles are the [Mapterhorn](https://mapterhorn.com) build served by VersaTiles. Required display text: **© Mapterhorn** linking to https://mapterhorn.com/attribution. Mapterhorn aggregates national open elevation models; the ones intersecting the launch regions (from https://download.mapterhorn.com/attribution.json, 2026-10-07):

- TINITALY 1.1, Istituto Nazionale di Geofisica e Vulcanologia (INGV), CC BY 4.0
- LiDAR PAT 2014/2018, Provincia Autonoma di Trento, CC BY 2.5
- Digitales Geländemodell 2,5 m, Autonome Provinz Bozen, CC0
- DMR, Slovenian Environment Agency (ARSO), CC BY 4.0
- ALS-DGM, BEV (Austria), CC BY 4.0, and the Austrian state models (Kärnten, Salzburg, Tirol where present), CC BY 4.0
- Copernicus GLO-30, European Union and ESA, Copernicus full, free and open licence

## VersaTiles

Tiles are produced and hosted by [VersaTiles](https://versatiles.org) (schema Shortbread, CC0). VersaTiles asks for no attribution of its own; the upstream credits above apply.
```

- [ ] **Step 4: Append ADR 0009 to `docs/decisions.md`**

```markdown

---

## 0009 — Regions as the smallest pack unit, the `triveneto` region, and the test-region fixtures

**Date:** 2026-10-08 · **Status:** accepted

**Context.** The owner needs Veneto, Trentino-Alto Adige and Friuli-Venezia Giulia together and will not use anything smaller than a region. Tile extracts are bbox-based, so the three regional bboxes overlap heavily (Veneto's already contains most of the other two): three separate packs cost ~1 GB where one costs ~720 MB. Swift tests need realistic fixtures, but nothing generated may be committed.

**Decisions.**
1. A region is the smallest unit a pack is cut at; no sub-region packs. `test` is `fixture: true`: built for CI and tests, never listed to apps, never released, never in a base pack.
2. `triveneto` is a first-class region with the union bbox (10.3818,44.7923,13.9187,47.0921). Measured 2026-10-08: basemap 431 MB (z0–14, gzip, border 1, 48 s), terrain 291 MB (z0–12, 21 s). The single regions stay for users who want less.
3. The `test` bbox is `<final bbox from Task 10>` (~`<km²>` km² around Nevegal); basemap + terrain measure `<bytes>` bytes, under the 5 MB warning line.
4. Fixtures are not committed. The `pipeline` workflow builds the test region on every relevant push and uploads `dist/test` as the `test-region-fixtures` artifact; the Swift workflow (Phase 4) downloads it. Only tiny hand-made corrupt-input files live in git.
5. Regions can be anywhere in the world: each names its Geofabrik extract and optional admin-relation clip; base packs are named lists of regions, not "everything".

**Consequences.** `config/regions.yaml` carries five entries; adding a region elsewhere is one more. The release workflow (Phase 3) skips fixture regions.
```

Fill the three `<…>` placeholders from Task 10's measurements before committing.

- [ ] **Step 5: Update CLAUDE.md commands**

In `CLAUDE.md` §1 *Commands*, replace the line `Everything below is the contract from the brief. Until the matching phase lands, the command does not exist; do not fake it.` with `The pipeline commands are real as of Phase 1; the Swift commands land in Phase 4 and do not exist yet.` and add after the `uv run pytest` line: `uv run pytest --run-network                               # plus the live test-region build (CI runs it)`.

- [ ] **Step 6: Commit and push**

```bash
git add docs/data-format.md docs/architecture.md README.md DATA_LICENSE.md docs/decisions.md CLAUDE.md
git commit -m "docs: data formats, architecture, README, data licence and ADR 0009 for the pipeline skeleton"
git push origin main
```

---

## Self-review notes

- **Spec coverage:** layout and CLI (Tasks 1, 10); config incl. worldwide fields and base packs (2); steps and idempotency with validation of skipped outputs (6); tile steps with border, gzip, zooms (7); terrain-hd with dry-run skip and merge (8); validation rules and caps (5); report schema (9); test region tuning and no committed fixtures (10, 12); bootstrap with pins (11); tests incl. the network-marked integration test (10); docs and ADR 0009 (13). `cache.py` from the spec's layout is deliberately absent: plan 1 downloads nothing (both archives are read remotely); plan 2 adds it with the Geofabrik download, its first real user.
- **Types:** `Expectation`, `OutputInfo`, `StepResult`, `BuildContext`, `ToolStatus` names and fields are identical across Tasks 5–10. `tools.run` returns `CompletedProcess` with `.stdout`/`.stderr`; the terrain-hd tests stub it with an object exposing both.
- **Review Focus coverage:** (1) Task 6 `test_skipped_output_is_still_validated`; (2) Task 8 empty-archive tests; (3) Task 2 bbox tests; (4) Task 3 and Task 10 `test_build_stops_on_tool_mismatch`; (5) Task 10 unknown-region and base-pack-id tests.
