import dataclasses
import hashlib
import json
import subprocess
from pathlib import Path

import pytest

from maqs import tools
from maqs.cache import FetchError
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.osm import extract

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"
NORD_EST = "europe-italy-nord-est"


@pytest.fixture
def cfg():
    return load_config(REAL)


def make_ctx(cfg, tmp_path, region_id):
    return BuildContext(
        config=cfg,
        dist=tmp_path / "dist",
        cache=tmp_path / ".cache",
        force=False,
        region=cfg.region(region_id),
    )


@pytest.fixture
def veneto(cfg, tmp_path):
    return make_ctx(cfg, tmp_path, "veneto")


@pytest.fixture
def test_region(cfg, tmp_path):
    return make_ctx(cfg, tmp_path, "test")


@pytest.fixture
def osmium_bin(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/usr/bin/{name}"))


@pytest.fixture
def no_download(monkeypatch):
    def refuse(*args, **kwargs):
        raise AssertionError("no download expected")

    monkeypatch.setattr(extract, "download", refuse)


def seed_geofabrik(ctx, kind="latest"):
    path = ctx.cache / "geofabrik" / f"{NORD_EST}-{kind}.osm.pbf"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"pbf")
    return path


def record_runs(monkeypatch):
    calls: list[list[str]] = []

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        calls.append(argv)
        for i, a in enumerate(argv):
            if a == "-o":  # every osmium command here writes its -o path
                Path(argv[i + 1]).parent.mkdir(parents=True, exist_ok=True)
                Path(argv[i + 1]).write_bytes(b"osm")
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    return calls


def test_extract_name():
    assert extract.extract_name("europe/italy/nord-est") == NORD_EST


def test_require_region_returns_region_or_raises(cfg, tmp_path):
    ctx = make_ctx(cfg, tmp_path, "veneto")
    assert ctx.require_region().id == "veneto"
    base = dataclasses.replace(ctx, region=None)
    with pytest.raises(ValueError, match="needs a region"):
        base.require_region()


def test_region_extract_id_requires_osm(cfg, tmp_path):
    ctx = make_ctx(cfg, tmp_path, "veneto")
    assert extract.region_extract_id(ctx) == "europe/italy/nord-est"
    no_osm = dataclasses.replace(cfg.region("veneto"), osm=None)
    ctx2 = dataclasses.replace(ctx, region=no_osm)
    with pytest.raises(FetchError, match="no osm.geofabrik"):
        extract.region_extract_id(ctx2)


def test_geofabrik_pbf_downloads_once_with_md5_check(veneto, monkeypatch):
    payload = b"pbf-bytes"
    digest = hashlib.md5(payload).hexdigest()
    fetched: list[str] = []

    def fake_download(url, dest, **kw):
        fetched.append(url)
        dest.parent.mkdir(parents=True, exist_ok=True)
        sidecar = f"{digest}  nord-est-latest.osm.pbf\n".encode()
        dest.write_bytes(sidecar if url.endswith(".md5") else payload)

    monkeypatch.setattr(extract, "download", fake_download)
    path = extract.geofabrik_pbf(veneto)
    assert path == veneto.cache / "geofabrik" / f"{NORD_EST}-latest.osm.pbf"
    assert path.read_bytes() == payload
    assert fetched == [
        "https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf.md5",
        "https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf",
    ]
    extract.geofabrik_pbf(veneto)
    veneto.force = True
    extract.geofabrik_pbf(veneto)
    assert len(fetched) == 2  # reused, even with --force


def test_fetch_extract_downloads_once_and_reuses(tmp_path, monkeypatch):
    payload = b"pbf-bytes"
    digest = hashlib.md5(payload).hexdigest()
    fetched: list[str] = []

    def fake_download(url, dest, **kw):
        fetched.append(url)
        dest.parent.mkdir(parents=True, exist_ok=True)
        sidecar = f"{digest}  nord-est-latest.osm.pbf\n".encode()
        dest.write_bytes(sidecar if url.endswith(".md5") else payload)

    monkeypatch.setattr(extract, "download", fake_download)
    cache = tmp_path / "cache"
    path = extract.fetch_extract(cache, "europe/italy/nord-est")
    assert path == cache / "geofabrik" / f"{NORD_EST}-latest.osm.pbf"
    assert path.read_bytes() == payload and len(fetched) == 2  # sidecar + file
    assert extract.fetch_extract(cache, "europe/italy/nord-est") == path
    assert len(fetched) == 2  # reused, not downloaded again


def test_geofabrik_pbf_rejects_md5_mismatch_and_caches_nothing(veneto, monkeypatch):
    def fake_download(url, dest, **kw):
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"0" * 32 + b"  x\n" if url.endswith(".md5") else b"corrupt")

    monkeypatch.setattr(extract, "download", fake_download)
    with pytest.raises(FetchError, match="md5 mismatch"):
        extract.geofabrik_pbf(veneto)
    assert not [p for p in (veneto.cache / "geofabrik").iterdir()]


