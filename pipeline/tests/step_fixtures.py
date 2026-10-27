"""Shared stand-ins for the data-step tests: the build context, the osmium tags-filter cut and
the tippecanoe run. None of them touches a real binary or the network."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.osm import extract
from tests.helpers import write_pmtiles

REGIONS_YAML = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


def region_ctx(tmp_path: Path, region_id: str = "test") -> BuildContext:
    """A build context for one region of the real regions.yaml, writing under tmp_path."""
    cfg = load_config(REGIONS_YAML)
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region(region_id),
    )


def stub_tags_filter(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Replace `osmium tags-filter` with a copy of its input; records the expressions."""
    seen: dict[str, Any] = {}

    def fake_tags_filter(src: Path, dst: Path, expressions: list[str]) -> list[str]:
        seen["expressions"] = list(expressions)
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        return ["osmium", "tags-filter"]

    monkeypatch.setattr(extract, "tags_filter", fake_tags_filter)
    return seen


def stub_tippecanoe(
    monkeypatch: pytest.MonkeyPatch, min_zoom: int, max_zoom: int
) -> dict[str, Any]:
    """Replace the tippecanoe run with a tiny MVT archive at `-o`; records argv and features."""
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/usr/bin/{name}"))
    calls: dict[str, Any] = {}

    def fake_run(argv: list[Any], **kw: Any) -> subprocess.CompletedProcess[str]:
        argv = [str(a) for a in argv]
        calls["argv"] = argv
        calls["cwd"] = kw.get("cwd")
        folder = kw.get("cwd") or Path()
        lines = (folder / argv[-1]).read_text().splitlines()
        calls["features"] = [json.loads(line) for line in lines if line.strip()]
        out = folder / argv[argv.index("-o") + 1]
        write_pmtiles(out, tile_type=1, min_zoom=min_zoom, max_zoom=max_zoom)
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(tools, "run", fake_run)
    return calls