def test_hiking_pbf_runs_tags_filter_once(veneto, osmium_bin, no_download, monkeypatch):
    calls = record_runs(monkeypatch)
    src = seed_geofabrik(veneto)
    out = extract.hiking_pbf(veneto)
    assert out == src.with_name(f"{NORD_EST}-hiking.osm.pbf")
    tmp = src.with_name(f"{NORD_EST}-hiking.tmp.osm.pbf")
    expected = ["/usr/bin/osmium", "tags-filter", str(src), "r/route=hiking"]
    assert calls == [[*expected, "-o", str(tmp), "--overwrite"]]
    assert out.exists() and not tmp.exists()
    extract.hiking_pbf(veneto)
    assert len(calls) == 1


def test_write_poly_from_geojson_features(tmp_path):
    triangle = [[12.2, 46.0], [12.3, 46.0], [12.3, 46.1], [12.2, 46.0]]
    hole = [[12.21, 46.01], [12.22, 46.01], [12.22, 46.02], [12.21, 46.01]]
    other = [[13.0, 46.0], [13.1, 46.0], [13.1, 46.1], [13.0, 46.0]]
    features = [
        {
            "type": "Feature",
            "geometry": {"type": "MultiPolygon", "coordinates": [[triangle, hole]]},
            "properties": {},
        },
        {
            "type": "Feature",
            "geometry": {"type": "Polygon", "coordinates": [other]},
            "properties": {},
        },
    ]
    path = tmp_path / "clip.poly"
    assert extract.write_poly(features, path, "veneto") == 3
    text = path.read_text()
    assert text.startswith("veneto\n")
    assert text.count("END\n") == 4  # three sections + the file terminator
    assert "!" in text.split("END")[1]  # second section is the inner ring
    assert "   12.2 46.0\n" in text and "   13.1 46.1\n" in text


def test_write_poly_rejects_non_polygons(tmp_path):
    point = {"type": "Feature", "geometry": {"type": "Point", "coordinates": [1, 2]}}
    with pytest.raises(FetchError, match="no polygon rings"):
        extract.write_poly([point], tmp_path / "x.poly", "x")


def test_clip_poly_runs_getid_and_export(veneto, osmium_bin, no_download, monkeypatch):
    calls: list[list[str]] = []
    ring = [[12.2, 46.0], [12.3, 46.0], [12.3, 46.1], [12.2, 46.0]]
    feature = {
        "type": "Feature",
        "geometry": {"type": "Polygon", "coordinates": [ring]},
        "properties": {},
    }

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        calls.append(argv)
        out = Path(argv[argv.index("-o") + 1])
        out.parent.mkdir(parents=True, exist_ok=True)
        if argv[1] == "export":
            out.write_text("\x1e" + json.dumps(feature) + "\n")
        else:
            out.write_bytes(b"pbf")

    monkeypatch.setattr(tools, "run", fake_run)
    seed_geofabrik(veneto)
    poly = extract.clip_poly(veneto)
    admin_pbf = veneto.cache / "veneto" / "admin.osm.pbf"
    assert poly == veneto.cache / "veneto" / "clip.poly"
    assert poly.read_text().startswith("veneto\n")
    assert calls[0][:3] == ["/usr/bin/osmium", "getid", "-r"] and "r43648" in calls[0]
    assert calls[1][1:4] == ["export", str(admin_pbf), "-f"] and "geojsonseq" in calls[1]
    assert not admin_pbf.exists()  # intermediates removed


def test_clip_poly_is_none_without_clip(test_region, osmium_bin, monkeypatch):
    record_runs(monkeypatch)
    assert extract.clip_poly(test_region) is None


def test_region_pbf_uses_polygon_or_bbox(veneto, test_region, osmium_bin, no_download, monkeypatch):
    calls = record_runs(monkeypatch)
    for ctx in (veneto, test_region):
        seed_geofabrik(ctx)
    (veneto.cache / "veneto" / "clip.poly").parent.mkdir(parents=True)
    (veneto.cache / "veneto" / "clip.poly").write_text("veneto\nEND\n")
    out = extract.region_pbf(veneto)
    assert out == veneto.cache / "veneto" / "region.osm.pbf"
    src = veneto.cache / "geofabrik" / f"{NORD_EST}-latest.osm.pbf"
    poly = veneto.cache / "veneto" / "clip.poly"
    tmp = veneto.cache / "veneto" / "region.tmp.osm.pbf"
    assert calls[-1] == [
        *["/usr/bin/osmium", "extract", "--polygon", str(poly), "-s", "complete_ways"],
        *[str(src), "-o", str(tmp), "--overwrite"],
    ]
    assert out.exists() and not tmp.exists()
    out2 = extract.region_pbf(test_region)
    assert calls[-1][2:4] == ["--bbox", "12.21,46.08,12.29,46.13"] and out2.name == "region.osm.pbf"


def test_region_hiking_pbf_uses_smart_strategy(cfg, tmp_path, osmium_bin, no_download, monkeypatch):
    calls = record_runs(monkeypatch)
    bbox_only = dataclasses.replace(cfg.region("veneto"), clip=None)
    ctx = dataclasses.replace(make_ctx(cfg, tmp_path, "veneto"), region=bbox_only)
    seed_geofabrik(ctx)
    out = extract.region_hiking_pbf(ctx)
    assert out == ctx.cache / "veneto" / "hiking.osm.pbf"
    assert [c[1] for c in calls] == ["tags-filter", "extract"]
    assert calls[-1][4:8] == ["-s", "smart", "-S", "types=route"]
    assert calls[-1][2] == "--bbox"
    extract.region_hiking_pbf(ctx)
    assert len(calls) == 2  # everything reused
    ctx.force = True
    extract.region_hiking_pbf(ctx)
    assert [c[1] for c in calls[2:]] == ["tags-filter", "extract"]


def test_filtered_region_pbf_filters_the_region_cut_once(
    test_region, osmium_bin, no_download, monkeypatch
):
    calls = record_runs(monkeypatch)
    seed_geofabrik(test_region)
    roads = ["w/highway=primary,secondary"]
    out = extract.filtered_region_pbf(test_region, "roads", roads)
    region = test_region.cache / "test" / "region.osm.pbf"
    assert out == test_region.cache / "test" / "roads.osm.pbf"
    assert [c[1] for c in calls] == ["extract", "tags-filter"]
    assert calls[-1] == [
        *["/usr/bin/osmium", "tags-filter", str(region), *roads],
        *["-o", str(test_region.cache / "test" / "roads.tmp.osm.pbf"), "--overwrite"],
    ]
    assert extract.filtered_region_pbf(test_region, "roads", roads) == out
    assert len(calls) == 2  # reused
    test_region.force = True
    extract.filtered_region_pbf(test_region, "roads", roads)
    assert [c[1] for c in calls[2:]] == ["extract", "tags-filter"]


def fail_after_writing(monkeypatch):
    """An osmium run that writes part of its -o file and then exits non-zero."""

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        Path(argv[argv.index("-o") + 1]).write_bytes(b"trunc")
        raise tools.ToolError(argv, 1, "interrupted")

    monkeypatch.setattr(tools, "run", fake_run)


def test_failed_cuts_leave_neither_the_output_nor_a_partial_file(
    test_region, osmium_bin, no_download, monkeypatch
):
    seed_geofabrik(test_region)
    fail_after_writing(monkeypatch)
    region_dir = test_region.cache / "test"
    with pytest.raises(tools.ToolError):
        extract.region_pbf(test_region)
    assert list(region_dir.iterdir()) == []
    region_dir.joinpath("region.osm.pbf").write_bytes(b"osm")
    with pytest.raises(tools.ToolError):
        extract.filtered_region_pbf(test_region, "roads", ["w/highway=primary"])
    assert sorted(p.name for p in region_dir.iterdir()) == ["region.osm.pbf"]


def test_failed_tags_filter_leaves_no_file_and_a_retry_runs_again(
    veneto, osmium_bin, no_download, monkeypatch
):
    src = seed_geofabrik(veneto)
    fail_after_writing(monkeypatch)
    with pytest.raises(tools.ToolError):
        extract.hiking_pbf(veneto)
    assert [p.name for p in src.parent.iterdir()] == [src.name]
    calls = record_runs(monkeypatch)
    out = extract.hiking_pbf(veneto)
    assert len(calls) == 1 and out.read_bytes() == b"osm"
    assert sorted(p.name for p in src.parent.iterdir()) == sorted([src.name, out.name])


def test_successful_cut_leaves_only_the_final_file(
    test_region, osmium_bin, no_download, monkeypatch
):
    record_runs(monkeypatch)
    seed_geofabrik(test_region)
    out = extract.region_pbf(test_region)
    assert [p.name for p in out.parent.iterdir()] == ["region.osm.pbf"]
    assert out.read_bytes() == b"osm"


def test_osm_timestamp(osmium_bin, monkeypatch):
    def reply(stdout):
        return lambda argv, **kw: subprocess.CompletedProcess(argv, 0, stdout, "")

    monkeypatch.setattr(tools, "run", reply("2026-10-06T20:21:06Z\n"))
    assert extract.osm_timestamp(Path("/x.pbf")) == "2026-10-06T20:21:06Z"
    monkeypatch.setattr(tools, "run", reply("\n"))
    assert extract.osm_timestamp(Path("/x.pbf")) is None
