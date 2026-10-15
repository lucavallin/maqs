# Data Layers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the trails, places and curvature layers to the pipeline: per-region SQLite indexes (FTS5 + R*Tree), trail and place overlay tiles, built from the Geofabrik extract each region names, validated, counted and reported like the tile layers, with the `test` region still under 5 minutes.

**Architecture:** Plan 1's step runner gains data steps. `osm/extract.py` fetches the Geofabrik file once per run and cuts it per region with `osmium` (polygon or bbox; the `smart` strategy keeps hiking relations complete across borders). pyosmium reads the cut files; our own code assembles relation geometry, ranks places and scores curvature; `sqlite_out.py` writes the three schemas; tippecanoe writes the two overlays; validation reads SQLite files read-only and checks row-count ranges from `regions.yaml`.

**Tech Stack:** Python 3.12, `uv`, pyosmium 4.3.1 (new runtime dependency, BSD-2), Pillow 12.3 (new, MIT-CMU; WebP decode), stdlib `sqlite3`, `urllib`; CLIs `osmium` 1.19.1 and `tippecanoe` 2.79.0 (already pinned), `versatiles` 5.0.0; GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-15-data-layers-design.md`

## Global Constraints

- Geometry encoding everywhere: Google encoded polyline, **precision 6**, TEXT; legs joined by `|`. Points are `lon`/`lat` REAL columns.
- Sources: `https://download.geofabrik.de/<extract>-latest.osm.pbf` plus `.md5` sidecar, downloaded once per distinct extract per run with an identifying User-Agent, verified against the md5, reused when present (`--force` never re-downloads).
- Cuts: hiking relations via `osmium tags-filter <extract> r/route=hiking`, then `osmium extract --polygon <clip.poly> -s smart -S types=route`; places and roads from `osmium extract --polygon <clip.poly> -s complete_ways`; regions without `clip` use `--bbox lon_min,lat_min,lon_max,lat_max`. `.poly` files are Osmosis format, one section per outer ring, `!`-prefixed sections for inner rings.
- Every CLI call goes through `maqs.tools.run`; no `shell=True`; unit tests never touch the network, the real extract, or the real binaries (pyosmium and tippecanoe calls are stubbed or run on generated fixtures only; pyosmium itself runs in tests on fixtures written with `osmium.SimpleWriter`, nodes before ways before relations).
- SQLite: one `metadata` row (`schema_version`, `layer`, `region`, `data_date`, `osm_timestamp`, `attribution`); FTS5 `tokenize='unicode61 remove_diacritics 2'` as external-content tables; R*Tree in lon/lat degrees; written to a temp file, `VACUUM`ed, renamed into place. Attribution string: `© OpenStreetMap contributors (ODbL)`.
- Formulas, exact values: resample every **25 m**, ascent/descent hysteresis **5 m**; `rank_score = 1000 × [wikidata present] + ele` (ele 0 when null); curvature vertex merge under **5 m**, corner cutoff radius **500 m**, band weights 4 (< 30 m), 3 (30–60), 2 (60–100), 1 (100–175), 0 (≥ 175); difficulty 1–6 per the spec table.
- Overlays: tippecanoe `-o <file>.pmtiles -f -l <layer> -Z<min> -z<max>`, gzip default; trails layer `trails` z6–14; places layer `places` z8–14. Validation expects MVT, those zooms, gzip.
- Report stays `report_version` 1: outputs gain `rows` (SQLite only), steps gain `anomalies` (≤ 1,000 entries) and `anomaly_count`. Data anomalies never fail a build; size, schema, checksum and `expect` violations do.
- `regions.yaml` `schema_version` stays 1; new keys are optional: top-level `curvature.highways` / `curvature.exclude_surfaces`, per region `trails.sources` (default `[osm]`, only `osm` known) and `expect` (`trails`, `places`, `curvature_segments`: `[min, max]`).
- Default `--layers` becomes `basemap,terrain,trails,places,curvature`; `terrain-hd` stays opt-in. Within a region the step order is fixed: tiles, trails, places, curvature.
- Refinement of the spec (recorded here, reason in ADR 0011): curvature keeps two-node ways with score 0 and no corners instead of skipping them, because the corner lookahead needs adjacency along straight connectors; only ways with fewer than two valid locations are skipped.
- Ruff (line-length 100; select E,F,I,B,UP,SIM,PTH) clean, no suppressions; type hints; pathlib. Conventional commits, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, direct to `main`, never force-push. Nothing generated committed.

## Review Focus

1. **A relation whose member way is missing from the extract** (members outside nord-est, 5 % of relations). Expected: the row exists with `geometry_status = incomplete`, the legs it has, and an anomaly naming the missing way. Test in Task 6.
2. **A road way with two nodes exactly on a straight line, and one with three collinear nodes.** Expected: score 0, no corners, no division by zero, the segment still written (adjacency). Test in Task 9.
3. **A trail that leaves the terrain archive's coverage** (a leg outside the region's terrain bbox, e.g. a border-crossing relation). Expected: ascent/descent computed from the samples that have a tile, an anomaly recording how many samples had none, never a crash. Test in Task 4.
4. **A region with `expect` ranges and a build that lands outside them** (for example an extract that lost a province). Expected: the step fails validation with the count and the range in the message; the SQLite file is still written for inspection. Test in Task 5.
5. **A Geofabrik download whose md5 does not match** (truncated or replaced mid-run). Expected: the partial file is removed, the step fails with "md5 mismatch", nothing cached. Test in Task 3.

---

### Task 1: Dependencies and `geometry.py`

**Files:**
- Modify: `pipeline/pyproject.toml` (add `osmium>=4.3`, `pillow>=12.0` to `dependencies`), `pipeline/uv.lock` (via `uv lock`)
- Create: `pipeline/src/maqs/geometry.py`, `pipeline/tests/test_geometry.py`

**Interfaces:**
- Produces:
  - `Coord = tuple[float, float]` (lon, lat)
  - `encode_polyline(coords: Sequence[Coord], precision: int = 6) -> str`, `decode_polyline(text: str, precision: int = 6) -> list[Coord]`
  - `haversine_m(a: Coord, b: Coord) -> float`, `line_length_m(coords: Sequence[Coord]) -> float`, `cumulative_m(coords) -> list[float]`
  - `bbox_of(coords: Iterable[Coord]) -> tuple[float, float, float, float]` (lon_min, lat_min, lon_max, lat_max)
  - `resample(coords: Sequence[Coord], step_m: float) -> list[Coord]` (endpoints always included)
  - `circumradius(p: Coord, q: Coord, r: Coord) -> tuple[float, int]` (radius in metres, `math.inf` when collinear; sign `+1` left turn, `-1` right, `0` collinear)
  - `merge_close(coords: Sequence[Coord], min_m: float) -> list[Coord]`

- [ ] **Step 1: Add the dependencies**

Edit `pipeline/pyproject.toml`: `dependencies = ["click>=8.1", "pyyaml>=6.0", "osmium>=4.3", "pillow>=12.0"]`. Run from `pipeline/`: `uv lock && uv sync`. Expected: `uv.lock` changes; `uv run python -c "import osmium, PIL; print(PIL.__version__)"` prints `12.3.0` (or newer).

- [ ] **Step 2: Write the failing tests**

```python
# pipeline/tests/test_geometry.py
import math

import pytest

from maqs.geometry import (
    bbox_of,
    circumradius,
    cumulative_m,
    decode_polyline,
    encode_polyline,
    haversine_m,
    line_length_m,
    merge_close,
    resample,
)

# Google's published precision-5 example (lat/lon pairs in their doc; we store lon/lat).
GOOGLE_POINTS = [(-120.2, 38.5), (-120.95, 40.7), (-126.453, 43.252)]
GOOGLE_ENCODED = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"


def test_polyline_matches_the_reference_vector_at_precision_5():
    assert encode_polyline(GOOGLE_POINTS, precision=5) == GOOGLE_ENCODED
    assert decode_polyline(GOOGLE_ENCODED, precision=5) == pytest.approx(GOOGLE_POINTS)


def test_polyline_precision_6_round_trips_to_a_tenth_of_a_metre():
    pts = [(12.2534567, 46.1012345), (12.2601234, 46.1109876), (-73.9857, 40.7484)]
    out = decode_polyline(encode_polyline(pts))
    for (lon, lat), (olon, olat) in zip(pts, out, strict=True):
        assert abs(lon - olon) < 1e-6 and abs(lat - olat) < 1e-6


def test_empty_polyline():
    assert encode_polyline([]) == "" and decode_polyline("") == []


def test_haversine_and_length():
    a, b = (12.25, 46.10), (12.26, 46.10)
    assert haversine_m(a, b) == pytest.approx(771.8, abs=1.0)  # 0.01° lon at 46.1° N
    assert line_length_m([a, b, a]) == pytest.approx(2 * haversine_m(a, b))
    assert cumulative_m([a, b]) == pytest.approx([0.0, haversine_m(a, b)])
    assert line_length_m([a]) == 0.0


def test_bbox_of():
    assert bbox_of([(12.3, 46.2), (12.1, 46.4), (12.2, 46.1)]) == (12.1, 46.1, 12.3, 46.4)


def test_resample_keeps_endpoints_and_spacing():
    a, b = (12.25, 46.10), (12.26, 46.10)  # ~772 m
    pts = resample([a, b], 100.0)
    assert pts[0] == a and pts[-1] == b
    assert len(pts) == 9  # 0,100,...,700 and the endpoint
    gaps = [haversine_m(p, q) for p, q in zip(pts, pts[1:], strict=True)]
    assert all(abs(g - 100.0) < 1.0 for g in gaps[:-1]) and gaps[-1] < 100.0
    assert resample([a], 100.0) == [a]


def test_circumradius_on_a_known_circle():
    # three points on a circle of radius 50 m around (12.25, 46.10), counter-clockwise (left turn)
    cx, cy = 12.25, 46.10
    m_per_deg_lon = 111_320 * math.cos(math.radians(cy))
    m_per_deg_lat = 110_574

    def on_circle(angle_deg):
        return (cx + 50 * math.cos(math.radians(angle_deg)) / m_per_deg_lon,
                cy + 50 * math.sin(math.radians(angle_deg)) / m_per_deg_lat)

    r, sign = circumradius(on_circle(200), on_circle(270), on_circle(340))
    assert r == pytest.approx(50.0, rel=0.02) and sign == 1
    r2, sign2 = circumradius(on_circle(340), on_circle(270), on_circle(200))
    assert r2 == pytest.approx(50.0, rel=0.02) and sign2 == -1


def test_circumradius_collinear_is_infinite():
    r, sign = circumradius((12.25, 46.10), (12.26, 46.10), (12.27, 46.10))
    assert r == math.inf and sign == 0


def test_merge_close_drops_vertices_under_the_threshold():
    a = (12.25, 46.10)
    near = (12.25001, 46.10)  # ~0.8 m
    far = (12.26, 46.10)
    assert merge_close([a, near, far], 5.0) == [a, far]
    assert merge_close([a, near], 5.0) == [a, near]  # the last vertex is always kept
    assert merge_close([a], 5.0) == [a]
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `uv run pytest tests/test_geometry.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.geometry'`

- [ ] **Step 4: Implement `geometry.py`**

```python
# pipeline/src/maqs/geometry.py
"""Coordinate maths shared by every data layer: polyline6, distances, resampling, circles.

Coordinates are (lon, lat) in WGS 84 degrees everywhere. Distances are metres.
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence

Coord = tuple[float, float]

EARTH_RADIUS_M = 6_371_008.8
M_PER_DEG_LAT = 110_574.0
M_PER_DEG_LON_EQUATOR = 111_320.0


def _encode_value(value: int) -> str:
    value = ~(value << 1) if value < 0 else value << 1
    out = []
    while value >= 0x20:
        out.append(chr((0x20 | (value & 0x1F)) + 63))
        value >>= 5
    out.append(chr(value + 63))
    return "".join(out)


def encode_polyline(coords: Sequence[Coord], precision: int = 6) -> str:
    factor = 10**precision
    out: list[str] = []
    last_lat = last_lon = 0
    for lon, lat in coords:
        ilat, ilon = round(lat * factor), round(lon * factor)
        out.append(_encode_value(ilat - last_lat))
        out.append(_encode_value(ilon - last_lon))
        last_lat, last_lon = ilat, ilon
    return "".join(out)


def decode_polyline(text: str, precision: int = 6) -> list[Coord]:
    factor = 10**precision
    coords: list[Coord] = []
    index = lat = lon = 0
    while index < len(text):
        values = []
        for _ in range(2):
            result = shift = 0
            while True:
                if index >= len(text):
                    raise ValueError("truncated polyline")
                byte = ord(text[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            values.append(~(result >> 1) if result & 1 else result >> 1)
        lat += values[0]
        lon += values[1]
        coords.append((lon / factor, lat / factor))
    return coords


def haversine_m(a: Coord, b: Coord) -> float:
    lon1, lat1 = map(math.radians, a)
    lon2, lat2 = map(math.radians, b)
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(h))


def cumulative_m(coords: Sequence[Coord]) -> list[float]:
    out = [0.0]
    for p, q in zip(coords, coords[1:], strict=False):
        out.append(out[-1] + haversine_m(p, q))
    return out


def line_length_m(coords: Sequence[Coord]) -> float:
    return cumulative_m(coords)[-1] if coords else 0.0


def bbox_of(coords: Iterable[Coord]) -> tuple[float, float, float, float]:
    lons, lats = zip(*coords, strict=True)
    return (min(lons), min(lats), max(lons), max(lats))


def resample(coords: Sequence[Coord], step_m: float) -> list[Coord]:
    """Points every step_m along the line, plus the exact endpoints."""
    if len(coords) < 2:
        return list(coords)
    out: list[Coord] = [coords[0]]
    carry = 0.0  # distance already covered since the last emitted point
    for p, q in zip(coords, coords[1:], strict=False):
        seg = haversine_m(p, q)
        if seg == 0.0:
            continue
        pos = step_m - carry
        while pos < seg:
            t = pos / seg
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
            pos += step_m
        carry = seg - (pos - step_m)
    if out[-1] != coords[-1]:
        out.append(coords[-1])
    return out


def _local_xy(origin: Coord, p: Coord) -> tuple[float, float]:
    m_per_deg_lon = M_PER_DEG_LON_EQUATOR * math.cos(math.radians(origin[1]))
    return ((p[0] - origin[0]) * m_per_deg_lon, (p[1] - origin[1]) * M_PER_DEG_LAT)


def circumradius(p: Coord, q: Coord, r: Coord) -> tuple[float, int]:
    """Radius of the circle through p, q, r (metres) and the turn sign at q (+1 left, -1 right)."""
    ax, ay = _local_xy(q, p)
    cx, cy = _local_xy(q, r)
    cross = ax * cy - ay * cx  # twice the signed triangle area (q at the origin)
    if abs(cross) < 1e-9:
        return math.inf, 0
    a = math.hypot(ax, ay)
    b = math.hypot(cx, cy)
    c = math.hypot(cx - ax, cy - ay)
    # sign: travelling p -> q -> r, a left turn has r to the left of the p->q direction
    direction = (-ax) * (cy) - (-ay) * (cx)
    return (a * b * c) / (2 * abs(cross)), 1 if direction > 0 else -1


def merge_close(coords: Sequence[Coord], min_m: float) -> list[Coord]:
    """Drop vertices closer than min_m to the last kept one; the last vertex is always kept."""
    if len(coords) <= 2:
        return list(coords)
    out = [coords[0]]
    for p in coords[1:-1]:
        if haversine_m(out[-1], p) >= min_m:
            out.append(p)
    out.append(coords[-1])
    return out
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_geometry.py -q`
Expected: all pass. If `test_circumradius_on_a_known_circle` fails on the sign, the `direction` formula is inverted: flip the comparison, never the test.

- [ ] **Step 6: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/pyproject.toml pipeline/uv.lock pipeline/src/maqs/geometry.py pipeline/tests/test_geometry.py
git commit -m "feat(pipeline): polyline6, distances and circle maths; add pyosmium and Pillow"
```

---

### Task 2: Configuration additions

**Files:**
- Modify: `pipeline/src/maqs/config.py`, `config/regions.yaml`, `pipeline/tests/test_config.py`

**Interfaces:**
- Produces:
  - `DEFAULT_HIGHWAYS: tuple[str, ...]`, `DEFAULT_EXCLUDE_SURFACES: tuple[str, ...]` (the spec's lists)
  - `@dataclass(frozen=True) CurvatureConfig(highways: tuple[str, ...], exclude_surfaces: tuple[str, ...])`
  - `@dataclass(frozen=True) RowRange(min: int, max: int)`
  - `Region` gains `trail_sources: tuple[str, ...]` (default `("osm",)`) and `expect: dict[str, RowRange]` (keys among `trails`, `places`, `curvature_segments`)
  - `Config` gains `curvature: CurvatureConfig`
  - `KNOWN_TRAIL_SOURCES = frozenset({"osm"})`, `EXPECT_KEYS = frozenset({"trails", "places", "curvature_segments"})`

- [ ] **Step 1: Write the failing tests** (append to `tests/test_config.py`)

```python
from maqs.config import DEFAULT_EXCLUDE_SURFACES, DEFAULT_HIGHWAYS, RowRange


def test_curvature_defaults_when_absent(tmp_path):
    cfg = load_config(write(tmp_path, MINIMAL))
    assert cfg.curvature.highways == DEFAULT_HIGHWAYS
    assert cfg.curvature.exclude_surfaces == DEFAULT_EXCLUDE_SURFACES
    assert "motorway" in DEFAULT_HIGHWAYS and "residential" not in DEFAULT_HIGHWAYS


def test_curvature_lists_from_config(tmp_path):
    text = MINIMAL + "curvature:\n  highways: [primary, secondary]\n  exclude_surfaces: [gravel]\n"
    cfg = load_config(write(tmp_path, text))
    assert cfg.curvature.highways == ("primary", "secondary")
    assert cfg.curvature.exclude_surfaces == ("gravel",)


def test_curvature_rejects_non_string_lists(tmp_path):
    with pytest.raises(ConfigError, match="curvature.highways must be a list of strings"):
        load_config(write(tmp_path, MINIMAL + "curvature:\n  highways: [1, 2]\n"))


def test_trail_sources_default_and_explicit(tmp_path):
    cfg = load_config(write(tmp_path, MINIMAL))
    assert cfg.region("a").trail_sources == ("osm",)
    text = MINIMAL.replace("bbox: [10.0, 45.0, 11.0, 46.0]", "bbox: [10.0, 45.0, 11.0, 46.0]\n    trails: { sources: [osm] }")
    assert load_config(write(tmp_path, text)).region("a").trail_sources == ("osm",)


def test_trail_sources_rejects_unknown_and_empty(tmp_path):
    bad = MINIMAL.replace("bbox: [10.0, 45.0, 11.0, 46.0]", "bbox: [10.0, 45.0, 11.0, 46.0]\n    trails: { sources: [avs] }")
    with pytest.raises(ConfigError, match="region 'a': unknown trail source 'avs'"):
        load_config(write(tmp_path, bad))
    empty = MINIMAL.replace("bbox: [10.0, 45.0, 11.0, 46.0]", "bbox: [10.0, 45.0, 11.0, 46.0]\n    trails: { sources: [] }")
    with pytest.raises(ConfigError, match="region 'a': trails.sources must list at least one source"):
        load_config(write(tmp_path, empty))


def test_expect_ranges(tmp_path):
    text = MINIMAL.replace(
        "bbox: [10.0, 45.0, 11.0, 46.0]",
        "bbox: [10.0, 45.0, 11.0, 46.0]\n    expect: { trails: [10, 20], curvature_segments: [1, 5] }",
    )
    r = load_config(write(tmp_path, text)).region("a")
    assert r.expect == {"trails": RowRange(10, 20), "curvature_segments": RowRange(1, 5)}
    assert load_config(write(tmp_path, MINIMAL)).region("a").expect == {}


@pytest.mark.parametrize(
    "expect, message",
    [
        ("{ lava: [1, 2] }", "unknown expect key 'lava'"),
        ("{ trails: [5] }", "expect.trails must be \\[min, max\\]"),
        ("{ trails: [5, 2] }", "expect.trails: min must be <= max"),
        ("{ trails: [-1, 2] }", "expect.trails: min must be >= 0"),
        ("{ trails: [true, 2] }", "expect.trails must be \\[min, max\\]"),
    ],
)
def test_expect_rejects_bad_shapes(tmp_path, expect, message):
    text = MINIMAL.replace("bbox: [10.0, 45.0, 11.0, 46.0]", f"bbox: [10.0, 45.0, 11.0, 46.0]\n    expect: {expect}")
    with pytest.raises(ConfigError, match=message):
        load_config(write(tmp_path, text))


def test_real_config_has_veneto_expectations():
    cfg = load_config(REAL)
    assert cfg.region("veneto").expect["trails"] == RowRange(1500, 3000)
    assert cfg.region("veneto").expect["places"] == RowRange(10000, 18000)
    assert cfg.region("test").expect == {}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_config.py -q`
Expected: FAIL with `ImportError: cannot import name 'DEFAULT_EXCLUDE_SURFACES'`.

- [ ] **Step 3: Implement**

Add to `config/regions.yaml` (top level, after `hd_max_zoom`):

```yaml
curvature:
  highways: [motorway, trunk, primary, secondary, tertiary, unclassified,
             motorway_link, trunk_link, primary_link, secondary_link, tertiary_link]
  exclude_surfaces: [gravel, dirt, ground, grass, sand, unpaved, compacted, fine_gravel,
                     mud, earth, wood, pebblestone]
```

and to the `veneto` region: `expect: { trails: [1500, 3000], places: [10000, 18000] }` (Phase 0: 1,955 relations, 13,408 place nodes). No `expect` on the other regions yet (Task 12 measures `test`; see the ledger ruling: `test` keeps no `expect`, the network test asserts its ranges; the others after their first build).

In `config.py`:

```python
DEFAULT_HIGHWAYS: tuple[str, ...] = (
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
    "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
)
DEFAULT_EXCLUDE_SURFACES: tuple[str, ...] = (
    "gravel", "dirt", "ground", "grass", "sand", "unpaved", "compacted", "fine_gravel",
    "mud", "earth", "wood", "pebblestone",
)
KNOWN_TRAIL_SOURCES = frozenset({"osm"})
EXPECT_KEYS = frozenset({"trails", "places", "curvature_segments"})


@dataclass(frozen=True)
class CurvatureConfig:
    highways: tuple[str, ...]
    exclude_surfaces: tuple[str, ...]


@dataclass(frozen=True)
class RowRange:
    min: int
    max: int
```

`Region` gains `trail_sources: tuple[str, ...]` and `expect: dict[str, RowRange]`; `Config` gains `curvature: CurvatureConfig`. Parsing helpers (private, in `config.py`):

```python
def _string_list(raw: object, where: str) -> tuple[str, ...]:
    if not isinstance(raw, list) or not all(isinstance(s, str) for s in raw):
        raise ConfigError(f"{where} must be a list of strings")
    return tuple(raw)


def _parse_curvature(raw: object) -> CurvatureConfig:
    if raw is None:
        return CurvatureConfig(DEFAULT_HIGHWAYS, DEFAULT_EXCLUDE_SURFACES)
    if not isinstance(raw, dict):
        raise ConfigError("curvature must be a mapping")
    highways = _string_list(raw["highways"], "curvature.highways") if "highways" in raw else DEFAULT_HIGHWAYS
    surfaces = (
        _string_list(raw["exclude_surfaces"], "curvature.exclude_surfaces")
        if "exclude_surfaces" in raw
        else DEFAULT_EXCLUDE_SURFACES
    )
    return CurvatureConfig(highways, surfaces)


def _parse_trail_sources(raw: object, where: str) -> tuple[str, ...]:
    if raw is None:
        return ("osm",)
    if not isinstance(raw, dict):
        raise ConfigError(f"{where}: trails must be a mapping")
    sources = raw.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ConfigError(f"{where}: trails.sources must list at least one source")
    for s in sources:
        if s not in KNOWN_TRAIL_SOURCES:
            raise ConfigError(f"{where}: unknown trail source {s!r}; known: {sorted(KNOWN_TRAIL_SOURCES)}")
    return tuple(sources)


def _parse_expect(raw: object, where: str) -> dict[str, RowRange]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ConfigError(f"{where}: expect must be a mapping")
    out: dict[str, RowRange] = {}
    for key, value in raw.items():
        if key not in EXPECT_KEYS:
            raise ConfigError(f"{where}: unknown expect key {key!r}; known: {sorted(EXPECT_KEYS)}")
        if not isinstance(value, list) or len(value) != 2 or not all(_is_int(v) for v in value):
            raise ConfigError(f"{where}: expect.{key} must be [min, max]")
        lo, hi = value
        if lo < 0:
            raise ConfigError(f"{where}: expect.{key}: min must be >= 0")
        if lo > hi:
            raise ConfigError(f"{where}: expect.{key}: min must be <= max")
        out[key] = RowRange(lo, hi)
    return out
```

(`_is_int` is the existing bool-rejecting helper.) Wire them: `_parse_region` sets `trail_sources=_parse_trail_sources(raw.get("trails"), where)` and `expect=_parse_expect(raw.get("expect"), where)`; `load_config` sets `curvature=_parse_curvature(data.get("curvature"))`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_config.py -q`
Expected: all pass (the earlier config tests must still pass; `Region` construction sites in other tests use keywords, so the new fields with no defaults are fine only if every construction goes through `load_config` — check `grep -rn "Region(" tests src`).

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add config/regions.yaml pipeline/src/maqs/config.py pipeline/tests/test_config.py
git commit -m "feat(pipeline): curvature filters, trail sources and row-count expectations in regions.yaml"
```

---

### Task 3: Geofabrik fetch and osmium cuts (`cache.py`, `osm/extract.py`)

**Files:**
- Create: `pipeline/src/maqs/cache.py`, `pipeline/src/maqs/osm/__init__.py`, `pipeline/src/maqs/osm/extract.py`, `pipeline/tests/test_cache.py`, `pipeline/tests/test_osm_extract.py`

**Interfaces:**
- Consumes: `BuildContext` (`ctx.cache`, `ctx.force`, `ctx.region` with `.osm`, `.clip`, `.bbox`, `.id`), `tools.run`, `tools.find_tool`, `format_bbox` from `steps/tiles.py`, `maqs.__version__`.
- Produces:
  - `cache.py`: `class FetchError(OSError)`; `md5_of(path: Path) -> str`; `parse_md5_sidecar(text: str) -> str`; `download(url: str, dest: Path, *, user_agent: str, opener: Callable = urllib.request.urlopen) -> None` (streams to `dest.with_suffix(dest.suffix + ".part")`, renames on success); `USER_AGENT: str`.
  - `osm/extract.py`: `GEOFABRIK_BASE = "https://download.geofabrik.de"`; `extract_name(extract: str) -> str` (`europe/italy/nord-est` → `europe-italy-nord-est`); `geofabrik_pbf(ctx) -> Path`; `hiking_pbf(ctx) -> Path`; `write_poly(features: Iterable[dict], path: Path, name: str) -> int`; `clip_poly(ctx) -> Path | None`; `region_pbf(ctx) -> Path`; `region_hiking_pbf(ctx) -> Path`; `tags_filter(src: Path, dst: Path, expressions: Sequence[str]) -> list[str]`; `osm_timestamp(pbf: Path) -> str | None`; `region_extract_id(ctx) -> str` (raises `FetchError` when the region has no `osm.geofabrik`).
  - Cache layout: `<cache>/geofabrik/<name>-latest.osm.pbf`, `<cache>/geofabrik/<name>-hiking.osm.pbf`, `<cache>/<region>/clip.poly`, `<cache>/<region>/region.osm.pbf`, `<cache>/<region>/hiking.osm.pbf`.
  - Skip rule: the Geofabrik file is reused whenever present (never re-downloaded); every derived file is reused when present unless `ctx.force`.

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_cache.py
import hashlib
import io

import pytest

from maqs.cache import FetchError, download, md5_of, parse_md5_sidecar


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def test_md5_of_and_sidecar(tmp_path):
    p = tmp_path / "f.pbf"
    p.write_bytes(b"maqs" * 100)
    digest = hashlib.md5(b"maqs" * 100).hexdigest()
    assert md5_of(p) == digest
    assert parse_md5_sidecar(f"{digest}  nord-est-latest.osm.pbf\n") == digest
    with pytest.raises(FetchError, match="malformed md5"):
        parse_md5_sidecar("not a digest")


def test_download_streams_to_part_file_then_renames(tmp_path):
    seen = {}

    def opener(request):
        seen["ua"] = request.get_header("User-agent")
        return FakeResponse(b"payload")

    dest = tmp_path / "x.pbf"
    download("https://example.test/x.pbf", dest, user_agent="maqs-test/1", opener=opener)
    assert dest.read_bytes() == b"payload" and not dest.with_suffix(".pbf.part").exists()
    assert seen["ua"] == "maqs-test/1"


def test_download_failure_leaves_no_file(tmp_path):
    def opener(request):
        raise OSError("connection reset")

    dest = tmp_path / "x.pbf"
    with pytest.raises(FetchError, match="connection reset"):
        download("https://example.test/x.pbf", dest, user_agent="t", opener=opener)
    assert not dest.exists() and not list(tmp_path.iterdir())
```

```python
# pipeline/tests/test_osm_extract.py
import hashlib
import io
import json
from pathlib import Path

import pytest

from maqs import tools
from maqs.cache import FetchError
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.osm import extract

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.fixture
def cfg():
    return load_config(REAL)


@pytest.fixture
def veneto(cfg, tmp_path):
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("veneto"))


@pytest.fixture
def test_region(cfg, tmp_path):
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("test"))


@pytest.fixture
def osmium_bin(monkeypatch):
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/usr/bin/{name}"))


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
    assert extract.extract_name("europe/italy/nord-est") == "europe-italy-nord-est"


def test_region_extract_id_requires_osm(cfg, tmp_path):
    ctx = BuildContext(config=cfg, dist=tmp_path, cache=tmp_path, force=False, region=cfg.region("veneto"))
    assert extract.region_extract_id(ctx) == "europe/italy/nord-est"
    no_osm = cfg.region("veneto").__class__(**{**cfg.region("veneto").__dict__, "osm": None})
    ctx2 = BuildContext(config=cfg, dist=tmp_path, cache=tmp_path, force=False, region=no_osm)
    with pytest.raises(FetchError, match="no osm.geofabrik"):
        extract.region_extract_id(ctx2)


def test_geofabrik_pbf_downloads_once_with_md5_check(veneto, monkeypatch):
    payload = b"pbf-bytes"
    digest = hashlib.md5(payload).hexdigest()
    fetched: list[str] = []

    def fake_download(url, dest, **kw):
        fetched.append(url)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(f"{digest}  nord-est-latest.osm.pbf\n".encode() if url.endswith(".md5") else payload)

    monkeypatch.setattr(extract, "download", fake_download)
    path = extract.geofabrik_pbf(veneto)
    assert path == veneto.cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf"
    assert path.read_bytes() == payload
    assert fetched == [
        "https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf.md5",
        "https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf",
    ]
    extract.geofabrik_pbf(veneto)
    veneto.force = True
    extract.geofabrik_pbf(veneto)
    assert len(fetched) == 2  # reused, even with --force


def test_geofabrik_pbf_rejects_md5_mismatch(veneto, monkeypatch):
    def fake_download(url, dest, **kw):
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"0" * 32 + b"  x\n" if url.endswith(".md5") else b"corrupt")

    monkeypatch.setattr(extract, "download", fake_download)
    with pytest.raises(FetchError, match="md5 mismatch"):
        extract.geofabrik_pbf(veneto)
    assert not list((veneto.cache / "geofabrik").glob("*.pbf"))


def test_hiking_pbf_runs_tags_filter_once(veneto, osmium_bin, monkeypatch):
    calls = record_runs(monkeypatch)
    src = veneto.cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf"
    src.parent.mkdir(parents=True)
    src.write_bytes(b"pbf")
    out = extract.hiking_pbf(veneto)
    assert out == src.with_name("europe-italy-nord-est-hiking.osm.pbf")
    assert calls == [["/usr/bin/osmium", "tags-filter", str(src), "r/route=hiking", "-o", str(out), "--overwrite"]]
    extract.hiking_pbf(veneto)
    assert len(calls) == 1


def test_write_poly_from_geojson_features(tmp_path):
    features = [
        {"type": "Feature", "geometry": {"type": "MultiPolygon", "coordinates": [
            [[[12.2, 46.0], [12.3, 46.0], [12.3, 46.1], [12.2, 46.0]], [[12.21, 46.01], [12.22, 46.01], [12.22, 46.02], [12.21, 46.01]]],
        ]}, "properties": {}},
        {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [[[13.0, 46.0], [13.1, 46.0], [13.1, 46.1], [13.0, 46.0]]]}, "properties": {}},
    ]
    path = tmp_path / "clip.poly"
    assert extract.write_poly(features, path, "veneto") == 3
    text = path.read_text()
    assert text.startswith("veneto\n")
    assert text.count("END\n") == 4  # three sections + the file terminator
    assert "!" in text.split("END")[1]  # second section is the inner ring
    assert "   12.2 46.0\n" in text and "   13.1 46.1\n" in text


def test_write_poly_rejects_non_polygons(tmp_path):
    with pytest.raises(FetchError, match="no polygon rings"):
        extract.write_poly([{"type": "Feature", "geometry": {"type": "Point", "coordinates": [1, 2]}}], tmp_path / "x.poly", "x")


def test_clip_poly_runs_getid_and_export(veneto, osmium_bin, monkeypatch):
    calls: list[list[str]] = []

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        calls.append(argv)
        out = Path(argv[argv.index("-o") + 1])
        out.parent.mkdir(parents=True, exist_ok=True)
        if argv[1] == "export":
            feature = {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [[[12.2, 46.0], [12.3, 46.0], [12.3, 46.1], [12.2, 46.0]]]}, "properties": {}}
            out.write_text("\x1e" + json.dumps(feature) + "\n")
        else:
            out.write_bytes(b"pbf")
        return None

    monkeypatch.setattr(tools, "run", fake_run)
    (veneto.cache / "geofabrik").mkdir(parents=True)
    (veneto.cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf").write_bytes(b"pbf")
    poly = extract.clip_poly(veneto)
    assert poly == veneto.cache / "veneto" / "clip.poly" and poly.read_text().startswith("veneto\n")
    assert calls[0][:3] == ["/usr/bin/osmium", "getid", "-r"] and "r43648" in calls[0]
    assert calls[1][1:4] == ["export", str(veneto.cache / "veneto" / "admin.osm.pbf"), "-f"] and "geojsonseq" in calls[1]
    assert not (veneto.cache / "veneto" / "admin.osm.pbf").exists()  # intermediates removed


def test_clip_poly_is_none_without_clip(test_region, osmium_bin, monkeypatch):
    record_runs(monkeypatch)
    assert extract.clip_poly(test_region) is None


def test_region_pbf_uses_polygon_or_bbox(veneto, test_region, osmium_bin, monkeypatch):
    calls = record_runs(monkeypatch)
    for ctx in (veneto, test_region):
        (ctx.cache / "geofabrik").mkdir(parents=True, exist_ok=True)
        (ctx.cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf").write_bytes(b"pbf")
    (veneto.cache / "veneto").mkdir(parents=True)
    (veneto.cache / "veneto" / "clip.poly").write_text("veneto\nEND\n")
    out = extract.region_pbf(veneto)
    assert out == veneto.cache / "veneto" / "region.osm.pbf"
    assert calls[-1] == ["/usr/bin/osmium", "extract", "--polygon", str(veneto.cache / "veneto" / "clip.poly"), "-s", "complete_ways",
                         str(veneto.cache / "geofabrik" / "europe-italy-nord-est-latest.osm.pbf"), "-o", str(out), "--overwrite"]
    out2 = extract.region_pbf(test_region)
    assert calls[-1][2:4] == ["--bbox", "12.21,46.08,12.29,46.13"] and out2.name == "region.osm.pbf"


def test_region_hiking_pbf_uses_smart_strategy(veneto, osmium_bin, monkeypatch):
    calls = record_runs(monkeypatch)
    (veneto.cache / "geofabrik").mkdir(parents=True)
    (veneto.cache / "geofabrik" / "europe-italy-nord-est-hiking.osm.pbf").write_bytes(b"pbf")
    (veneto.cache / "veneto").mkdir(parents=True)
    (veneto.cache / "veneto" / "clip.poly").write_text("veneto\nEND\n")
    out = extract.region_hiking_pbf(veneto)
    assert calls[-1][4:8] == ["-s", "smart", "-S", "types=route"] and out == veneto.cache / "veneto" / "hiking.osm.pbf"
    extract.region_hiking_pbf(veneto)
    assert len(calls) == 1
    veneto.force = True
    extract.region_hiking_pbf(veneto)
    assert len(calls) == 2


def test_osm_timestamp(osmium_bin, monkeypatch):
    import subprocess

    monkeypatch.setattr(tools, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 0, "2026-10-06T20:21:06Z\n", ""))
    assert extract.osm_timestamp(Path("/x.pbf")) == "2026-10-06T20:21:06Z"
    monkeypatch.setattr(tools, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 0, "\n", ""))
    assert extract.osm_timestamp(Path("/x.pbf")) is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_cache.py tests/test_osm_extract.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.cache'`

- [ ] **Step 3: Implement `cache.py`**

```python
# pipeline/src/maqs/cache.py
"""Downloads into .cache/ with an identifying User-Agent, streamed, verified, atomic."""

from __future__ import annotations

import hashlib
import re
import urllib.request
from collections.abc import Callable
from pathlib import Path

from maqs import __version__

USER_AGENT = f"maqs-pipeline/{__version__} (+https://github.com/lucavallin/maqs)"
_MD5_RE = re.compile(r"^([0-9a-fA-F]{32})\b")


class FetchError(OSError):
    """A download or an input cut failed; the message says which file and why."""


def md5_of(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_md5_sidecar(text: str) -> str:
    match = _MD5_RE.match(text.strip())
    if not match:
        raise FetchError(f"malformed md5 sidecar: {text.strip()[:60]!r}")
    return match.group(1).lower()


def download(
    url: str,
    dest: Path,
    *,
    user_agent: str = USER_AGENT,
    opener: Callable = urllib.request.urlopen,
) -> None:
    """Stream url into dest via a .part file; on any failure leave nothing behind."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": user_agent})
    try:
        with opener(request) as response, part.open("wb") as out:
            for chunk in iter(lambda: response.read(1 << 20), b""):
                out.write(chunk)
        part.replace(dest)
    except OSError as exc:
        part.unlink(missing_ok=True)
        raise FetchError(f"download of {url} failed: {exc}") from exc
```

Note: the `# noqa: S324` comment is only needed if ruff's `S` rules are enabled; they are not (select is E,F,I,B,UP,SIM,PTH), so omit the comment.

- [ ] **Step 4: Implement `osm/extract.py`**

```python
# pipeline/src/maqs/osm/__init__.py
```

```python
# pipeline/src/maqs/osm/extract.py
"""Geofabrik input and the per-region osmium cuts every data layer reads.

The extract is downloaded once per run and never re-downloaded (delete it to refresh).
Hiking relations are completed across the clip boundary with osmium's smart strategy, so
a relation that crosses a region border keeps all its member ways (ADR 0006).
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence
from pathlib import Path

from maqs import tools
from maqs.cache import FetchError, download, md5_of, parse_md5_sidecar
from maqs.context import BuildContext
from maqs.steps.tiles import format_bbox

GEOFABRIK_BASE = "https://download.geofabrik.de"


def extract_name(extract: str) -> str:
    return extract.strip("/").replace("/", "-")


def region_extract_id(ctx: BuildContext) -> str:
    region = ctx._region()
    extract = (region.osm or {}).get("geofabrik")
    if not isinstance(extract, str) or not extract:
        raise FetchError(f"region '{region.id}' has no osm.geofabrik extract; the data layers need one")
    return extract


def _osmium() -> str:
    return str(tools.find_tool("osmium"))


def geofabrik_pbf(ctx: BuildContext) -> Path:
    extract = region_extract_id(ctx)
    dest = ctx.cache / "geofabrik" / f"{extract_name(extract)}-latest.osm.pbf"
    if dest.exists():
        return dest
    url = f"{GEOFABRIK_BASE}/{extract}-latest.osm.pbf"
    md5_file = dest.with_suffix(dest.suffix + ".md5")
    download(f"{url}.md5", md5_file)
    expected = parse_md5_sidecar(md5_file.read_text(encoding="utf-8"))
    tmp = dest.with_suffix(dest.suffix + ".unverified")
    download(url, tmp)
    actual = md5_of(tmp)
    if actual != expected:
        tmp.unlink(missing_ok=True)
        raise FetchError(f"md5 mismatch for {url}: expected {expected}, got {actual}")
    tmp.replace(dest)
    return dest


def tags_filter(src: Path, dst: Path, expressions: Sequence[str]) -> list[str]:
    argv = [_osmium(), "tags-filter", str(src), *expressions, "-o", str(dst), "--overwrite"]
    dst.parent.mkdir(parents=True, exist_ok=True)
    tools.run(argv)
    return argv


def hiking_pbf(ctx: BuildContext) -> Path:
    src = geofabrik_pbf(ctx)
    dst = src.with_name(src.name.replace("-latest.osm.pbf", "-hiking.osm.pbf"))
    if dst.exists() and not ctx.force:
        return dst
    tags_filter(src, dst, ["r/route=hiking"])
    return dst


def _rings(feature: dict) -> list[tuple[list[list[float]], bool]]:
    geometry = feature.get("geometry") or {}
    kind = geometry.get("type")
    polygons: list[list[list[list[float]]]]
    if kind == "Polygon":
        polygons = [geometry["coordinates"]]
    elif kind == "MultiPolygon":
        polygons = geometry["coordinates"]
    else:
        return []
    out = []
    for polygon in polygons:
        for i, ring in enumerate(polygon):
            out.append((ring, i > 0))
    return out


def write_poly(features: Iterable[dict], path: Path, name: str) -> int:
    """Write an Osmosis .poly: one section per ring, '!' marks inner rings. Returns the ring count."""
    lines = [name]
    count = 0
    for feature in features:
        for ring, inner in _rings(feature):
            count += 1
            lines.append(f"{'!' if inner else ''}ring{count}")
            lines.extend(f"   {lon!r} {lat!r}" for lon, lat in ring)
            lines.append("END")
    if count == 0:
        raise FetchError(f"{path}: the admin relations produced no polygon rings")
    lines.append("END")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return count


def clip_poly(ctx: BuildContext) -> Path | None:
    region = ctx._region()
    admin = (region.clip or {}).get("admin") if region.clip else None
    if not admin:
        return None
    poly = ctx.cache / region.id / "clip.poly"
    if poly.exists() and not ctx.force:
        return poly
    src = geofabrik_pbf(ctx)
    admin_pbf = poly.with_name("admin.osm.pbf")
    seq = poly.with_name("admin.geojsonseq")
    poly.parent.mkdir(parents=True, exist_ok=True)
    try:
        tools.run([_osmium(), "getid", "-r", "-t", str(src), *(f"r{i}" for i in admin), "-o", str(admin_pbf), "-f", "pbf", "--overwrite"])
        tools.run([_osmium(), "export", str(admin_pbf), "-f", "geojsonseq", "--geometry-types=polygon", "-o", str(seq), "--overwrite"])
        features = [json.loads(line.lstrip("\x1e")) for line in seq.read_text(encoding="utf-8").splitlines() if line.strip("\x1e \n")]
        write_poly(features, poly, region.id)
    finally:
        admin_pbf.unlink(missing_ok=True)
        seq.unlink(missing_ok=True)
    return poly


def _extent_args(ctx: BuildContext) -> list[str]:
    poly = clip_poly(ctx)
    if poly is not None:
        return ["--polygon", str(poly)]
    return ["--bbox", format_bbox(ctx._region().bbox)]


def region_pbf(ctx: BuildContext) -> Path:
    region = ctx._region()
    dst = ctx.cache / region.id / "region.osm.pbf"
    if dst.exists() and not ctx.force:
        return dst
    src = geofabrik_pbf(ctx)
    dst.parent.mkdir(parents=True, exist_ok=True)
    tools.run([_osmium(), "extract", *_extent_args(ctx), "-s", "complete_ways", str(src), "-o", str(dst), "--overwrite"])
    return dst


def region_hiking_pbf(ctx: BuildContext) -> Path:
    region = ctx._region()
    dst = ctx.cache / region.id / "hiking.osm.pbf"
    if dst.exists() and not ctx.force:
        return dst
    src = hiking_pbf(ctx)
    dst.parent.mkdir(parents=True, exist_ok=True)
    tools.run([_osmium(), "extract", *_extent_args(ctx), "-s", "smart", "-S", "types=route", str(src), "-o", str(dst), "--overwrite"])
    return dst


def osm_timestamp(pbf: Path) -> str | None:
    result = tools.run([_osmium(), "fileinfo", "-g", "header.option.osmosis_replication_timestamp", str(pbf)])
    value = (result.stdout or "").strip()
    return value or None
```

`BuildContext._region()` is the plan-1 accessor that raises when no region is set; if it is named differently in `context.py`, use the existing name (do not add a second one).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_cache.py tests/test_osm_extract.py -q`
Expected: all pass. `test_region_pbf_uses_polygon_or_bbox` relies on `format_bbox` printing `12.21,46.08,12.29,46.13`.

- [ ] **Step 6: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/cache.py pipeline/src/maqs/osm pipeline/tests/test_cache.py pipeline/tests/test_osm_extract.py
git commit -m "feat(pipeline): Geofabrik fetch with md5 check and per-region osmium cuts"
```

---

### Task 4: PMTiles tile lookup and terrain sampling

**Files:**
- Modify: `pipeline/src/maqs/pmtiles_header.py` (expose `inflate_gzip(data: bytes, max_bytes: int) -> bytes`, used by the existing metadata path), `pipeline/tests/helpers.py` (`write_pmtiles` gains `tile_id: int = 0`)
- Create: `pipeline/src/maqs/pmtiles_reader.py`, `pipeline/src/maqs/osm/terrain_sampler.py`, `pipeline/tests/test_pmtiles_reader.py`, `pipeline/tests/test_terrain_sampler.py`

**Interfaces:**
- Produces:
  - `pmtiles_reader.py`: `zxy_to_tile_id(z: int, x: int, y: int) -> int`; `@dataclass(frozen=True) Entry(tile_id: int, offset: int, length: int, run_length: int)`; `read_directory(data: bytes) -> list[Entry]`; `find_entry(entries: Sequence[Entry], tile_id: int) -> Entry | None`; `class PMTilesArchive(path: Path)` with `.header`, `.tile(z, x, y) -> bytes | None` (decompressed per `tile_compression`); `MAX_TILE_BYTES = 64 * 1024 * 1024`; `MAX_DIRECTORY_BYTES = 16 * 1024 * 1024`.
  - `terrain_sampler.py`: `terrarium_to_m(r: int, g: int, b: int) -> float`; `lonlat_to_pixel(lon, lat, zoom, tile_size) -> tuple[int, int, float, float]` (tile x, tile y, pixel x, pixel y); `class TerrainSampler(path: Path, *, max_tiles: int = 64)` with `.zoom` (the archive's `max_zoom`), `.elevation(lon, lat) -> float | None`; `ascent_descent(sampler, coords: Sequence[Coord], *, step_m: float = 25.0, hysteresis_m: float = 5.0) -> tuple[float | None, float | None, int]` (ascent, descent, samples without a tile).

- [ ] **Step 1: Extend the helper and refactor the bounded gunzip**

In `pmtiles_header.py`, rename the private bounded inflater to a public `inflate_gzip(data: bytes, max_bytes: int) -> bytes` (raising `PMTilesError` when the cap is hit or the stream is invalid), and call it from `read_metadata` with `MAX_METADATA_BYTES`. In `tests/helpers.py::write_pmtiles` add `tile_id: int = 0` and encode it in the directory entry (`_varint(1) + _varint(tile_id) + _varint(1) + _varint(len(tile_blob)) + _varint(1)`). Run `uv run pytest -q`: everything still passes.

- [ ] **Step 2: Write the failing tests**

```python
# pipeline/tests/test_pmtiles_reader.py
import gzip

import pytest

from maqs.pmtiles_header import PMTilesError
from maqs.pmtiles_reader import Entry, PMTilesArchive, find_entry, read_directory, zxy_to_tile_id
from tests.helpers import _varint, write_pmtiles


@pytest.mark.parametrize("zxy, tile_id", [((0, 0, 0), 0), ((1, 0, 0), 1), ((1, 0, 1), 2), ((1, 1, 1), 3), ((1, 1, 0), 4), ((2, 0, 0), 5)])
def test_zxy_to_tile_id_matches_the_spec_order(zxy, tile_id):
    assert zxy_to_tile_id(*zxy) == tile_id


def test_zxy_to_tile_id_rejects_out_of_range():
    with pytest.raises(ValueError):
        zxy_to_tile_id(1, 2, 0)
    with pytest.raises(ValueError):
        zxy_to_tile_id(32, 0, 0)


def test_read_directory_decodes_deltas_and_implicit_offsets():
    # two entries: id 5 len 10 at offset 0, id 7 len 20 at offset 10 (implicit), one leaf pointer id 9
    data = _varint(3) + _varint(5) + _varint(2) + _varint(2) + _varint(1) + _varint(1) + _varint(0) + _varint(10) + _varint(20) + _varint(99) + _varint(1) + _varint(0) + _varint(501)
    entries = read_directory(data)
    assert entries == [Entry(5, 0, 10, 1), Entry(7, 10, 20, 1), Entry(9, 500, 99, 0)]
    assert find_entry(entries, 5) == entries[0] and find_entry(entries, 7) == entries[1]
    assert find_entry(entries, 6) is None and find_entry(entries, 9) == entries[2]


def test_read_directory_run_length_covers_a_range():
    data = _varint(1) + _varint(10) + _varint(4) + _varint(8) + _varint(1)
    (entry,) = read_directory(data)
    assert entry == Entry(10, 0, 8, 4)
    assert find_entry([entry], 13) == entry and find_entry([entry], 14) is None


def test_read_directory_rejects_truncated_data():
    with pytest.raises(PMTilesError, match="directory"):
        read_directory(_varint(2) + _varint(5))


def test_archive_returns_the_decompressed_tile(tmp_path):
    tile_id = zxy_to_tile_id(12, 2187, 1465)
    p = write_pmtiles(tmp_path / "a.pmtiles", tile_type=1, max_zoom=12, tile=b"hello-tile", tile_id=tile_id)
    archive = PMTilesArchive(p)
    assert archive.tile(12, 2187, 1465) == b"hello-tile"
    assert archive.tile(12, 2188, 1465) is None


def test_archive_returns_uncompressed_tile_as_is(tmp_path):
    p = write_pmtiles(tmp_path / "t.pmtiles", tile_type=4, max_zoom=12, tile_compression=1, tile=b"RIFF....", tile_id=zxy_to_tile_id(12, 1, 1))
    assert PMTilesArchive(p).tile(12, 1, 1) == b"RIFF...."


def test_archive_rejects_tile_beyond_eof(tmp_path):
    p = write_pmtiles(tmp_path / "a.pmtiles", max_zoom=12, tile=b"x" * 100, tile_id=0)
    data = bytearray(p.read_bytes())
    # inflate the tile data length in the header (bytes 64..72) past the file end
    data[64:72] = (10_000).to_bytes(8, "little")
    p.write_bytes(bytes(data))
    with pytest.raises(PMTilesError, match="truncated"):
        PMTilesArchive(p)


def test_archive_rejects_gzip_bomb_tile(tmp_path):
    bomb = gzip.compress(b"\0" * (70 * 1024 * 1024), mtime=0)
    p = tmp_path / "b.pmtiles"
    # write the archive with the precompressed blob by bypassing the helper's compression
    write_pmtiles(p, max_zoom=12, tile_compression=1, tile=bomb, tile_id=0)
    data = bytearray(p.read_bytes())
    data[98] = 2  # declare gzip tile compression
    p.write_bytes(bytes(data))
    with pytest.raises(PMTilesError, match="exceeds"):
        PMTilesArchive(p).tile(0, 0, 0)
```

```python
# pipeline/tests/test_terrain_sampler.py
import io

import pytest
from PIL import Image

from maqs.osm.terrain_sampler import TerrainSampler, ascent_descent, lonlat_to_pixel, terrarium_to_m
from maqs.pmtiles_reader import zxy_to_tile_id
from tests.helpers import write_pmtiles

SIZE = 512


def terrarium_tile(elevation_at) -> bytes:
    """A lossless WebP terrarium tile whose elevation at (px, py) is elevation_at(px, py)."""
    img = Image.new("RGB", (SIZE, SIZE))
    pixels = img.load()
    for py in range(SIZE):
        for px in range(SIZE):
            v = elevation_at(px, py) + 32768.0
            whole = int(v)
            pixels[px, py] = (whole // 256, whole % 256, int(round((v - whole) * 256)) % 256)
    out = io.BytesIO()
    img.save(out, "WEBP", lossless=True)
    return out.getvalue()


def test_terrarium_decode():
    assert terrarium_to_m(128, 0, 0) == 0.0
    assert terrarium_to_m(131, 232, 128) == pytest.approx(1000.5)


def test_lonlat_to_pixel_center_of_the_test_bbox():
    tx, ty, px, py = lonlat_to_pixel(12.25, 46.105, 12, SIZE)
    assert (tx, ty) == (2187, 1455)
    assert 0 <= px < SIZE and 0 <= py < SIZE


@pytest.fixture
def archive(tmp_path):
    tile = terrarium_tile(lambda px, py: 1000.0 + px)  # 1 m per pixel eastwards
    return write_pmtiles(tmp_path / "terrain.pmtiles", tile_type=4, min_zoom=0, max_zoom=12,
                         tile_compression=1, tile=tile, tile_id=zxy_to_tile_id(12, 2187, 1455))


def test_elevation_is_bilinear_within_the_tile(archive):
    sampler = TerrainSampler(archive)
    assert sampler.zoom == 12
    tx, ty, px, py = lonlat_to_pixel(12.25, 46.105, 12, SIZE)
    e = sampler.elevation(12.25, 46.105)
    assert e == pytest.approx(1000.0 + px, abs=0.6)  # bilinear between neighbouring columns


def test_elevation_is_none_outside_coverage(archive):
    assert TerrainSampler(archive).elevation(13.5, 46.105) is None


def test_ascent_descent_with_hysteresis(archive, monkeypatch):
    sampler = TerrainSampler(archive)
    # 9 samples: 0, 25, ..., 175 m and the endpoint at ~190 m
    profile = iter([100.0, 102.0, 104.0, 112.0, 111.0, 103.0, 103.0, 120.0, 120.0])  # +12 (the +2/+4 steps stay under the hysteresis until 112), -9, +17
    monkeypatch.setattr(sampler, "elevation", lambda lon, lat: next(profile))
    coords = [(12.25, 46.10), (12.2525, 46.10)]  # ~190 m
    ascent, descent, missing = ascent_descent(sampler, coords)
    assert ascent == pytest.approx(29.0) and descent == pytest.approx(9.0) and missing == 0


def test_ascent_descent_counts_missing_samples(archive, monkeypatch):
    sampler = TerrainSampler(archive)
    values = iter([100.0, None, None, 130.0, 130.0])  # 5 samples: 0, 25, 50, 75 m and the endpoint at ~77 m
    monkeypatch.setattr(sampler, "elevation", lambda lon, lat: next(values))
    ascent, descent, missing = ascent_descent(sampler, [(12.25, 46.10), (12.2510, 46.10)])
    assert ascent == pytest.approx(30.0) and descent == 0.0 and missing == 2


def test_ascent_descent_all_missing_is_none(archive, monkeypatch):
    sampler = TerrainSampler(archive)
    monkeypatch.setattr(sampler, "elevation", lambda lon, lat: None)
    assert ascent_descent(sampler, [(13.5, 46.1), (13.51, 46.1)]) == (None, None, 32)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `uv run pytest tests/test_pmtiles_reader.py tests/test_terrain_sampler.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.pmtiles_reader'`

- [ ] **Step 4: Implement `pmtiles_reader.py`**

```python
# pipeline/src/maqs/pmtiles_reader.py
"""Tile lookup in a local PMTiles v3 archive: Hilbert tile ids, directories, leaf directories.

Everything is bounds-checked against the file; a corrupt directory or an oversized tile is a
PMTilesError. Only what the terrain sampler needs; the Swift reader mirrors it.
"""

from __future__ import annotations

from bisect import bisect_right
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from maqs.pmtiles_header import Header, PMTilesError, inflate_gzip, read_header

MAX_TILE_BYTES = 64 * 1024 * 1024
MAX_DIRECTORY_BYTES = 16 * 1024 * 1024


def zxy_to_tile_id(z: int, x: int, y: int) -> int:
    if z < 0 or z > 31:
        raise ValueError(f"zoom {z} out of range 0..31")
    n = 1 << z
    if not (0 <= x < n and 0 <= y < n):
        raise ValueError(f"tile {x}/{y} out of range for zoom {z}")
    acc = ((1 << (2 * z)) - 1) // 3  # tiles in all lower zooms
    d = 0
    s = n >> 1
    while s > 0:
        rx = 1 if x & s else 0
        ry = 1 if y & s else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                x, y = n - 1 - x, n - 1 - y
            x, y = y, x
        s >>= 1
    return acc + d


@dataclass(frozen=True)
class Entry:
    tile_id: int
    offset: int
    length: int
    run_length: int  # 0 = pointer to a leaf directory


def _read_varint(data: bytes, pos: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        if pos >= len(data):
            raise PMTilesError("truncated directory varint")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise PMTilesError("directory varint too long")


def read_directory(data: bytes) -> list[Entry]:
    count, pos = _read_varint(data, 0)
    ids: list[int] = []
    last = 0
    for _ in range(count):
        delta, pos = _read_varint(data, pos)
        last += delta
        ids.append(last)
    runs: list[int] = []
    for _ in range(count):
        value, pos = _read_varint(data, pos)
        runs.append(value)
    lengths: list[int] = []
    for _ in range(count):
        value, pos = _read_varint(data, pos)
        lengths.append(value)
    offsets: list[int] = []
    for i in range(count):
        value, pos = _read_varint(data, pos)
        if value == 0 and i > 0:
            offsets.append(offsets[i - 1] + lengths[i - 1])
        else:
            offsets.append(value - 1)
    return [Entry(ids[i], offsets[i], lengths[i], runs[i]) for i in range(count)]


def find_entry(entries: Sequence[Entry], tile_id: int) -> Entry | None:
    ids = [e.tile_id for e in entries]
    i = bisect_right(ids, tile_id) - 1
    if i < 0:
        return None
    entry = entries[i]
    if entry.run_length == 0:
        return entry  # leaf pointer: covers every id from its tile_id to the next entry
    if tile_id < entry.tile_id + entry.run_length:
        return entry
    return None


class PMTilesArchive:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.header: Header = read_header(path)
        self._root = read_directory(self._section(self.header.root_dir_offset, self.header.root_dir_length, MAX_DIRECTORY_BYTES))

    def _read(self, offset: int, length: int) -> bytes:
        with self.path.open("rb") as f:
            f.seek(offset)
            data = f.read(length)
        if len(data) != length:
            raise PMTilesError(f"{self.path}: truncated read at {offset}+{length}")
        return data

    def _section(self, offset: int, length: int, cap: int) -> bytes:
        if length > cap:
            raise PMTilesError(f"{self.path}: section of {length} bytes exceeds {cap}")
        raw = self._read(offset, length)
        if self.header.internal_compression == "gzip":
            return inflate_gzip(raw, cap)
        if self.header.internal_compression == "none":
            return raw
        raise PMTilesError(f"{self.path}: unsupported internal compression {self.header.internal_compression}")

    def tile(self, z: int, x: int, y: int) -> bytes | None:
        tile_id = zxy_to_tile_id(z, x, y)
        entry = find_entry(self._root, tile_id)
        if entry is not None and entry.run_length == 0:
            leaf = read_directory(self._section(self.header.leaf_dirs_offset + entry.offset, entry.length, MAX_DIRECTORY_BYTES))
            entry = find_entry(leaf, tile_id)
            if entry is not None and entry.run_length == 0:
                raise PMTilesError(f"{self.path}: nested leaf directories are not supported")
        if entry is None:
            return None
        if entry.length > MAX_TILE_BYTES:
            raise PMTilesError(f"{self.path}: tile of {entry.length} bytes exceeds {MAX_TILE_BYTES}")
        if entry.offset + entry.length > self.header.tile_data_length:
            raise PMTilesError(f"{self.path}: tile entry beyond the tile data section")
        raw = self._read(self.header.tile_data_offset + entry.offset, entry.length)
        if self.header.tile_compression == "gzip":
            return inflate_gzip(raw, MAX_TILE_BYTES)
        return raw
```

`inflate_gzip` must raise `PMTilesError` whose message contains "exceeds" when the cap is hit (the metadata test from plan 1 already matches "metadata exceeds"; keep that message for the metadata caller and make the generic one "inflated data exceeds N bytes").

- [ ] **Step 5: Implement `osm/terrain_sampler.py`**

```python
# pipeline/src/maqs/osm/terrain_sampler.py
"""Elevation along a line from the region's own terrarium terrain archive.

Tiles are 512 px WebP at the archive's max zoom (12). Sampling is bilinear inside a tile and
clamped at its edges (no cross-tile interpolation). Ascent and descent use a hysteresis so that
sensor-scale noise does not add up (ADR 0011).
"""

from __future__ import annotations

import io
import math
from collections import OrderedDict
from collections.abc import Sequence
from pathlib import Path

from PIL import Image

from maqs.geometry import Coord, resample
from maqs.pmtiles_reader import PMTilesArchive


def terrarium_to_m(r: int, g: int, b: int) -> float:
    return (r * 256 + g + b / 256) - 32768


def lonlat_to_pixel(lon: float, lat: float, zoom: int, tile_size: int) -> tuple[int, int, float, float]:
    n = 1 << zoom
    x = (lon + 180.0) / 360.0 * n
    lat_rad = math.radians(lat)
    y = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * n
    tx, ty = int(math.floor(x)), int(math.floor(y))
    return tx, ty, (x - tx) * tile_size, (y - ty) * tile_size


class TerrainSampler:
    def __init__(self, path: Path, *, max_tiles: int = 64) -> None:
        self.archive = PMTilesArchive(path)
        self.zoom = self.archive.header.max_zoom
        self._tiles: OrderedDict[tuple[int, int], Image.Image | None] = OrderedDict()
        self._max_tiles = max_tiles

    def _tile(self, tx: int, ty: int) -> Image.Image | None:
        key = (tx, ty)
        if key in self._tiles:
            self._tiles.move_to_end(key)
            return self._tiles[key]
        raw = self.archive.tile(self.zoom, tx, ty)
        image = Image.open(io.BytesIO(raw)).convert("RGB") if raw else None
        self._tiles[key] = image
        if len(self._tiles) > self._max_tiles:
            self._tiles.popitem(last=False)
        return image

    def elevation(self, lon: float, lat: float) -> float | None:
        if not (-85.05 < lat < 85.05):
            return None
        tx, ty, _, _ = lonlat_to_pixel(lon, lat, self.zoom, 1)
        image = self._tile(tx, ty)
        if image is None:
            return None
        size = image.size[0]
        _, _, px, py = lonlat_to_pixel(lon, lat, self.zoom, size)
        px, py = min(max(px - 0.5, 0.0), size - 1.0), min(max(py - 0.5, 0.0), size - 1.0)
        x0, y0 = int(px), int(py)
        x1, y1 = min(x0 + 1, size - 1), min(y0 + 1, size - 1)
        fx, fy = px - x0, py - y0
        pixels = image.load()

        def e(x: int, y: int) -> float:
            return terrarium_to_m(*pixels[x, y][:3])

        top = e(x0, y0) * (1 - fx) + e(x1, y0) * fx
        bottom = e(x0, y1) * (1 - fx) + e(x1, y1) * fx
        return top * (1 - fy) + bottom * fy


def ascent_descent(
    sampler: TerrainSampler,
    coords: Sequence[Coord],
    *,
    step_m: float = 25.0,
    hysteresis_m: float = 5.0,
) -> tuple[float | None, float | None, int]:
    """Sum climbs and descents along the line; a move counts once it exceeds the hysteresis."""
    samples = [sampler.elevation(lon, lat) for lon, lat in resample(coords, step_m)]
    missing = sum(1 for s in samples if s is None)
    values = [s for s in samples if s is not None]
    if not values:
        return None, None, missing
    ascent = descent = 0.0
    base = values[0]
    for value in values[1:]:
        if value > base + hysteresis_m:
            ascent += value - base
            base = value
        elif value < base - hysteresis_m:
            descent += base - value
            base = value
    return ascent, descent, missing
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `uv run pytest tests/test_pmtiles_reader.py tests/test_terrain_sampler.py -q`
Expected: all pass. `test_ascent_descent_with_hysteresis`: samples 100 → 102 (no move), 104 (no), 112 (+12, base 112), 111 (no), 103 (−9, base 103), 103, 120 (+17), 120: ascent 29, descent 9. `resample` always emits the endpoint, so a ~190 m line at 25 m gives 0..175 plus the end = 9 samples; if `next()` raises StopIteration the fixture length is off — check it with `line_length_m` and fix the test coordinates, not the function.

- [ ] **Step 7: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/pmtiles_header.py pipeline/src/maqs/pmtiles_reader.py pipeline/src/maqs/osm/terrain_sampler.py pipeline/tests/helpers.py pipeline/tests/test_pmtiles_reader.py pipeline/tests/test_terrain_sampler.py
git commit -m "feat(pipeline): PMTiles tile lookup and terrain elevation sampling"
```

---

### Task 5: SQLite writer, SQLite validation, step outcomes and report additions

**Files:**
- Create: `pipeline/src/maqs/sqlite_out.py`, `pipeline/tests/test_sqlite_out.py`
- Modify: `pipeline/src/maqs/validate.py`, `pipeline/src/maqs/steps/base.py`, `pipeline/src/maqs/steps/tiles.py`, `pipeline/src/maqs/steps/terrain_hd.py`, `pipeline/src/maqs/report.py`, `pipeline/tests/test_validate.py`, `pipeline/tests/test_steps_base.py`, `pipeline/tests/test_steps_tiles.py`, `pipeline/tests/test_steps_terrain_hd.py`, `pipeline/tests/test_report.py`, `pipeline/tests/test_cli.py` (only where `build()` return values or `expectation()` signatures are asserted)

**Interfaces:**
- Consumes: `RowRange` (Task 2), `OutputInfo`, `Expectation`, `validate_output`, `read_header` (plan 1).
- Produces:
  - `sqlite_out.py`: `ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"`; `SCHEMA_VERSION: dict[str, int]` (`trails`, `places`, `curvature` → 1); `SCHEMAS: dict[str, str]` (the spec's DDL per layer, plus the `metadata` table); `TABLES: dict[str, frozenset[str]]` (every table and virtual table the layer must have); `COUNT_TABLES: dict[str, tuple[str, ...]]` (`trails` → `("trails",)`, `places` → `("places",)`, `curvature` → `("segments", "corners")`); `FTS_TABLES: dict[str, tuple[str, ...]]`; `@dataclass(frozen=True) Metadata(layer: str, region: str, data_date: str, osm_timestamp: str | None)`; `write_sqlite(path: Path, layer: str, meta: Metadata, fill: Callable[[sqlite3.Connection], None]) -> None` (temp file, schema, `fill`, metadata row, FTS rebuild, `VACUUM`, rename); `open_readonly(path: Path) -> sqlite3.Connection`; `table_names(conn) -> set[str]`.
  - `validate.py`: `@dataclass(frozen=True) SqliteExpectation(layer: str, region: str, tables: frozenset[str], count_tables: tuple[str, ...], row_ranges: dict[str, RowRange] = field(default_factory=dict), size_cap: int = SIZE_CAP)`; `OutputInfo` tile fields become `| None` and it gains `rows: dict[str, int] | None = None` (last field); `validate_output(path, expect: Expectation | SqliteExpectation) -> OutputInfo` dispatches; `validate_sqlite(path, expect: SqliteExpectation) -> OutputInfo`.
  - `steps/base.py`: `@dataclass(frozen=True) Anomaly(kind: str, id: str, message: str)`; `@dataclass StepOutcome(command: list[str] = field(default_factory=list), anomalies: list[Anomaly] = field(default_factory=list))`; `Step.build(ctx) -> StepOutcome`; `Step.expectation(ctx, output: Path) -> Expectation | SqliteExpectation`; `StepResult` gains `anomalies: list[Anomaly]` (≤ `MAX_REPORTED_ANOMALIES = 1000`) and `anomaly_count: int`.
  - `report.py`: each output dict carries `rows` only when not None; each step dict carries `anomalies` (list of `{kind, id, message}`) and `anomaly_count`.

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_sqlite_out.py
import sqlite3

import pytest

from maqs.sqlite_out import ATTRIBUTION, COUNT_TABLES, SCHEMA_VERSION, TABLES, Metadata, open_readonly, table_names, write_sqlite
from maqs.validate import SqliteExpectation, ValidationError, validate_output
from maqs.config import RowRange

META = Metadata(layer="trails", region="test", data_date="2026-10-15", osm_timestamp="2026-10-06T20:21:06Z")


def fill_one_trail(conn: sqlite3.Connection) -> None:
    conn.execute(
        "INSERT INTO trails (id, source, source_id, length_m, geometry, geometry_status, name, ref, min_lon, min_lat, max_lon, max_lat) "
        "VALUES (1, 'osm', 'relation/100', 1234.5, 'abc', 'ordered', 'Cimà Grànde', '501', 12.2, 46.0, 12.3, 46.1)"
    )
    conn.execute("INSERT INTO trails_rtree VALUES (1, 12.2, 12.3, 46.0, 46.1)")


def test_write_sqlite_creates_schema_metadata_and_indexes(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    assert not path.with_suffix(".sqlite.tmp").exists()
    conn = open_readonly(path)
    assert table_names(conn) >= TABLES["trails"]
    row = conn.execute("SELECT schema_version, layer, region, data_date, osm_timestamp, attribution FROM metadata").fetchall()
    assert row == [(SCHEMA_VERSION["trails"], "trails", "test", "2026-10-15", "2026-10-06T20:21:06Z", ATTRIBUTION)]
    assert conn.execute("SELECT rowid FROM trails_fts WHERE trails_fts MATCH 'cima grande'").fetchall() == [(1,)]
    assert conn.execute("SELECT id FROM trails_rtree WHERE min_lon <= 12.25 AND max_lon >= 12.25 AND min_lat <= 46.05 AND max_lat >= 46.05").fetchall() == [(1,)]
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("INSERT INTO trails (id, source, source_id, length_m, geometry, geometry_status) VALUES (2, 'x', 'y', 1, 'g', 'ordered')")


@pytest.mark.parametrize("layer", ["trails", "places", "curvature"])
def test_every_schema_creates_its_tables(tmp_path, layer):
    path = tmp_path / f"x-{layer}.sqlite"
    write_sqlite(path, layer, Metadata(layer, "x", "2026-10-15", None), lambda conn: None)
    conn = open_readonly(path)
    assert table_names(conn) >= TABLES[layer]
    for table in COUNT_TABLES[layer]:
        assert conn.execute(f"SELECT count(*) FROM {table}").fetchone() == (0,)


def expectation(**overrides):
    base = dict(layer="trails", region="test", tables=TABLES["trails"], count_tables=COUNT_TABLES["trails"])
    base.update(overrides)
    return SqliteExpectation(**base)


def test_validate_sqlite_reports_rows_and_metadata(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    info = validate_output(path, expectation(row_ranges={"trails": RowRange(1, 10)}))
    assert info.rows == {"trails": 1} and info.tile_type is None and info.tiles is None
    assert info.attribution == ATTRIBUTION and info.source_data_date == "2026-10-06T20:21:06Z"
    assert info.file == "test-trails.sqlite" and info.bytes == path.stat().st_size


def test_validate_sqlite_fails_outside_the_expected_range(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    with pytest.raises(ValidationError, match="trails has 1 rows, expected 5..10"):
        validate_output(path, expectation(row_ranges={"trails": RowRange(5, 10)}))
    assert path.exists()  # kept for inspection


def test_validate_sqlite_rejects_missing_table_and_wrong_metadata(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    with pytest.raises(ValidationError, match="metadata layer 'trails', expected 'places'"):
        validate_output(path, expectation(layer="places"))
    conn = sqlite3.connect(path)
    conn.execute("DROP TABLE trails_rtree")
    conn.commit()
    conn.close()
    with pytest.raises(ValidationError, match="missing tables: trails_rtree"):
        validate_output(path, expectation())


def test_validate_sqlite_rejects_garbage_and_truncation(tmp_path):
    garbage = tmp_path / "g.sqlite"
    garbage.write_bytes(b"not a database" * 100)
    with pytest.raises(ValidationError, match="not a database|integrity"):
        validate_output(garbage, expectation())
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    path.write_bytes(path.read_bytes()[: path.stat().st_size // 2])
    with pytest.raises(ValidationError):
        validate_output(path, expectation())


def test_validate_sqlite_warns_but_passes_on_zero_rows_without_ranges(tmp_path, caplog):
    path = tmp_path / "x-trails.sqlite"
    write_sqlite(path, "trails", Metadata("trails", "x", "2026-10-15", None), lambda conn: None)
    with caplog.at_level("WARNING"):
        info = validate_output(path, expectation(region="x"))
    assert info.rows == {"trails": 0} and "zero rows" in caplog.text
```

Additions to `tests/test_steps_base.py` (the `FakeStep` returns `StepOutcome` and takes the output path in `expectation`):

```python
from maqs.steps.base import Anomaly, StepOutcome


class FakeStep:
    name = "fake"

    def __init__(self, fail=False, anomalies=0):
        self.calls = 0
        self.fail = fail
        self.anomalies = anomalies

    def outputs(self, ctx):
        return [ctx.out_dir / f"{ctx.label}-fake.pmtiles"]

    def expectation(self, ctx, output):
        return Expectation(0, 14, frozenset({"mvt"}))

    def build(self, ctx):
        self.calls += 1
        if self.fail:
            raise ToolError(["versatiles", "convert"], 1, "kaboom")
        ctx.out_dir.mkdir(parents=True, exist_ok=True)
        write_pmtiles(self.outputs(ctx)[0], max_zoom=14)
        return StepOutcome(["versatiles", "convert", "x"], [Anomaly("gap", f"relation/{i}", "gap of 12 m") for i in range(self.anomalies)])


def test_anomalies_are_kept_and_capped(ctx):
    result = run_step(FakeStep(anomalies=1200), ctx)
    assert result.status == "built" and result.anomaly_count == 1200 and len(result.anomalies) == 1000
    assert result.anomalies[0] == Anomaly("gap", "relation/0", "gap of 12 m")


def test_each_output_gets_its_own_expectation(ctx):
    class TwoOutputs(FakeStep):
        def outputs(self, ctx):
            return [ctx.out_dir / "a.pmtiles", ctx.out_dir / "b.pmtiles"]

        def expectation(self, ctx, output):
            return Expectation(0, 14 if output.name == "a.pmtiles" else 12, frozenset({"mvt"}))

        def build(self, ctx):
            ctx.out_dir.mkdir(parents=True, exist_ok=True)
            write_pmtiles(ctx.out_dir / "a.pmtiles", max_zoom=14)
            write_pmtiles(ctx.out_dir / "b.pmtiles", max_zoom=12)
            return StepOutcome(["x"])

    result = run_step(TwoOutputs(), ctx)
    assert result.status == "built" and [o.max_zoom for o in result.outputs] == [14, 12]
```

Additions to `tests/test_report.py`:

```python
from maqs.steps.base import Anomaly


def test_report_carries_rows_and_anomalies():
    sqlite_info = OutputInfo(
        file="test-trails.sqlite", bytes=10, sha256="ab" * 32, tile_type=None, min_zoom=None, max_zoom=None, tiles=None,
        compression=None, attribution="© OSM", source_data_date="2026-10-06T20:21:06Z", source=None, metadata={}, rows={"trails": 3},
    )
    result = StepResult("trails", "built", 1.0, ["tippecanoe"], [sqlite_info], anomalies=[Anomaly("gap", "relation/1", "gap of 12 m")], anomaly_count=1)
    step = build_report("test", [result], {})["steps"][0]
    assert step["outputs"][0]["rows"] == {"trails": 3} and step["outputs"][0]["tile_type"] is None
    assert step["anomalies"] == [{"kind": "gap", "id": "relation/1", "message": "gap of 12 m"}] and step["anomaly_count"] == 1
    tile_step = build_report("test", [StepResult("basemap", "built", 1.0, [], [info()])], {})["steps"][0]
    assert "rows" not in tile_step["outputs"][0] and tile_step["anomalies"] == [] and tile_step["anomaly_count"] == 0
```

(`info()` is the existing helper in that file; update its positional `OutputInfo(...)` call for the new field order if it does not already pass `source`; `rows` defaults to `None`.)

In `tests/test_steps_tiles.py` and `tests/test_steps_terrain_hd.py`, assertions of the form `step.build(ctx) == step.argv(ctx)` become `step.build(ctx).command == step.argv(ctx)` (and `command[1] == "extract"` becomes `outcome.command[1]`), and every `step.expectation(ctx)` call gains the output path: `step.expectation(ctx, step.outputs(ctx)[0])`. Do not change what they assert.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_sqlite_out.py tests/test_steps_base.py tests/test_report.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.sqlite_out'` and `ImportError` for `StepOutcome`.

- [ ] **Step 3: Implement `sqlite_out.py`**

```python
# pipeline/src/maqs/sqlite_out.py
"""The three SQLite layer schemas and the one way they are written: temp file, schema, rows,
metadata, FTS rebuild, VACUUM, rename. Formats are documented in docs/data-format.md."""

from __future__ import annotations

import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"
SCHEMA_VERSION: dict[str, int] = {"trails": 1, "places": 1, "curvature": 1}

_METADATA = """
CREATE TABLE metadata (
  schema_version INTEGER NOT NULL, layer TEXT NOT NULL, region TEXT NOT NULL,
  data_date TEXT NOT NULL, osm_timestamp TEXT, attribution TEXT NOT NULL
);
"""

SCHEMAS: dict[str, str] = {
    "trails": _METADATA + """
CREATE TABLE trails (
  id INTEGER PRIMARY KEY, source TEXT NOT NULL, source_id TEXT NOT NULL, source_licence TEXT, source_date TEXT,
  osm_type TEXT, osm_id INTEGER, ref TEXT, ref_rei TEXT, name TEXT,
  difficulty INTEGER, difficulty_scheme TEXT, difficulty_value TEXT,
  network TEXT, operator TEXT, osmc_symbol TEXT, from_name TEXT, to_name TEXT, roundtrip INTEGER,
  survey_date TEXT, website TEXT,
  length_m REAL NOT NULL, ascent_m REAL, descent_m REAL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
  geometry TEXT NOT NULL, geometry_status TEXT NOT NULL,
  secondary_of INTEGER REFERENCES trails(id)
);
CREATE VIRTUAL TABLE trails_fts USING fts5(ref, name, from_name, to_name, operator,
  content='trails', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE trails_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
""",
    "places": _METADATA + """
CREATE TABLE places (
  id INTEGER PRIMARY KEY, osm_type TEXT NOT NULL, osm_id INTEGER NOT NULL, kind TEXT NOT NULL,
  name TEXT, name_it TEXT, name_de TEXT, name_fur TEXT, name_sl TEXT,
  ele REAL, wikidata TEXT, lon REAL NOT NULL, lat REAL NOT NULL, rank_score REAL NOT NULL
);
CREATE VIRTUAL TABLE places_fts USING fts5(name, name_it, name_de, name_fur, name_sl,
  content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE places_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
""",
    "curvature": _METADATA + """
CREATE TABLE segments (
  id INTEGER PRIMARY KEY, osm_way_id INTEGER NOT NULL, name TEXT, ref TEXT, highway TEXT NOT NULL, surface TEXT,
  oneway INTEGER NOT NULL DEFAULT 0, maxspeed TEXT, length_m REAL NOT NULL, score REAL NOT NULL,
  start_node INTEGER NOT NULL, end_node INTEGER NOT NULL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL, geometry TEXT NOT NULL
);
CREATE TABLE corners (
  id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL REFERENCES segments(id), ordinal INTEGER NOT NULL,
  apex_lon REAL NOT NULL, apex_lat REAL NOT NULL, min_radius_m REAL NOT NULL, direction TEXT NOT NULL,
  entry_m REAL NOT NULL, apex_m REAL NOT NULL, exit_m REAL NOT NULL
);
CREATE INDEX corners_segment ON corners(segment_id, ordinal);
CREATE VIRTUAL TABLE segments_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
CREATE VIRTUAL TABLE corners_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
""",
}

TABLES: dict[str, frozenset[str]] = {
    "trails": frozenset({"metadata", "trails", "trails_fts", "trails_rtree"}),
    "places": frozenset({"metadata", "places", "places_fts", "places_rtree"}),
    "curvature": frozenset({"metadata", "segments", "corners", "segments_rtree", "corners_rtree"}),
}
COUNT_TABLES: dict[str, tuple[str, ...]] = {
    "trails": ("trails",),
    "places": ("places",),
    "curvature": ("segments", "corners"),
}
FTS_TABLES: dict[str, tuple[str, ...]] = {"trails": ("trails_fts",), "places": ("places_fts",), "curvature": ()}


@dataclass(frozen=True)
class Metadata:
    layer: str
    region: str
    data_date: str
    osm_timestamp: str | None


def write_sqlite(path: Path, layer: str, meta: Metadata, fill: Callable[[sqlite3.Connection], None]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.unlink(missing_ok=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(tmp)
    try:
        conn.executescript(SCHEMAS[layer])
        fill(conn)
        conn.execute(
            "INSERT INTO metadata VALUES (?, ?, ?, ?, ?, ?)",
            (SCHEMA_VERSION[layer], meta.layer, meta.region, meta.data_date, meta.osm_timestamp, ATTRIBUTION),
        )
        for fts in FTS_TABLES[layer]:
            conn.execute(f"INSERT INTO {fts}({fts}) VALUES ('rebuild')")
        conn.commit()
        conn.execute("VACUUM")
    finally:
        conn.close()
    tmp.replace(path)


def open_readonly(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def table_names(conn: sqlite3.Connection) -> set[str]:
    return {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
```

- [ ] **Step 4: Extend `validate.py`**

Add the import `from maqs.config import RowRange` and `from maqs.sqlite_out import open_readonly, table_names`; make `OutputInfo`'s `tile_type`, `min_zoom`, `max_zoom`, `tiles`, `compression` Optional and append `rows: dict[str, int] | None = None`; add:

```python
@dataclass(frozen=True)
class SqliteExpectation:
    layer: str
    region: str
    tables: frozenset[str]
    count_tables: tuple[str, ...]
    row_ranges: dict[str, RowRange] = field(default_factory=dict)
    size_cap: int = SIZE_CAP


def validate_sqlite(path: Path, expect: SqliteExpectation) -> OutputInfo:
    failures: list[str] = []
    size = path.stat().st_size
    if size >= expect.size_cap:
        failures.append(f"{size} bytes exceeds the size cap of {expect.size_cap}")
    try:
        conn = open_readonly(path)
    except sqlite3.Error as exc:
        raise ValidationError(f"{path.name}: cannot open: {exc}") from exc
    try:
        try:
            check = conn.execute("PRAGMA integrity_check").fetchone()
        except sqlite3.DatabaseError as exc:
            raise ValidationError(f"{path.name}: {exc}") from exc
        if check != ("ok",):
            raise ValidationError(f"{path.name}: integrity check failed: {check}")
        missing = sorted(expect.tables - table_names(conn))
        if missing:
            raise ValidationError(f"{path.name}: missing tables: {', '.join(missing)}")
        meta = conn.execute("SELECT schema_version, layer, region, osm_timestamp, attribution FROM metadata").fetchall()
        if len(meta) != 1:
            failures.append(f"metadata has {len(meta)} rows, expected 1")
            schema_version, layer, region, osm_timestamp, attribution = None, None, None, None, None
        else:
            schema_version, layer, region, osm_timestamp, attribution = meta[0]
            if layer != expect.layer:
                failures.append(f"metadata layer {layer!r}, expected {expect.layer!r}")
            if region != expect.region:
                failures.append(f"metadata region {region!r}, expected {expect.region!r}")
            if not isinstance(schema_version, int):
                failures.append(f"metadata schema_version {schema_version!r} is not an integer")
        rows: dict[str, int] = {}
        for table in expect.count_tables:
            rows[table] = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            wanted = expect.row_ranges.get(table)
            if wanted is not None and not (wanted.min <= rows[table] <= wanted.max):
                failures.append(f"{table} has {rows[table]} rows, expected {wanted.min}..{wanted.max}")
            elif rows[table] == 0:
                log.warning("%s: %s has zero rows", path.name, table)
    finally:
        conn.close()
    if failures:
        raise ValidationError(f"{path.name}: " + "; ".join(failures))
    return OutputInfo(
        file=path.name, bytes=size, sha256=sha256(path), tile_type=None, min_zoom=None, max_zoom=None,
        tiles=None, compression=None, attribution=attribution, source_data_date=osm_timestamp,
        source=None, metadata={}, rows=rows,
    )
```

with `log = logging.getLogger("maqs.validate")`, and `validate_output` becoming:

```python
def validate_output(path: Path, expect: Expectation | SqliteExpectation) -> OutputInfo:
    if isinstance(expect, SqliteExpectation):
        return validate_sqlite(path, expect)
    return validate_pmtiles(path, expect)
```

where `validate_pmtiles` is the existing body renamed. Keep the existing tests green (`OutputInfo` positional constructions in tests gain nothing: `rows` is last with a default).

- [ ] **Step 5: Change the step protocol, runner, tile steps and report**

`steps/base.py`:

```python
MAX_REPORTED_ANOMALIES = 1000


@dataclass(frozen=True)
class Anomaly:
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
```

In `run_step`: `outcome = step.build(ctx)`; `command = outcome.command`; after a build, `anomalies = outcome.anomalies[:MAX_REPORTED_ANOMALIES]`, `anomaly_count = len(outcome.anomalies)`; validation calls `step.expectation(ctx, path)` per output; every `StepResult(...)` return passes `anomalies`/`anomaly_count` (empty on skip). In `steps/tiles.py` and `steps/terrain_hd.py`, `build` returns `StepOutcome(argv)` and `expectation(self, ctx, output)` takes the extra argument (unused). In `report.py`, the output dict drops `rows` when it is `None` (`if d["rows"] is None: d.pop("rows")`) and the step dict gains `"anomalies": [asdict(a) for a in r.anomalies], "anomaly_count": r.anomaly_count`.

- [ ] **Step 6: Run the whole suite**

Run: `uv run pytest -q`
Expected: all pass, including the updated tile-step tests and the CLI tests (which only look at the report). Then the real test-region tile build still works: `uv run maqs build --region test --layers basemap,terrain --dist <scratch>/dist --force` exits 0.

- [ ] **Step 7: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src pipeline/tests
git commit -m "feat(pipeline): SQLite schemas and writer, SQLite validation, step outcomes with anomalies"
```

---

### Task 6: Trail record and the OSM adapter

**Files:**
- Create: `pipeline/src/maqs/trails/__init__.py`, `pipeline/src/maqs/trails/model.py`, `pipeline/src/maqs/trails/sources/__init__.py`, `pipeline/src/maqs/trails/sources/osm.py`, `pipeline/tests/osm_fixtures.py`, `pipeline/tests/test_trails_osm.py`

**Interfaces:**
- Consumes: `Coord`, `line_length_m`, `bbox_of`, `haversine_m` (Task 1); `Anomaly` (Task 5).
- Produces:
  - `model.py`: `@dataclass TrailRecord(source: str, source_id: str, source_licence: str | None, source_date: str | None, osm_type: str | None, osm_id: int | None, ref: str | None, ref_rei: str | None, name: str | None, difficulty: int | None, difficulty_scheme: str | None, difficulty_value: str | None, network: str | None, operator: str | None, osmc_symbol: str | None, from_name: str | None, to_name: str | None, roundtrip: int | None, survey_date: str | None, website: str | None, legs: list[list[Coord]], geometry_status: str, anomalies: list[Anomaly], ascent_m: float | None = None, descent_m: float | None = None, secondary_of: int | None = None)` with properties `length_m -> float`, `bbox -> tuple[float, float, float, float] | None`, `coords -> list[Coord]` (legs concatenated); `GEOMETRY_STATUSES = ("ordered", "gaps", "incomplete")`.
  - `sources/osm.py`: `OSM_LICENCE = "ODbL 1.0"`; `CAI_SCALE: dict[str, int]`, `SAC_SCALE: dict[str, int]`; `normalise_difficulty(cai: str | None, sac: str | None, way_sacs: Sequence[str]) -> tuple[int | None, str | None, str | None, str | None]` (difficulty, scheme, original value, anomaly message or None); `normalise_operator(value: str | None) -> str | None`; `@dataclass WayGeom(id: int, nodes: list[int], coords: list[Coord], tags: dict[str, str])`; `assemble(members: Sequence[tuple[int, str]], ways: dict[int, WayGeom]) -> tuple[list[list[Coord]], str, list[Anomaly]]`; `read_osm_trails(hiking_pbf: Path, *, source_date: str | None) -> list[TrailRecord]`.
  - `tests/osm_fixtures.py`: `write_osm(path: Path, nodes: dict[int, Coord], ways: dict[int, tuple[list[int], dict[str, str]]], relations: dict[int, tuple[list[tuple[str, int, str]], dict[str, str]]]) -> Path` (pyosmium `SimpleWriter`, ids ascending, nodes before ways before relations).

- [ ] **Step 1: Write the fixture writer and the failing tests**

```python
# pipeline/tests/osm_fixtures.py
"""Tiny OSM PBF files for tests, written with pyosmium. Objects are written in the order
osmium expects: nodes, ways, relations, each by ascending id."""

from __future__ import annotations

from pathlib import Path

import osmium
import osmium.osm.mutable as mutable

Coord = tuple[float, float]


def write_osm(
    path: Path,
    nodes: dict[int, Coord],
    ways: dict[int, tuple[list[int], dict[str, str]]],
    relations: dict[int, tuple[list[tuple[str, int, str]], dict[str, str]]],
) -> Path:
    with osmium.SimpleWriter(str(path), overwrite=True) as writer:
        for nid in sorted(nodes):
            writer.add_node(mutable.Node(id=nid, location=nodes[nid]))
        for wid in sorted(ways):
            node_ids, tags = ways[wid]
            writer.add_way(mutable.Way(id=wid, nodes=node_ids, tags=tags))
        for rid in sorted(relations):
            members, tags = relations[rid]
            writer.add_relation(mutable.Relation(id=rid, members=members, tags=tags))
    return path
```

```python
# pipeline/tests/test_trails_osm.py
import pytest

from maqs.steps.base import Anomaly
from maqs.trails.sources.osm import OSM_LICENCE, WayGeom, assemble, normalise_difficulty, normalise_operator, read_osm_trails
from tests.osm_fixtures import write_osm

P = {1: (12.250, 46.100), 2: (12.251, 46.101), 3: (12.252, 46.102), 4: (12.253, 46.103), 5: (12.260, 46.110), 6: (12.270, 46.120), 7: (12.271, 46.121)}


def way(wid, nodes, **tags):
    return WayGeom(wid, nodes, [P[n] for n in nodes], tags)


def test_assemble_orders_and_reverses_ways():
    ways = {10: way(10, [1, 2, 3]), 11: way(11, [4, 3]), 12: way(12, [5, 4])}
    legs, status, anomalies = assemble([(10, ""), (11, ""), (12, "")], ways)
    assert status == "ordered" and len(legs) == 1
    assert legs[0] == [P[1], P[2], P[3], P[4], P[5]]
    assert [a.kind for a in anomalies] == ["reversed", "reversed"] and anomalies[0].id == "way/11"


def test_assemble_prepends_when_a_way_joins_the_start():
    ways = {10: way(10, [3, 4, 5]), 11: way(11, [1, 2, 3])}
    legs, status, _ = assemble([(10, ""), (11, "")], ways)
    assert status == "ordered" and legs == [[P[1], P[2], P[3], P[4], P[5]]]


def test_assemble_reports_gaps_with_distance():
    ways = {10: way(10, [1, 2]), 11: way(11, [6, 7])}
    legs, status, anomalies = assemble([(10, ""), (11, "")], ways)
    assert status == "gaps" and len(legs) == 2
    (gap,) = [a for a in anomalies if a.kind == "gap"]
    assert gap.id == "way/11" and "gap of 2" in gap.message and gap.message.endswith("before this way")  # ~2.6 km


def test_assemble_flags_missing_member_but_keeps_the_rest():
    ways = {10: way(10, [1, 2, 3])}
    legs, status, anomalies = assemble([(10, ""), (99, "")], ways)
    assert status == "incomplete" and legs == [[P[1], P[2], P[3]]]
    assert Anomaly("missing_member", "way/99", "member way not in the extract") in anomalies


def test_assemble_flags_special_roles_but_keeps_them():
    ways = {10: way(10, [1, 2, 3]), 11: way(11, [3, 4])}
    legs, status, anomalies = assemble([(10, ""), (11, "alternative")], ways)
    assert status == "ordered" and legs[0][-1] == P[4]
    assert Anomaly("role", "way/11", "member role 'alternative' kept in the main geometry") in anomalies


def test_assemble_with_no_usable_ways():
    legs, status, anomalies = assemble([(99, "")], {})
    assert legs == [] and status == "incomplete" and anomalies[0].kind == "missing_member"


@pytest.mark.parametrize(
    "cai, sac, way_sacs, expected",
    [
        ("E", None, [], (2, "cai_scale", "E", None)),
        ("eea:pd", None, [], (5, "cai_scale", "eea:pd", None)),
        ("EEA:ED", "hiking", [], (6, "cai_scale", "EEA:ED", None)),
        (None, "demanding_mountain_hiking", [], (3, "sac_scale", "demanding_mountain_hiking", None)),
        (None, None, ["hiking", "alpine_hiking", "mountain_hiking"], (4, "sac_scale:ways", "alpine_hiking", None)),
        (None, None, [], (None, None, None, None)),
        ("X", None, [], (None, "cai_scale", "X", "unknown cai_scale 'X'")),
        (None, "strolling", [], (None, "sac_scale", "strolling", "unknown sac_scale 'strolling'")),
    ],
)
def test_normalise_difficulty(cai, sac, way_sacs, expected):
    assert normalise_difficulty(cai, sac, way_sacs) == expected


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("Alpenverein Südtirol", "Alpenverein Südtirol"),
        ("AVS", "Alpenverein Südtirol"),
        ("alpenverein suedtirol", "Alpenverein Südtirol"),
        ("Alpenverein Sudtirol - Sektion Bozen", "Alpenverein Südtirol"),
        ("  CAI Belluno ", "CAI Belluno"),
        (None, None),
    ],
)
def test_normalise_operator(raw, expected):
    assert normalise_operator(raw) == expected


@pytest.fixture
def hiking_pbf(tmp_path):
    nodes = {1: P[1], 2: P[2], 3: P[3], 4: P[4], 5: P[5], 6: P[6], 7: P[7]}
    ways = {
        10: ([1, 2, 3], {"highway": "path", "sac_scale": "mountain_hiking"}),
        11: ([4, 3], {"highway": "path", "sac_scale": "alpine_hiking"}),
        12: ([5, 4], {"highway": "path"}),
        20: ([6, 7], {"highway": "path"}),
        30: ([1, 2], {"highway": "track"}),
    }
    relations = {
        100: ([("w", 10, ""), ("w", 11, ""), ("w", 12, "")],
              {"type": "route", "route": "hiking", "ref": "501", "ref:REI": "VE501", "name": "Alta Via", "cai_scale": "E",
               "network": "lwn", "operator": "avs", "osmc:symbol": "red:white:red_bar", "from": "Nevegal", "to": "Col Visentin",
               "roundtrip": "no", "survey:date": "2025-06-01", "website": "https://example.org"}),
        101: ([("w", 20, ""), ("w", 99, "")], {"type": "route", "route": "hiking", "ref": "502"}),  # 99 is missing
        102: ([("w", 10, ""), ("w", 11, "")], {"type": "route", "route": "hiking", "name": "No scale"}),  # difficulty from ways
        200: ([("w", 30, "")], {"type": "route", "route": "bicycle", "ref": "B1"}),  # ignored
    }
    return write_osm(tmp_path / "hiking.osm.pbf", nodes, ways, relations)


def test_read_osm_trails_maps_tags_and_geometry(hiking_pbf):
    records = {r.osm_id: r for r in read_osm_trails(hiking_pbf, source_date="2026-10-06T20:21:06Z")}
    assert set(records) == {100, 101, 102}
    r = records[100]
    assert (r.source, r.source_id, r.source_licence, r.source_date, r.osm_type) == ("osm", "relation/100", OSM_LICENCE, "2026-10-06T20:21:06Z", "relation")
    assert (r.ref, r.ref_rei, r.name, r.network, r.osmc_symbol) == ("501", "VE501", "Alta Via", "lwn", "red:white:red_bar")
    assert (r.difficulty, r.difficulty_scheme, r.difficulty_value) == (2, "cai_scale", "E")
    assert r.operator == "Alpenverein Südtirol"
    assert (r.from_name, r.to_name, r.roundtrip, r.survey_date, r.website) == ("Nevegal", "Col Visentin", 0, "2025-06-01", "https://example.org")
    assert r.geometry_status == "ordered" and r.legs == [[P[1], P[2], P[3], P[4], P[5]]]
    assert r.length_m == pytest.approx(1353, abs=20) and r.bbox == (12.25, 46.1, 12.26, 46.11)
    assert records[101].geometry_status == "incomplete" and records[101].legs == [[P[6], P[7]]]
    assert any(a.kind == "missing_member" and a.id == "way/99" for a in records[101].anomalies)
    assert (records[102].difficulty, records[102].difficulty_scheme, records[102].difficulty_value) == (4, "sac_scale:ways", "alpine_hiking")
    assert records[102].roundtrip is None and records[102].ref is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_trails_osm.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.trails'`

- [ ] **Step 3: Implement `model.py`**

```python
# pipeline/src/maqs/trails/__init__.py
```

```python
# pipeline/src/maqs/trails/sources/__init__.py
```

```python
# pipeline/src/maqs/trails/model.py
"""The normalised trail record every source adapter emits (ADR 0006)."""

from __future__ import annotations

from dataclasses import dataclass, field

from maqs.geometry import Coord, bbox_of, line_length_m
from maqs.steps.base import Anomaly

GEOMETRY_STATUSES = ("ordered", "gaps", "incomplete")


@dataclass
class TrailRecord:
    source: str
    source_id: str
    source_licence: str | None
    source_date: str | None
    osm_type: str | None
    osm_id: int | None
    ref: str | None
    ref_rei: str | None
    name: str | None
    difficulty: int | None
    difficulty_scheme: str | None
    difficulty_value: str | None
    network: str | None
    operator: str | None
    osmc_symbol: str | None
    from_name: str | None
    to_name: str | None
    roundtrip: int | None
    survey_date: str | None
    website: str | None
    legs: list[list[Coord]]
    geometry_status: str
    anomalies: list[Anomaly] = field(default_factory=list)
    ascent_m: float | None = None
    descent_m: float | None = None
    secondary_of: int | None = None

    @property
    def coords(self) -> list[Coord]:
        return [c for leg in self.legs for c in leg]

    @property
    def length_m(self) -> float:
        return sum(line_length_m(leg) for leg in self.legs)

    @property
    def bbox(self) -> tuple[float, float, float, float] | None:
        coords = self.coords
        return bbox_of(coords) if coords else None
```

- [ ] **Step 4: Implement `sources/osm.py`**

```python
# pipeline/src/maqs/trails/sources/osm.py
"""Adapter 1: OSM route=hiking relations, assembled from member ways by our own code.

osmium export cannot assemble route relations, so the ordering is done here: ways are chained
by shared end nodes, reversed when needed, and every irregularity becomes an anomaly in the
build report. Nothing is dropped (brief item 4, ADR 0006).
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import osmium

from maqs.geometry import Coord, haversine_m
from maqs.steps.base import Anomaly
from maqs.trails.model import TrailRecord

OSM_LICENCE = "ODbL 1.0"

CAI_SCALE: dict[str, int] = {
    "T": 1, "E": 2, "EE": 3, "EEA": 4, "EEA:F": 4, "EEA:PD": 5, "EEA:D": 6, "EEA:MD": 6, "EEA:ED": 6, "EAI": 3,
}
SAC_SCALE: dict[str, int] = {
    "hiking": 1, "mountain_hiking": 2, "demanding_mountain_hiking": 3,
    "alpine_hiking": 4, "demanding_alpine_hiking": 5, "difficult_alpine_hiking": 6,
}
FLAGGED_ROLES = frozenset({"alternative", "excursion", "connection"})
_AVS_RE = re.compile(r"alpenverein\s*s(ü|ue|u)dtirol|^avs$", re.IGNORECASE)


def normalise_difficulty(
    cai: str | None, sac: str | None, way_sacs: Sequence[str]
) -> tuple[int | None, str | None, str | None, str | None]:
    if cai:
        value = cai.strip()
        level = CAI_SCALE.get(value.upper())
        return level, "cai_scale", value, None if level else f"unknown cai_scale {value!r}"
    if sac:
        value = sac.strip()
        level = SAC_SCALE.get(value)
        return level, "sac_scale", value, None if level else f"unknown sac_scale {value!r}"
    known = [(SAC_SCALE[s], s) for s in way_sacs if s in SAC_SCALE]
    if known:
        level, value = max(known)
        return level, "sac_scale:ways", value, None
    return None, None, None, None


def normalise_operator(value: str | None) -> str | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    return "Alpenverein Südtirol" if _AVS_RE.search(text) else text


@dataclass
class WayGeom:
    id: int
    nodes: list[int]
    coords: list[Coord]
    tags: dict[str, str]


def assemble(members: Sequence[tuple[int, str]], ways: dict[int, WayGeom]) -> tuple[list[list[Coord]], str, list[Anomaly]]:
    anomalies: list[Anomaly] = []
    unused: list[int] = []
    missing = False
    for wid, role in members:
        if wid not in ways or len(ways[wid].nodes) < 2:
            anomalies.append(Anomaly("missing_member", f"way/{wid}", "member way not in the extract"))
            missing = True
            continue
        if role in FLAGGED_ROLES:
            anomalies.append(Anomaly("role", f"way/{wid}", f"member role {role!r} kept in the main geometry"))
        if wid not in unused:
            unused.append(wid)
    legs: list[list[Coord]] = []
    leg_ways: list[list[int]] = []  # way ids per leg, in leg order, for the gap anomalies
    while unused:
        first_id = unused.pop(0)
        first = ways[first_id]
        nodes, coords, wids = list(first.nodes), list(first.coords), [first_id]
        extended = True
        while extended:
            extended = False
            for wid in list(unused):
                w = ways[wid]
                if w.nodes[0] == nodes[-1]:
                    nodes, coords, wids = nodes + w.nodes[1:], coords + w.coords[1:], wids + [wid]
                elif w.nodes[-1] == nodes[-1]:
                    nodes, coords, wids = nodes + w.nodes[-2::-1], coords + w.coords[-2::-1], wids + [wid]
                    anomalies.append(Anomaly("reversed", f"way/{wid}", "member way runs against the route direction"))
                elif w.nodes[-1] == nodes[0]:
                    nodes, coords, wids = w.nodes[:-1] + nodes, w.coords[:-1] + coords, [wid] + wids
                elif w.nodes[0] == nodes[0]:
                    nodes, coords, wids = w.nodes[:0:-1] + nodes, w.coords[:0:-1] + coords, [wid] + wids
                    anomalies.append(Anomaly("reversed", f"way/{wid}", "member way runs against the route direction"))
                else:
                    continue
                unused.remove(wid)
                extended = True
        legs.append(coords)
        leg_ways.append(wids)
    for i in range(1, len(legs)):
        gap = haversine_m(legs[i - 1][-1], legs[i][0])
        anomalies.append(Anomaly("gap", f"way/{leg_ways[i][0]}", f"gap of {gap:.0f} m before this way"))
    status = "incomplete" if missing else ("gaps" if len(legs) > 1 else "ordered")
    return legs, status, anomalies


def _yes_no(value: str | None) -> int | None:
    if value is None:
        return None
    return {"yes": 1, "true": 1, "1": 1, "no": 0, "false": 0, "0": 0}.get(value.strip().lower())


def read_osm_trails(hiking_pbf: Path, *, source_date: str | None) -> list[TrailRecord]:
    relations: dict[int, tuple[dict[str, str], list[tuple[int, str]]]] = {}
    processor = osmium.FileProcessor(str(hiking_pbf), osmium.osm.RELATION).with_filter(osmium.filter.TagFilter(("route", "hiking")))
    for rel in processor:
        members = [(m.ref, m.role) for m in rel.members if m.type in ("w", "way")]
        relations[rel.id] = (dict(rel.tags), members)
    way_ids = {wid for _, members in relations.values() for wid, _ in members}
    ways: dict[int, WayGeom] = {}
    if way_ids:
        processor = osmium.FileProcessor(str(hiking_pbf)).with_locations().with_filter(
            osmium.filter.IdFilter(way_ids).enable_for(osmium.osm.WAY)
        )
        for obj in processor:
            if obj.is_way():
                located = [n for n in obj.nodes if n.location.valid()]
                ways[obj.id] = WayGeom(obj.id, [n.ref for n in located], [(n.lon, n.lat) for n in located], dict(obj.tags))
    records: list[TrailRecord] = []
    for rid in sorted(relations):
        tags, members = relations[rid]
        legs, status, anomalies = assemble(members, ways)
        way_sacs = [ways[wid].tags["sac_scale"] for wid, _ in members if wid in ways and "sac_scale" in ways[wid].tags]
        difficulty, scheme, value, problem = normalise_difficulty(tags.get("cai_scale"), tags.get("sac_scale"), way_sacs)
        if problem:
            anomalies.append(Anomaly("difficulty", f"relation/{rid}", problem))
        records.append(
            TrailRecord(
                source="osm", source_id=f"relation/{rid}", source_licence=OSM_LICENCE, source_date=source_date,
                osm_type="relation", osm_id=rid,
                ref=tags.get("ref"), ref_rei=tags.get("ref:REI"), name=tags.get("name"),
                difficulty=difficulty, difficulty_scheme=scheme, difficulty_value=value,
                network=tags.get("network"), operator=normalise_operator(tags.get("operator")), osmc_symbol=tags.get("osmc:symbol"),
                from_name=tags.get("from"), to_name=tags.get("to"), roundtrip=_yes_no(tags.get("roundtrip")),
                survey_date=tags.get("survey:date"), website=tags.get("website"),
                legs=legs, geometry_status=status, anomalies=anomalies,
            )
        )
    return records
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_trails_osm.py -q`
Expected: all pass. If `member.type` is `"way"` rather than `"w"` in this pyosmium build, the `in ("w", "way")` check covers both.

- [ ] **Step 6: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/trails pipeline/tests/osm_fixtures.py pipeline/tests/test_trails_osm.py
git commit -m "feat(pipeline): trail record and the OSM hiking-relation adapter"
```

---

### Task 7: Trail merge across sources

**Files:**
- Create: `pipeline/src/maqs/trails/merge.py`, `pipeline/tests/test_trails_merge.py`

**Interfaces:**
- Consumes: `TrailRecord`, `resample`, `haversine_m`.
- Produces: `merge(sources: Sequence[tuple[str, list[TrailRecord]]], *, overlap_m: float = 50.0, min_share: float = 0.5, step_m: float = 25.0) -> list[TrailRecord]` — records in output order, primaries first in source priority order, secondaries after them with `secondary_of` set to the **index** of their winner in the returned list; `normalise_ref(ref: str | None) -> str | None`; `overlap_share(candidate: Sequence[Coord], winner: Sequence[Coord], *, overlap_m, step_m) -> float`.

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_trails_merge.py
import pytest

from maqs.trails.merge import merge, normalise_ref, overlap_share
from maqs.trails.model import TrailRecord


def record(source, ref, legs, name=None):
    return TrailRecord(
        source=source, source_id=f"{source}/{ref or name}", source_licence=None, source_date=None, osm_type=None, osm_id=None,
        ref=ref, ref_rei=None, name=name, difficulty=None, difficulty_scheme=None, difficulty_value=None, network=None,
        operator=None, osmc_symbol=None, from_name=None, to_name=None, roundtrip=None, survey_date=None, website=None,
        legs=legs, geometry_status="ordered",
    )


A = [[(12.25, 46.10), (12.26, 46.10), (12.27, 46.10)]]            # ~1.5 km, E-W
A_SHIFTED = [[(12.25, 46.1002), (12.27, 46.1002)]]                # 22 m north of A
FAR = [[(12.25, 46.20), (12.27, 46.20)]]


def test_normalise_ref():
    assert normalise_ref(" 501 ") == "501" and normalise_ref("cai 501") == "CAI 501" and normalise_ref(None) is None


def test_overlap_share():
    assert overlap_share(A_SHIFTED[0], A[0], overlap_m=50.0, step_m=25.0) == pytest.approx(1.0)
    assert overlap_share(FAR[0], A[0], overlap_m=50.0, step_m=25.0) == 0.0


def test_same_ref_overlapping_becomes_secondary_of_the_higher_priority_source():
    out = merge([("osm", [record("osm", "501", A)]), ("synthetic", [record("synthetic", "501", A_SHIFTED)])])
    assert [r.source for r in out] == ["osm", "synthetic"]
    assert out[0].secondary_of is None and out[1].secondary_of == 0


def test_priority_order_decides_the_winner():
    out = merge([("synthetic", [record("synthetic", "501", A_SHIFTED)]), ("osm", [record("osm", "501", A)])])
    assert out[0].source == "synthetic" and out[1].secondary_of == 0


def test_same_ref_far_apart_stays_separate():
    out = merge([("osm", [record("osm", "501", A)]), ("synthetic", [record("synthetic", "501", FAR)])])
    assert all(r.secondary_of is None for r in out) and len(out) == 2


def test_different_ref_or_no_ref_never_merges():
    out = merge([("osm", [record("osm", "501", A), record("osm", None, A, name="x")]), ("synthetic", [record("synthetic", "502", A_SHIFTED), record("synthetic", None, A_SHIFTED, name="y")])])
    assert all(r.secondary_of is None for r in out) and len(out) == 4


def test_single_source_is_unchanged():
    records = [record("osm", "501", A), record("osm", "502", FAR)]
    assert merge([("osm", records)]) == records
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_trails_merge.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.trails.merge'`

- [ ] **Step 3: Implement**

```python
# pipeline/src/maqs/trails/merge.py
"""Merge trail records from several sources by priority (ADR 0006).

A lower-priority record with the same ref as a higher-priority one, whose geometry mostly
lies within overlap_m of it, becomes a secondary reference pointing at the winner. Today the
only real source is OSM; the seam is exercised with a synthetic second source in tests.
"""

from __future__ import annotations

from collections.abc import Sequence

from maqs.geometry import Coord, haversine_m, resample
from maqs.trails.model import TrailRecord


def normalise_ref(ref: str | None) -> str | None:
    if ref is None:
        return None
    text = " ".join(ref.split()).upper()
    return text or None


def overlap_share(candidate: Sequence[Coord], winner: Sequence[Coord], *, overlap_m: float, step_m: float) -> float:
    if len(candidate) < 2 or len(winner) < 2:
        return 0.0
    winner_points = resample(winner, step_m)
    tolerance = overlap_m + step_m / 2
    points = resample(candidate, step_m)
    near = sum(1 for p in points if any(haversine_m(p, w) <= tolerance for w in winner_points))
    return near / len(points)


def merge(
    sources: Sequence[tuple[str, list[TrailRecord]]],
    *,
    overlap_m: float = 50.0,
    min_share: float = 0.5,
    step_m: float = 25.0,
) -> list[TrailRecord]:
    primaries: list[TrailRecord] = []
    by_ref: dict[str, list[int]] = {}
    secondaries: list[TrailRecord] = []
    for _, records in sources:
        for record in records:
            key = normalise_ref(record.ref)
            winner_index = None
            if key is not None:
                for index in by_ref.get(key, []):
                    winner = primaries[index]
                    for leg in record.legs:
                        if overlap_share(leg, winner.coords, overlap_m=overlap_m, step_m=step_m) >= min_share:
                            winner_index = index
                            break
                    if winner_index is not None:
                        break
            if winner_index is None:
                primaries.append(record)
                if key is not None:
                    by_ref.setdefault(key, []).append(len(primaries) - 1)
            else:
                record.secondary_of = winner_index
                secondaries.append(record)
    return primaries + secondaries
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_trails_merge.py -q`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/trails/merge.py pipeline/tests/test_trails_merge.py
git commit -m "feat(pipeline): merge trails across sources by ref and overlap"
```

---

### Task 8: The trails step

**Files:**
- Create: `pipeline/src/maqs/overlay.py`, `pipeline/src/maqs/trails/step.py`, `pipeline/tests/test_steps_trails.py`

**Interfaces:**
- Consumes: `extract.region_hiking_pbf`, `extract.geofabrik_pbf`, `extract.osm_timestamp` (Task 3); `read_osm_trails` (Task 6); `merge` (Task 7); `TerrainSampler`, `ascent_descent` (Task 4); `write_sqlite`, `Metadata`, `TABLES`, `COUNT_TABLES` (Task 5); `encode_polyline`; `SqliteExpectation`, `Expectation`, `StepOutcome`, `Anomaly`; `tools.run`, `tools.find_tool`.
- Produces: `class TrailsStep` (`name = "trails"`): `outputs(ctx) -> [<out_dir>/<label>-trails.sqlite, <out_dir>/<label>-trails.pmtiles]`; `expectation(ctx, output)`; `build(ctx) -> StepOutcome` (command = the tippecanoe argv); `TRAILS_MIN_ZOOM = 6`, `TRAILS_MAX_ZOOM = 14`; `trail_row(record: TrailRecord, trail_id: int, winner_id: int | None) -> tuple`; `trail_feature(record: TrailRecord, trail_id: int) -> dict`; `tippecanoe_argv(src: Path, out: Path, layer: str, min_zoom: int, max_zoom: int) -> list[str]` (shared with places: put it in `maqs/overlay.py`).

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_steps_trails.py
import json
import subprocess
from pathlib import Path

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.geometry import decode_polyline
from maqs.osm import extract
from maqs.sqlite_out import open_readonly
from maqs.steps.base import run_step
from maqs.trails.step import TrailsStep
from maqs.validate import SqliteExpectation
from tests.helpers import write_pmtiles
from tests.osm_fixtures import write_osm
from tests.test_terrain_sampler import terrarium_tile
from maqs.pmtiles_reader import zxy_to_tile_id

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"
P = {1: (12.250, 46.100), 2: (12.251, 46.101), 3: (12.252, 46.102), 4: (12.253, 46.103), 5: (12.260, 46.110)}


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("test"))


@pytest.fixture
def hiking(tmp_path):
    return write_osm(
        tmp_path / "hiking.osm.pbf",
        {k: P[k] for k in P},
        {10: ([1, 2, 3], {"highway": "path"}), 11: ([3, 4, 5], {"highway": "path"})},
        {100: ([("w", 10, ""), ("w", 11, "")], {"type": "route", "route": "hiking", "ref": "501", "name": "Alta Via", "cai_scale": "E"}),
         101: ([("w", 10, ""), ("w", 99, "")], {"type": "route", "route": "hiking", "ref": "502"})},
    )


@pytest.fixture
def stubs(ctx, hiking, monkeypatch):
    monkeypatch.setattr(extract, "region_hiking_pbf", lambda c: hiking)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: hiking)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/usr/bin/{name}"))
    calls = {}

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        calls["argv"] = argv
        src = Path(argv[-1])
        calls["features"] = [json.loads(line) for line in src.read_text().splitlines() if line.strip()]
        out = Path(argv[argv.index("-o") + 1])
        write_pmtiles(out, tile_type=1, min_zoom=6, max_zoom=14)
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(tools, "run", fake_run)
    return calls


def test_outputs_and_expectations(ctx):
    step = TrailsStep()
    sqlite, pmtiles = step.outputs(ctx)
    assert sqlite == ctx.dist / "test" / "test-trails.sqlite" and pmtiles == ctx.dist / "test" / "test-trails.pmtiles"
    e = step.expectation(ctx, sqlite)
    assert isinstance(e, SqliteExpectation) and e.layer == "trails" and e.region == "test" and e.row_ranges == {}
    e2 = step.expectation(ctx, pmtiles)
    assert (e2.min_zoom, e2.max_zoom) == (6, 14) and e2.tile_types == frozenset({"mvt"})


def test_expectation_carries_the_region_row_range(ctx):
    cfg = ctx.config
    veneto = BuildContext(config=cfg, dist=ctx.dist, cache=ctx.cache, force=False, region=cfg.region("veneto"))
    e = TrailsStep().expectation(veneto, veneto.out_dir / "veneto-trails.sqlite")
    assert e.row_ranges["trails"].min == 1500


def test_build_writes_sqlite_overlay_and_anomalies(ctx, stubs):
    result = run_step(TrailsStep(), ctx)
    assert result.status == "built", result.error
    assert result.command == stubs["argv"]
    assert stubs["argv"][:2] == ["/usr/bin/tippecanoe", "-o"] and "-l" in stubs["argv"] and "-Z6" in stubs["argv"] and "-z14" in stubs["argv"]
    conn = open_readonly(ctx.out_dir / "test-trails.sqlite")
    rows = conn.execute("SELECT id, ref, name, difficulty, geometry_status, length_m, ascent_m, geometry FROM trails ORDER BY id").fetchall()
    assert [(r[1], r[3], r[4]) for r in rows] == [("501", 2, "ordered"), ("502", None, "incomplete")]
    assert decode_polyline(rows[0][7])[0] == pytest.approx(P[1], abs=1e-6) and rows[0][5] > 1000
    assert rows[0][6] is None  # no terrain archive in this build
    assert conn.execute("SELECT rowid FROM trails_fts WHERE trails_fts MATCH 'alta'").fetchall() == [(1,)]
    assert conn.execute("SELECT count(*) FROM trails_rtree").fetchone() == (2,)
    kinds = {a.kind for a in result.anomalies}
    assert {"missing_member", "terrain_missing"} <= kinds
    assert [f["properties"]["ref"] for f in stubs["features"]] == ["501", "502"]
    assert stubs["features"][0]["geometry"]["type"] == "LineString" and stubs["features"][0]["properties"]["id"] == 1
    assert result.outputs[0].rows == {"trails": 2} and result.outputs[1].tile_type == "mvt"


def test_build_computes_ascent_from_the_terrain_archive(ctx, stubs):
    ctx.out_dir.mkdir(parents=True)
    tile = terrarium_tile(lambda px, py: 1000.0 + 2.0 * px)  # 2 m per pixel eastwards
    write_pmtiles(ctx.out_dir / "test-terrain.pmtiles", tile_type=4, min_zoom=0, max_zoom=12, tile_compression=1,
                  tile=tile, tile_id=zxy_to_tile_id(12, 2187, 1455))
    result = run_step(TrailsStep(), ctx)
    assert result.status == "built", result.error
    conn = open_readonly(ctx.out_dir / "test-trails.sqlite")
    ascent, descent = conn.execute("SELECT ascent_m, descent_m FROM trails WHERE ref = '501'").fetchone()
    assert ascent is not None and ascent > 0 and descent == 0.0  # the trail runs east, uphill on this tile
    assert "terrain_missing" not in {a.kind for a in result.anomalies}


def test_secondary_rows_point_at_their_winner(ctx, stubs):
    cfg = ctx.config
    # pretend the region lists the osm source twice: the second copy must become secondary rows
    region = cfg.region("test").__class__(**{**cfg.region("test").__dict__, "trail_sources": ("osm", "osm")})
    ctx2 = BuildContext(config=cfg, dist=ctx.dist, cache=ctx.cache, force=False, region=region)
    result = run_step(TrailsStep(), ctx2)
    assert result.status == "built", result.error
    conn = open_readonly(ctx2.out_dir / "test-trails.sqlite")
    assert conn.execute("SELECT count(*) FROM trails WHERE secondary_of IS NOT NULL").fetchone() == (2,)
    assert conn.execute("SELECT secondary_of FROM trails WHERE id = 3").fetchone() == (1,)
    assert len(stubs["features"]) == 2  # overlays carry primaries only
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_steps_trails.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.trails.step'`

- [ ] **Step 3: Implement `overlay.py` and `trails/step.py`**

```python
# pipeline/src/maqs/overlay.py
"""tippecanoe overlays: GeoJSONSeq in, gzip MVT PMTiles out."""

from __future__ import annotations

import json
from collections.abc import Iterable
from pathlib import Path

from maqs import tools


def tippecanoe_argv(src: Path, out: Path, layer: str, min_zoom: int, max_zoom: int) -> list[str]:
    return [
        str(tools.find_tool("tippecanoe")), "-o", str(out), "-f", "-q", "-l", layer,
        f"-Z{min_zoom}", f"-z{max_zoom}", str(src),
    ]


def write_geojsonseq(features: Iterable[dict], path: Path) -> int:
    count = 0
    with path.open("w", encoding="utf-8") as f:
        for feature in features:
            f.write(json.dumps(feature, ensure_ascii=False, separators=(",", ":")) + "\n")
            count += 1
    return count


def build_overlay(features: Iterable[dict], out: Path, layer: str, min_zoom: int, max_zoom: int) -> list[str]:
    src = out.with_suffix(".geojsonseq")
    try:
        write_geojsonseq(features, src)
        argv = tippecanoe_argv(src, out, layer, min_zoom, max_zoom)
        tools.run(argv)
    finally:
        src.unlink(missing_ok=True)
    return argv
```

```python
# pipeline/src/maqs/trails/step.py
"""The trails layer: SQLite index plus a vector overlay, from the region's hiking extract."""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime
from pathlib import Path

from maqs.context import BuildContext
from maqs.geometry import encode_polyline
from maqs.osm import extract
from maqs.osm.terrain_sampler import TerrainSampler, ascent_descent
from maqs.overlay import build_overlay
from maqs.sqlite_out import COUNT_TABLES, TABLES, Metadata, write_sqlite
from maqs.steps.base import Anomaly, StepOutcome
from maqs.trails.merge import merge
from maqs.trails.model import TrailRecord
from maqs.trails.sources.osm import read_osm_trails
from maqs.validate import Expectation, SqliteExpectation

TRAILS_MIN_ZOOM = 6
TRAILS_MAX_ZOOM = 14


def trail_row(record: TrailRecord, trail_id: int, winner_id: int | None) -> tuple:
    bbox = record.bbox or (None, None, None, None)
    return (
        trail_id, record.source, record.source_id, record.source_licence, record.source_date,
        record.osm_type, record.osm_id, record.ref, record.ref_rei, record.name,
        record.difficulty, record.difficulty_scheme, record.difficulty_value,
        record.network, record.operator, record.osmc_symbol, record.from_name, record.to_name, record.roundtrip,
        record.survey_date, record.website,
        record.length_m, record.ascent_m, record.descent_m,
        *bbox,
        "|".join(encode_polyline(leg) for leg in record.legs), record.geometry_status, winner_id,
    )


def trail_feature(record: TrailRecord, trail_id: int) -> dict:
    legs = [[list(c) for c in leg] for leg in record.legs]
    geometry = {"type": "LineString", "coordinates": legs[0]} if len(legs) == 1 else {"type": "MultiLineString", "coordinates": legs}
    properties = {
        "id": trail_id, "ref": record.ref, "name": record.name, "difficulty": record.difficulty,
        "network": record.network, "osmc_symbol": record.osmc_symbol,
    }
    return {"type": "Feature", "properties": properties, "geometry": geometry}


class TrailsStep:
    name = "trails"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-trails.sqlite", ctx.out_dir / f"{ctx.label}-trails.pmtiles"]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation | SqliteExpectation:
        region = ctx._region()
        if output.suffix == ".sqlite":
            ranges = {"trails": region.expect["trails"]} if "trails" in region.expect else {}
            return SqliteExpectation("trails", region.id, TABLES["trails"], COUNT_TABLES["trails"], ranges)
        return Expectation(TRAILS_MIN_ZOOM, TRAILS_MAX_ZOOM, frozenset({"mvt"}))

    def build(self, ctx: BuildContext) -> StepOutcome:
        region = ctx._region()
        anomalies: list[Anomaly] = []
        hiking = extract.region_hiking_pbf(ctx)
        timestamp = extract.osm_timestamp(extract.geofabrik_pbf(ctx))
        per_source: list[tuple[str, list[TrailRecord]]] = []
        for source in region.trail_sources:
            if source == "osm":
                per_source.append(("osm", read_osm_trails(hiking, source_date=timestamp)))
        records = merge(per_source)
        terrain = ctx.out_dir / f"{ctx.label}-terrain.pmtiles"
        sampler = TerrainSampler(terrain) if terrain.exists() else None
        if sampler is None:
            anomalies.append(Anomaly("terrain_missing", ctx.label, "no terrain archive in this build; ascent and descent are null"))
        for record in records:
            anomalies.extend(record.anomalies)
            if sampler is not None and record.legs:
                ascent = descent = 0.0
                missing = 0
                for leg in record.legs:
                    up, down, gaps = ascent_descent(sampler, leg)
                    ascent += up or 0.0
                    descent += down or 0.0
                    missing += gaps
                record.ascent_m, record.descent_m = ascent, descent
                if missing:
                    anomalies.append(Anomaly("terrain_gap", record.source_id, f"{missing} elevation samples had no terrain tile"))
        sqlite_path, overlay_path = self.outputs(ctx)
        primaries = [(i + 1, r) for i, r in enumerate(records) if r.secondary_of is None]

        def fill(conn: sqlite3.Connection) -> None:
            placeholders = ",".join("?" * 31)
            for index, record in enumerate(records):
                trail_id = index + 1
                winner = record.secondary_of + 1 if record.secondary_of is not None else None
                conn.execute(f"INSERT INTO trails VALUES ({placeholders})", trail_row(record, trail_id, winner))
                if record.bbox:
                    lon_min, lat_min, lon_max, lat_max = record.bbox
                    conn.execute("INSERT INTO trails_rtree VALUES (?, ?, ?, ?, ?)", (trail_id, lon_min, lon_max, lat_min, lat_max))

        meta = Metadata("trails", region.id, datetime.now(UTC).strftime("%Y-%m-%d"), timestamp)
        write_sqlite(sqlite_path, "trails", meta, fill)
        argv = build_overlay((trail_feature(r, i) for i, r in primaries if r.legs), overlay_path, "trails", TRAILS_MIN_ZOOM, TRAILS_MAX_ZOOM)
        return StepOutcome(argv, anomalies)
```

The `trails` table has 31 columns; keep `trail_row`'s tuple length and the `placeholders` count in step. A region with zero trails fails the overlay validation with "zero tiles" (tippecanoe writes no tiles); note it in architecture.md as a known limit until a region needs it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_steps_trails.py -q`
Expected: all pass. `test_build_computes_ascent_from_the_terrain_archive`: the fixture tile covers the test bbox's z12 tile `2187/1455`; the trail's points all fall inside it, so `missing` is 0.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/overlay.py pipeline/src/maqs/trails/step.py pipeline/tests/test_steps_trails.py
git commit -m "feat(pipeline): trails step with SQLite index, ascent/descent and overlay tiles"
```

---

### Task 9: The places step

**Files:**
- Create: `pipeline/src/maqs/places/__init__.py`, `pipeline/src/maqs/places/step.py`, `pipeline/tests/test_steps_places.py`

**Interfaces:**
- Consumes: `extract.region_pbf`, `extract.tags_filter`, `extract.geofabrik_pbf`, `extract.osm_timestamp` (Task 3); `write_sqlite`, `Metadata`, `TABLES`, `COUNT_TABLES` (Task 5); `build_overlay` (Task 8); `SqliteExpectation`, `Expectation`, `StepOutcome`, `Anomaly`.
- Produces: `PLACE_FILTERS: tuple[str, ...]` (the osmium expressions); `KINDS: tuple[str, ...]`; `place_kind(tags: Mapping[str, str]) -> str | None`; `parse_ele(value: str | None) -> tuple[float | None, str | None]`; `rank_score(wikidata: str | None, ele: float | None) -> float`; `@dataclass PlaceRecord(osm_id: int, kind: str, name: str | None, name_it: str | None, name_de: str | None, name_fur: str | None, name_sl: str | None, ele: float | None, wikidata: str | None, lon: float, lat: float, rank_score: float, anomalies: list[Anomaly])`; `read_places(pbf: Path) -> list[PlaceRecord]`; `class PlacesStep` (`name = "places"`, outputs `<label>-places.sqlite`, `<label>-places.pmtiles`); `PLACES_MIN_ZOOM = 8`, `PLACES_MAX_ZOOM = 14`.

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_steps_places.py
import json
import subprocess
from pathlib import Path

import pytest

from maqs import tools
from maqs.config import load_config
from maqs.context import BuildContext
from maqs.osm import extract
from maqs.places.step import PLACE_FILTERS, PlacesStep, parse_ele, place_kind, rank_score, read_places
from maqs.sqlite_out import open_readonly
from maqs.steps.base import run_step
from tests.helpers import write_pmtiles
from tests.osm_fixtures import write_osm

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.mark.parametrize(
    "tags, kind",
    [
        ({"natural": "peak", "name": "Col Visentin"}, "peak"),
        ({"natural": "peak"}, "peak"),  # unnamed peaks are kept
        ({"natural": "volcano"}, "volcano"),
        ({"natural": "saddle"}, "saddle"),
        ({"natural": "saddle", "mountain_pass": "yes"}, "pass"),
        ({"mountain_pass": "yes"}, "pass"),
        ({"tourism": "alpine_hut"}, "alpine_hut"),
        ({"tourism": "wilderness_hut"}, "wilderness_hut"),
        ({"amenity": "shelter"}, "shelter"),
        ({"place": "village", "name": "Nevegal"}, "village"),
        ({"place": "hamlet", "name": "X"}, "hamlet"),
        ({"place": "isolated_dwelling", "name": "X"}, "isolated_dwelling"),
        ({"place": "village"}, None),  # unnamed settlements are skipped
        ({"place": "town", "name": "Belluno"}, None),
        ({"highway": "bus_stop"}, None),
    ],
)
def test_place_kind(tags, kind):
    assert place_kind(tags) == kind


@pytest.mark.parametrize(
    "raw, expected",
    [("1763", (1763.0, None)), ("1763.5 m", (1763.5, None)), (" 1,763 ", (1763.0, None)), ("1763m", (1763.0, None)),
     (None, (None, None)), ("ca. 1700", (None, "unparsable ele 'ca. 1700'")), ("5000 ft", (None, "unparsable ele '5000 ft'"))],
)
def test_parse_ele(raw, expected):
    assert parse_ele(raw) == expected


def test_rank_score():
    assert rank_score("Q123", 1763.0) == 2763.0
    assert rank_score(None, 1763.0) == 1763.0
    assert rank_score("Q1", None) == 1000.0
    assert rank_score(None, None) == 0.0


def test_place_filters_cover_the_brief():
    assert PLACE_FILTERS == (
        "n/natural=peak,volcano,saddle", "n/mountain_pass=yes", "n/tourism=alpine_hut,wilderness_hut",
        "n/amenity=shelter", "n/place=village,hamlet,isolated_dwelling",
    )


@pytest.fixture
def places_pbf(tmp_path):
    nodes = {1: (12.25, 46.10), 2: (12.26, 46.11), 3: (12.27, 46.12), 4: (12.28, 46.13)}
    return write_osm(tmp_path / "places.osm.pbf", nodes, {}, {}), nodes


def write_places(tmp_path):
    import osmium
    import osmium.osm.mutable as mutable

    path = tmp_path / "places.osm.pbf"
    with osmium.SimpleWriter(str(path), overwrite=True) as w:
        w.add_node(mutable.Node(id=1, location=(12.25, 46.10), tags={"natural": "peak", "name": "Col Visentin", "name:de": "Visentin", "ele": "1763", "wikidata": "Q123"}))
        w.add_node(mutable.Node(id=2, location=(12.26, 46.11), tags={"natural": "saddle", "mountain_pass": "yes", "name": "Forcella", "ele": "1,500 m"}))
        w.add_node(mutable.Node(id=3, location=(12.27, 46.12), tags={"place": "hamlet"}))  # unnamed: skipped
        w.add_node(mutable.Node(id=4, location=(12.28, 46.13), tags={"tourism": "alpine_hut", "name": "Rifugio Brigata Cadore", "ele": "ca. 1600"}))
    return path


def test_read_places(tmp_path):
    records = {r.osm_id: r for r in read_places(write_places(tmp_path))}
    assert set(records) == {1, 2, 4}
    assert (records[1].kind, records[1].name, records[1].name_de, records[1].ele, records[1].wikidata, records[1].rank_score) == ("peak", "Col Visentin", "Visentin", 1763.0, "Q123", 2763.0)
    assert (records[2].kind, records[2].ele, records[2].rank_score) == ("pass", 1500.0, 1500.0)
    assert records[4].ele is None and records[4].anomalies[0].kind == "ele" and records[4].rank_score == 0.0
    assert (records[1].lon, records[1].lat) == (12.25, 46.10)


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("test"))


def test_build_writes_sqlite_and_overlay(ctx, tmp_path, monkeypatch):
    fixture = write_places(tmp_path)
    monkeypatch.setattr(extract, "region_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    filtered = {}

    def fake_tags_filter(src, dst, expressions):
        filtered["expressions"] = list(expressions)
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        return ["osmium", "tags-filter"]

    monkeypatch.setattr(extract, "tags_filter", fake_tags_filter)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/usr/bin/{name}"))
    captured = {}

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        captured["features"] = [json.loads(line) for line in Path(argv[-1]).read_text().splitlines() if line.strip()]
        write_pmtiles(Path(argv[argv.index("-o") + 1]), tile_type=1, min_zoom=8, max_zoom=14)
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(tools, "run", fake_run)
    result = run_step(PlacesStep(), ctx)
    assert result.status == "built", result.error
    assert filtered["expressions"] == list(PLACE_FILTERS)
    conn = open_readonly(ctx.out_dir / "test-places.sqlite")
    rows = conn.execute("SELECT osm_id, kind, name, ele, rank_score FROM places ORDER BY rank_score DESC").fetchall()
    assert rows == [(1, "peak", "Col Visentin", 1763.0, 2763.0), (2, "pass", "Forcella", 1500.0, 1500.0), (4, "alpine_hut", "Rifugio Brigata Cadore", None, 0.0)]
    assert conn.execute("SELECT osm_id FROM places p JOIN places_fts f ON f.rowid = p.id WHERE places_fts MATCH 'visentin'").fetchall() == [(1,)]
    assert conn.execute("SELECT id FROM places_rtree WHERE min_lon <= 12.25 AND max_lon >= 12.25 AND min_lat <= 46.10 AND max_lat >= 46.10").fetchall() == [(1,)]
    assert [f["properties"]["kind"] for f in captured["features"]] == ["peak", "pass", "alpine_hut"]
    assert captured["features"][0]["geometry"] == {"type": "Point", "coordinates": [12.25, 46.1]}
    assert {a.kind for a in result.anomalies} == {"ele"} and result.outputs[0].rows == {"places": 3}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_steps_places.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.places'`

- [ ] **Step 3: Implement**

```python
# pipeline/src/maqs/places/__init__.py
```

```python
# pipeline/src/maqs/places/step.py
"""The places layer: peaks, passes, huts, shelters and named settlements with a label rank."""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import osmium

from maqs.context import BuildContext
from maqs.osm import extract
from maqs.overlay import build_overlay
from maqs.sqlite_out import COUNT_TABLES, TABLES, Metadata, write_sqlite
from maqs.steps.base import Anomaly, StepOutcome
from maqs.validate import Expectation, SqliteExpectation

PLACE_FILTERS: tuple[str, ...] = (
    "n/natural=peak,volcano,saddle", "n/mountain_pass=yes", "n/tourism=alpine_hut,wilderness_hut",
    "n/amenity=shelter", "n/place=village,hamlet,isolated_dwelling",
)
KINDS: tuple[str, ...] = ("peak", "volcano", "saddle", "pass", "alpine_hut", "wilderness_hut", "shelter", "village", "hamlet", "isolated_dwelling")
PLACES_MIN_ZOOM = 8
PLACES_MAX_ZOOM = 14
_ELE_RE = re.compile(r"^\s*(-?\d+(?:[.,]\d+)?)\s*(?:m|meters|metres)?\s*$", re.IGNORECASE)


def place_kind(tags: Mapping[str, str]) -> str | None:
    if tags.get("mountain_pass") == "yes":
        return "pass"
    natural = tags.get("natural")
    if natural in ("peak", "volcano", "saddle"):
        return natural
    tourism = tags.get("tourism")
    if tourism in ("alpine_hut", "wilderness_hut"):
        return tourism
    if tags.get("amenity") == "shelter":
        return "shelter"
    place = tags.get("place")
    if place in ("village", "hamlet", "isolated_dwelling") and tags.get("name"):
        return place
    return None


def parse_ele(value: str | None) -> tuple[float | None, str | None]:
    if value is None:
        return None, None
    match = _ELE_RE.match(value)
    if not match:
        return None, f"unparsable ele {value!r}"
    number = match.group(1)
    if "," in number and "." not in number:
        number = number.replace(",", "") if len(number.split(",")[-1]) == 3 else number.replace(",", ".")
    return float(number), None


def rank_score(wikidata: str | None, ele: float | None) -> float:
    return 1000.0 * (1 if wikidata else 0) + (ele or 0.0)


@dataclass
class PlaceRecord:
    osm_id: int
    kind: str
    name: str | None
    name_it: str | None
    name_de: str | None
    name_fur: str | None
    name_sl: str | None
    ele: float | None
    wikidata: str | None
    lon: float
    lat: float
    rank_score: float
    anomalies: list[Anomaly] = field(default_factory=list)


def read_places(pbf: Path) -> list[PlaceRecord]:
    records: list[PlaceRecord] = []
    for node in osmium.FileProcessor(str(pbf), osmium.osm.NODE):
        tags = dict(node.tags)
        kind = place_kind(tags)
        if kind is None or not node.location.valid():
            continue
        ele, problem = parse_ele(tags.get("ele"))
        anomalies = [Anomaly("ele", f"node/{node.id}", problem)] if problem else []
        wikidata = tags.get("wikidata")
        records.append(
            PlaceRecord(
                node.id, kind, tags.get("name"), tags.get("name:it"), tags.get("name:de"), tags.get("name:fur"), tags.get("name:sl"),
                ele, wikidata, node.location.lon, node.location.lat, rank_score(wikidata, ele), anomalies,
            )
        )
    return records


def place_feature(record: PlaceRecord, place_id: int) -> dict:
    return {
        "type": "Feature",
        "properties": {"id": place_id, "kind": record.kind, "name": record.name, "ele": record.ele, "rank_score": record.rank_score},
        "geometry": {"type": "Point", "coordinates": [record.lon, record.lat]},
    }


class PlacesStep:
    name = "places"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-places.sqlite", ctx.out_dir / f"{ctx.label}-places.pmtiles"]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation | SqliteExpectation:
        region = ctx._region()
        if output.suffix == ".sqlite":
            ranges = {"places": region.expect["places"]} if "places" in region.expect else {}
            return SqliteExpectation("places", region.id, TABLES["places"], COUNT_TABLES["places"], ranges)
        return Expectation(PLACES_MIN_ZOOM, PLACES_MAX_ZOOM, frozenset({"mvt"}))

    def build(self, ctx: BuildContext) -> StepOutcome:
        region = ctx._region()
        source = extract.region_pbf(ctx)
        filtered = ctx.cache / region.id / "places.osm.pbf"
        if not filtered.exists() or ctx.force:
            extract.tags_filter(source, filtered, PLACE_FILTERS)
        timestamp = extract.osm_timestamp(extract.geofabrik_pbf(ctx))
        records = read_places(filtered)
        anomalies = [a for r in records for a in r.anomalies]
        sqlite_path, overlay_path = self.outputs(ctx)

        def fill(conn: sqlite3.Connection) -> None:
            for index, r in enumerate(records):
                place_id = index + 1
                conn.execute(
                    "INSERT INTO places VALUES (?, 'node', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (place_id, r.osm_id, r.kind, r.name, r.name_it, r.name_de, r.name_fur, r.name_sl, r.ele, r.wikidata, r.lon, r.lat, r.rank_score),
                )
                conn.execute("INSERT INTO places_rtree VALUES (?, ?, ?, ?, ?)", (place_id, r.lon, r.lon, r.lat, r.lat))

        meta = Metadata("places", region.id, datetime.now(UTC).strftime("%Y-%m-%d"), timestamp)
        write_sqlite(sqlite_path, "places", meta, fill)
        argv = build_overlay((place_feature(r, i + 1) for i, r in enumerate(records)), overlay_path, "places", PLACES_MIN_ZOOM, PLACES_MAX_ZOOM)
        return StepOutcome(argv, anomalies)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/test_steps_places.py -q`
Expected: all pass. The `places_pbf` fixture in the test file is unused once `write_places` exists; delete it rather than leave dead code.

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/places pipeline/tests/test_steps_places.py
git commit -m "feat(pipeline): places step with rank_score, SQLite index and overlay"
```

---

### Task 10: Curvature scoring and step

**Files:**
- Create: `pipeline/src/maqs/curvature/__init__.py`, `pipeline/src/maqs/curvature/score.py`, `pipeline/src/maqs/curvature/step.py`, `pipeline/tests/test_curvature.py`, `pipeline/tests/test_steps_curvature.py`

**Interfaces:**
- Consumes: `circumradius`, `cumulative_m`, `merge_close`, `line_length_m`, `bbox_of`, `encode_polyline` (Task 1); `CurvatureConfig` (Task 2); `extract.*` (Task 3); `write_sqlite` etc. (Task 5).
- Produces:
  - `score.py`: `BANDS: tuple[tuple[float, int], ...] = ((30.0, 4), (60.0, 3), (100.0, 2), (175.0, 1))`; `CORNER_MAX_RADIUS_M = 500.0`; `MERGE_MIN_M = 5.0`; `band_weight(radius_m: float) -> int`; `vertex_radii(coords) -> list[tuple[float, int]]` (one per interior vertex, index 1..n-2); `way_score(coords, radii) -> float`; `@dataclass(frozen=True) Corner(apex_index: int, apex: Coord, min_radius_m: float, direction: str, entry_m: float, apex_m: float, exit_m: float)`; `find_corners(coords, radii) -> list[Corner]`; `score_way(coords) -> tuple[list[Coord], float, list[Corner]]` (merged coords, score, corners).
  - `step.py`: `parse_oneway(value: str | None) -> int` (1 forward, -1 reverse, 0 both); `@dataclass SegmentRecord(osm_way_id, name, ref, highway, surface, oneway, maxspeed, coords, start_node, end_node, score, corners)`; `read_roads(pbf: Path, config: CurvatureConfig) -> tuple[list[SegmentRecord], list[Anomaly]]`; `class CurvatureStep` (`name = "curvature"`, output `<label>-curvature.sqlite`).

- [ ] **Step 1: Write the failing tests**

```python
# pipeline/tests/test_curvature.py
import math

import pytest

from maqs.curvature.score import BANDS, CORNER_MAX_RADIUS_M, band_weight, find_corners, score_way, vertex_radii, way_score
from maqs.geometry import line_length_m

CX, CY = 12.25, 46.10
M_PER_DEG_LON = 111_320 * math.cos(math.radians(CY))
M_PER_DEG_LAT = 110_574


def arc(radius_m, start_deg, end_deg, steps):
    """Counter-clockwise arc around (CX, CY) sampled every (end-start)/steps degrees."""
    out = []
    for i in range(steps + 1):
        a = math.radians(start_deg + (end_deg - start_deg) * i / steps)
        out.append((CX + radius_m * math.cos(a) / M_PER_DEG_LON, CY + radius_m * math.sin(a) / M_PER_DEG_LAT))
    return out


def east(n, spacing_m=50.0):
    return [(CX + i * spacing_m / M_PER_DEG_LON, CY) for i in range(n)]


def test_band_weights():
    assert [band_weight(r) for r in (10, 29.9, 30, 59, 60, 99, 100, 174, 175, 1000, math.inf)] == [4, 4, 3, 3, 2, 2, 1, 1, 0, 0, 0]
    assert BANDS == ((30.0, 4), (60.0, 3), (100.0, 2), (175.0, 1))


def test_straight_roads_score_zero_with_no_corners():
    for coords in (east(2), east(3), east(10)):
        merged, score, corners = score_way(coords)
        assert score == 0.0 and corners == [] and merged == coords


def test_vertex_radii_on_an_arc():
    coords = arc(50.0, 180, 270, 6)
    radii = vertex_radii(coords)
    assert len(radii) == len(coords) - 2
    assert all(r == pytest.approx(50.0, rel=0.02) and sign == 1 for r, sign in radii)


def test_arc_scores_in_band_3_and_yields_one_left_corner():
    coords = arc(50.0, 180, 270, 6)  # quarter circle, ~78.5 m
    merged, score, corners = score_way(coords)
    length = line_length_m(merged)
    # the first segment has no vertex radius before it and weighs 0; the rest are band 3
    expected = 3 * (length - line_length_m(merged[:2]))
    assert score == pytest.approx(expected, rel=0.01)
    (corner,) = corners
    assert corner.direction == "left" and corner.min_radius_m == pytest.approx(50.0, rel=0.05)
    assert corner.entry_m < corner.apex_m < corner.exit_m <= length
    assert corner.entry_m == 0.0 and corner.exit_m == pytest.approx(length)


def test_s_curve_yields_two_opposite_corners():
    left = arc(60.0, 180, 270, 5)  # ends at the bottom of its circle, heading east
    # a right turn from there: a circle of the same radius centred 60 m south of the join point,
    # walked clockwise from its top (angle 90°) towards angle 0°
    cx, cy = left[-1][0], left[-1][1] - 60.0 / M_PER_DEG_LAT
    right = [
        (cx + 60.0 * math.cos(math.radians(a)) / M_PER_DEG_LON, cy + 60.0 * math.sin(math.radians(a)) / M_PER_DEG_LAT)
        for a in (72, 54, 36, 18, 0)
    ]
    coords = left + right
    _, score, corners = score_way(coords)
    assert score > 0 and len(corners) == 2
    assert [c.direction for c in corners] == ["left", "right"]
    assert corners[0].exit_m <= corners[1].entry_m


def test_gentle_bend_above_the_cutoff_is_not_a_corner():
    coords = arc(CORNER_MAX_RADIUS_M + 100, 180, 200, 8)
    _, score, corners = score_way(coords)
    assert corners == [] and score == 0.0


def test_jitter_is_merged_before_scoring():
    coords = east(5)
    jittered = coords[:2] + [(coords[1][0] + 1 / M_PER_DEG_LON, coords[1][1] + 1 / M_PER_DEG_LAT)] + coords[2:]  # a vertex ~1.4 m away
    merged, score, corners = score_way(jittered)
    assert merged == coords and score == 0.0 and corners == []


def test_way_score_uses_the_start_vertex_radius():
    coords = east(3)
    assert way_score(coords, [(20.0, 1)]) == pytest.approx(4 * 50.0, rel=0.01)
```

```python
# pipeline/tests/test_steps_curvature.py
from pathlib import Path

import pytest

from maqs.config import CurvatureConfig, load_config
from maqs.context import BuildContext
from maqs.curvature.step import CurvatureStep, parse_oneway, read_roads
from maqs.geometry import decode_polyline
from maqs.osm import extract
from maqs.sqlite_out import open_readonly
from maqs.steps.base import run_step
from tests.osm_fixtures import write_osm
from tests.test_curvature import arc, east

REAL = Path(__file__).resolve().parents[2] / "config" / "regions.yaml"


@pytest.mark.parametrize("raw, expected", [("yes", 1), ("true", 1), ("1", 1), ("-1", -1), ("no", 0), (None, 0), ("reversible", 0)])
def test_parse_oneway(raw, expected):
    assert parse_oneway(raw) == expected


def roads_pbf(tmp_path):
    bend = arc(50.0, 180, 270, 6)
    straight = east(3)
    two = east(2)
    nodes = {i + 1: c for i, c in enumerate(bend)}  # 1..7
    base = len(nodes)
    nodes.update({base + i + 1: c for i, c in enumerate(straight)})  # 8..10
    nodes.update({base + 3 + i + 1: c for i, c in enumerate(two)})  # 11..12
    nodes[99] = (12.30, 46.15)
    ways = {
        10: (list(range(1, 8)), {"highway": "tertiary", "name": "Via del Passo", "ref": "SP1", "surface": "asphalt", "oneway": "yes", "maxspeed": "50"}),
        11: (list(range(8, 11)), {"highway": "primary"}),
        12: ([11, 12], {"highway": "secondary"}),  # two nodes: kept with score 0
        13: ([8, 9], {"highway": "track"}),  # not a configured class (filtered by osmium in real runs; the reader must still skip it)
        14: ([9, 10], {"highway": "primary", "surface": "gravel"}),  # excluded surface
        15: ([99], {"highway": "primary"}),  # one node: skipped with an anomaly
    }
    return write_osm(tmp_path / "roads.osm.pbf", nodes, ways, {})


def test_read_roads_filters_and_scores(tmp_path):
    cfg = CurvatureConfig(("primary", "secondary", "tertiary"), ("gravel",))
    segments, anomalies = read_roads(roads_pbf(tmp_path), cfg)
    by_way = {s.osm_way_id: s for s in segments}
    assert set(by_way) == {10, 11, 12}
    s = by_way[10]
    assert (s.name, s.ref, s.highway, s.surface, s.oneway, s.maxspeed) == ("Via del Passo", "SP1", "tertiary", "asphalt", 1, "50")
    assert (s.start_node, s.end_node) == (1, 7) and s.score > 0 and len(s.corners) == 1
    assert by_way[11].score == 0.0 and by_way[12].score == 0.0 and by_way[12].corners == []
    assert [a.kind for a in anomalies] == ["too_short"] and anomalies[0].id == "way/15"


@pytest.fixture
def ctx(tmp_path):
    cfg = load_config(REAL)
    return BuildContext(config=cfg, dist=tmp_path / "dist", cache=tmp_path / ".cache", force=False, region=cfg.region("test"))


def test_build_writes_segments_and_corners(ctx, tmp_path, monkeypatch):
    fixture = roads_pbf(tmp_path)
    monkeypatch.setattr(extract, "region_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: fixture)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")
    seen = {}

    def fake_tags_filter(src, dst, expressions):
        seen["expressions"] = list(expressions)
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        return ["osmium"]

    monkeypatch.setattr(extract, "tags_filter", fake_tags_filter)
    result = run_step(CurvatureStep(), ctx)
    assert result.status == "built", result.error
    assert seen["expressions"] == ["w/highway=" + ",".join(ctx.config.curvature.highways)]
    assert result.command == [] and result.outputs[0].rows["segments"] == 3 and result.outputs[0].rows["corners"] == 1
    conn = open_readonly(ctx.out_dir / "test-curvature.sqlite")
    seg = conn.execute("SELECT id, osm_way_id, start_node, end_node, score, geometry FROM segments WHERE osm_way_id = 10").fetchone()
    assert seg[2:4] == (1, 7) and seg[4] > 0 and len(decode_polyline(seg[5])) == 7
    corner = conn.execute("SELECT segment_id, ordinal, direction, min_radius_m, entry_m, apex_m, exit_m FROM corners").fetchone()
    assert corner[0] == seg[0] and corner[1] == 0 and corner[2] == "left" and 45 < corner[3] < 55 and corner[4] < corner[5] < corner[6]
    assert conn.execute("SELECT count(*) FROM segments_rtree").fetchone() == (3,) and conn.execute("SELECT count(*) FROM corners_rtree").fetchone() == (1,)
    assert [a.kind for a in result.anomalies] == ["too_short"]


def test_expectation_uses_curvature_segments_range(ctx):
    cfg = ctx.config
    region = cfg.region("test").__class__(**{**cfg.region("test").__dict__, "expect": {"curvature_segments": cfg.region("veneto").expect.get("trails")}})
    ctx2 = BuildContext(config=cfg, dist=ctx.dist, cache=ctx.cache, force=False, region=region)
    e = CurvatureStep().expectation(ctx2, ctx2.out_dir / "test-curvature.sqlite")
    assert e.layer == "curvature" and e.count_tables == ("segments", "corners") and "segments" in e.row_ranges
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_curvature.py tests/test_steps_curvature.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'maqs.curvature'`

- [ ] **Step 3: Implement `score.py`**

```python
# pipeline/src/maqs/curvature/__init__.py
```

```python
# pipeline/src/maqs/curvature/score.py
"""Road curvature: per-vertex radius, per-way score, discrete corners (ADR 0005, 0008, 0011).

The normative description is in docs/data-format.md; the Swift package mirrors these rules so
recorded tracks and road corners agree by construction.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass

from maqs.geometry import Coord, circumradius, cumulative_m, merge_close

BANDS: tuple[tuple[float, int], ...] = ((30.0, 4), (60.0, 3), (100.0, 2), (175.0, 1))
CORNER_MAX_RADIUS_M = 500.0
MERGE_MIN_M = 5.0


def band_weight(radius_m: float) -> int:
    for limit, weight in BANDS:
        if radius_m < limit:
            return weight
    return 0


def vertex_radii(coords: Sequence[Coord]) -> list[tuple[float, int]]:
    return [circumradius(coords[i - 1], coords[i], coords[i + 1]) for i in range(1, len(coords) - 1)]


def way_score(coords: Sequence[Coord], radii: Sequence[tuple[float, int]]) -> float:
    distances = cumulative_m(coords)
    score = 0.0
    for i, (radius, _) in enumerate(radii, start=1):  # radius at vertex i weighs segment i -> i+1
        score += (distances[i + 1] - distances[i]) * band_weight(radius)
    return score


@dataclass(frozen=True)
class Corner:
    apex_index: int
    apex: Coord
    min_radius_m: float
    direction: str
    entry_m: float
    apex_m: float
    exit_m: float


def find_corners(coords: Sequence[Coord], radii: Sequence[tuple[float, int]]) -> list[Corner]:
    distances = cumulative_m(coords)
    corners: list[Corner] = []
    run: list[int] = []  # interior vertex indices of the current run

    def close_run() -> None:
        if not run:
            return
        apex = min(run, key=lambda i: radii[i - 1][0])
        entry, exit_ = run[0] - 1, run[-1] + 1
        radius, _ = circumradius(coords[entry], coords[apex], coords[exit_])
        if math.isinf(radius):
            radius = radii[apex - 1][0]
        sign = radii[apex - 1][1]
        corners.append(Corner(apex, coords[apex], radius, "left" if sign > 0 else "right", distances[entry], distances[apex], distances[exit_]))
        run.clear()

    for i, (radius, sign) in enumerate(radii, start=1):
        turning = sign != 0 and radius < CORNER_MAX_RADIUS_M
        if turning and (not run or radii[run[-1] - 1][1] == sign):
            run.append(i)
            continue
        close_run()
        if turning:
            run.append(i)
    close_run()
    return corners


def score_way(coords: Sequence[Coord]) -> tuple[list[Coord], float, list[Corner]]:
    merged = merge_close(coords, MERGE_MIN_M)
    if len(merged) < 3:
        return merged, 0.0, []
    radii = vertex_radii(merged)
    return merged, way_score(merged, radii), find_corners(merged, radii)
```

- [ ] **Step 4: Implement `step.py`**

```python
# pipeline/src/maqs/curvature/step.py
"""The curvature layer: one segment per configured road way, with its corners."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import osmium

from maqs.config import CurvatureConfig
from maqs.context import BuildContext
from maqs.curvature.score import Corner, score_way
from maqs.geometry import Coord, bbox_of, encode_polyline, line_length_m
from maqs.osm import extract
from maqs.sqlite_out import COUNT_TABLES, TABLES, Metadata, write_sqlite
from maqs.steps.base import Anomaly, StepOutcome
from maqs.validate import Expectation, SqliteExpectation


def parse_oneway(value: str | None) -> int:
    if value is None:
        return 0
    text = value.strip().lower()
    if text in ("yes", "true", "1"):
        return 1
    if text == "-1":
        return -1
    return 0


@dataclass
class SegmentRecord:
    osm_way_id: int
    name: str | None
    ref: str | None
    highway: str
    surface: str | None
    oneway: int
    maxspeed: str | None
    coords: list[Coord]
    start_node: int
    end_node: int
    score: float
    corners: list[Corner]


def read_roads(pbf: Path, config: CurvatureConfig) -> tuple[list[SegmentRecord], list[Anomaly]]:
    segments: list[SegmentRecord] = []
    anomalies: list[Anomaly] = []
    highways = set(config.highways)
    excluded = set(config.exclude_surfaces)
    for obj in osmium.FileProcessor(str(pbf)).with_locations():
        if not obj.is_way():
            continue
        tags = dict(obj.tags)
        if tags.get("highway") not in highways or tags.get("surface") in excluded:
            continue
        located = [n for n in obj.nodes if n.location.valid()]
        if len(located) < 2:
            anomalies.append(Anomaly("too_short", f"way/{obj.id}", f"{len(located)} located nodes; need 2"))
            continue
        coords = [(n.lon, n.lat) for n in located]
        merged, score, corners = score_way(coords)
        segments.append(
            SegmentRecord(
                obj.id, tags.get("name"), tags.get("ref"), tags["highway"], tags.get("surface"), parse_oneway(tags.get("oneway")),
                tags.get("maxspeed"), merged, located[0].ref, located[-1].ref, score, corners,
            )
        )
    return segments, anomalies


class CurvatureStep:
    name = "curvature"

    def outputs(self, ctx: BuildContext) -> list[Path]:
        return [ctx.out_dir / f"{ctx.label}-curvature.sqlite"]

    def expectation(self, ctx: BuildContext, output: Path) -> Expectation | SqliteExpectation:
        region = ctx._region()
        ranges = {"segments": region.expect["curvature_segments"]} if "curvature_segments" in region.expect else {}
        return SqliteExpectation("curvature", region.id, TABLES["curvature"], COUNT_TABLES["curvature"], ranges)

    def build(self, ctx: BuildContext) -> StepOutcome:
        region = ctx._region()
        source = extract.region_pbf(ctx)
        filtered = ctx.cache / region.id / "roads.osm.pbf"
        if not filtered.exists() or ctx.force:
            extract.tags_filter(source, filtered, ["w/highway=" + ",".join(ctx.config.curvature.highways)])
        timestamp = extract.osm_timestamp(extract.geofabrik_pbf(ctx))
        segments, anomalies = read_roads(filtered, ctx.config.curvature)

        def fill(conn: sqlite3.Connection) -> None:
            corner_id = 0
            for index, s in enumerate(segments):
                segment_id = index + 1
                lon_min, lat_min, lon_max, lat_max = bbox_of(s.coords)
                conn.execute(
                    "INSERT INTO segments VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (segment_id, s.osm_way_id, s.name, s.ref, s.highway, s.surface, s.oneway, s.maxspeed, line_length_m(s.coords), s.score,
                     s.start_node, s.end_node, lon_min, lat_min, lon_max, lat_max, encode_polyline(s.coords)),
                )
                conn.execute("INSERT INTO segments_rtree VALUES (?, ?, ?, ?, ?)", (segment_id, lon_min, lon_max, lat_min, lat_max))
                for ordinal, c in enumerate(s.corners):
                    corner_id += 1
                    conn.execute(
                        "INSERT INTO corners VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (corner_id, segment_id, ordinal, c.apex[0], c.apex[1], c.min_radius_m, c.direction, c.entry_m, c.apex_m, c.exit_m),
                    )
                    conn.execute("INSERT INTO corners_rtree VALUES (?, ?, ?, ?, ?)", (corner_id, c.apex[0], c.apex[0], c.apex[1], c.apex[1]))

        meta = Metadata("curvature", region.id, datetime.now(UTC).strftime("%Y-%m-%d"), timestamp)
        write_sqlite(self.outputs(ctx)[0], "curvature", meta, fill)
        return StepOutcome([], anomalies)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `uv run pytest tests/test_curvature.py tests/test_steps_curvature.py -q`
Expected: all pass. In `test_s_curve_yields_two_opposite_corners` the first arc turns left (counter-clockwise) and the second, centred south of the join, turns right; if the directions come out swapped the sign convention in `circumradius` is inverted (fix `geometry.py`, not the test).

- [ ] **Step 6: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/curvature pipeline/tests/test_curvature.py pipeline/tests/test_steps_curvature.py
git commit -m "feat(pipeline): curvature scoring, corners and the curvature step"
```

---

### Task 11: CLI wiring, default layers and step order

**Files:**
- Modify: `pipeline/src/maqs/cli.py`, `pipeline/tests/test_cli.py`

**Interfaces:**
- Consumes: `TrailsStep`, `PlacesStep`, `CurvatureStep`, `TILE_STEPS`, `TerrainHDStep`, `BasePackStep`.
- Produces: `LAYER_ORDER: tuple[str, ...] = ("basemap", "terrain", "terrain-hd", "trails", "places", "curvature")`; `LAYER_STEPS: dict[str, type]` over all six; `DEFAULT_LAYERS = ("basemap", "terrain", "trails", "places", "curvature")`; `_parse_layers` returns the requested layers sorted by `LAYER_ORDER` with duplicates removed.

- [ ] **Step 1: Write the failing tests** (append to `tests/test_cli.py`; reuse the file's `ok_tools` helper and `REAL`)

```python
from maqs.osm import extract
from tests.osm_fixtures import write_osm


def test_default_layers_and_order():
    result = CliRunner().invoke(main, ["build", "--help"])
    assert "basemap,terrain,trails,places,curvature" in result.output
    from maqs.cli import _parse_layers

    assert _parse_layers("curvature,basemap,trails,basemap") == ["basemap", "trails", "curvature"]
    assert _parse_layers("terrain-hd,terrain") == ["terrain", "terrain-hd"]


def data_stubs(monkeypatch, tmp_path):
    """Fixture PBFs in place of the osmium cuts, and stubbed tippecanoe/versatiles runs."""
    nodes = {1: (12.250, 46.100), 2: (12.251, 46.101), 3: (12.252, 46.102), 4: (12.26, 46.11)}
    hiking = write_osm(tmp_path / "hiking.osm.pbf", nodes, {10: ([1, 2, 3], {"highway": "path"})},
                       {100: ([("w", 10, "")], {"type": "route", "route": "hiking", "ref": "501"})})
    region = write_osm(tmp_path / "region.osm.pbf", nodes,
                       {20: ([1, 2, 3, 4], {"highway": "tertiary", "name": "Via"})}, {})
    import osmium
    import osmium.osm.mutable as mutable

    places = tmp_path / "places.osm.pbf"
    with osmium.SimpleWriter(str(places), overwrite=True) as w:
        w.add_node(mutable.Node(id=1, location=(12.25, 46.10), tags={"natural": "peak", "name": "Cima", "ele": "1700"}))
    monkeypatch.setattr(extract, "geofabrik_pbf", lambda c: region)
    monkeypatch.setattr(extract, "region_hiking_pbf", lambda c: hiking)
    monkeypatch.setattr(extract, "region_pbf", lambda c: region)
    monkeypatch.setattr(extract, "osm_timestamp", lambda p: "2026-10-06T20:21:06Z")

    def fake_tags_filter(src, dst, expressions):
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes((places if expressions[0].startswith("n/") else region).read_bytes())
        return ["osmium"]

    monkeypatch.setattr(extract, "tags_filter", fake_tags_filter)
    monkeypatch.setattr(tools, "find_tool", lambda name: Path(f"/fake/{name}"))

    def fake_run(argv, **kw):
        argv = [str(a) for a in argv]
        if argv[0].endswith("tippecanoe"):
            out = Path(argv[argv.index("-o") + 1])
            zooms = (6, 14) if "-l" in argv and argv[argv.index("-l") + 1] == "trails" else (8, 14)
            write_pmtiles(out, tile_type=1, min_zoom=zooms[0], max_zoom=zooms[1])
        else:
            out = Path(argv[-1])
            out.parent.mkdir(parents=True, exist_ok=True)
            if "elevation.versatiles" in argv[-2]:
                write_pmtiles(out, tile_type=4, max_zoom=12, tile_compression=1)
            else:
                write_pmtiles(out, tile_type=1, max_zoom=14, metadata={"attribution": "© OSM"})
        return None

    monkeypatch.setattr(tools, "run", fake_run)


def test_build_all_default_layers_writes_every_output(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    data_stubs(monkeypatch, tmp_path)
    dist = tmp_path / "dist"
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(dist), "--cache", str(tmp_path / "cache")])
    assert result.exit_code == 0, result.output
    names = sorted(p.name for p in (dist / "test").iterdir())
    assert names == ["build-report.json", "test-basemap.pmtiles", "test-curvature.sqlite", "test-places.pmtiles", "test-places.sqlite",
                     "test-terrain.pmtiles", "test-trails.pmtiles", "test-trails.sqlite"]
    report = json.loads((dist / "test" / "build-report.json").read_text())
    assert [s["name"] for s in report["steps"]] == ["basemap", "terrain", "trails", "places", "curvature"]
    trails = next(s for s in report["steps"] if s["name"] == "trails")
    assert trails["outputs"][0]["rows"] == {"trails": 1} and trails["outputs"][0]["source"] is None
    assert trails["outputs"][1]["tile_type"] == "mvt" and "anomaly_count" in trails
    assert report["validation"]["ok"] is True


def test_build_data_layers_only(monkeypatch, tmp_path):
    ok_tools(monkeypatch)
    data_stubs(monkeypatch, tmp_path)
    dist = tmp_path / "dist"
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--layers", "curvature,places", "--dist", str(dist), "--cache", str(tmp_path / "cache")])
    assert result.exit_code == 0, result.output
    report = json.loads((dist / "test" / "build-report.json").read_text())
    assert [s["name"] for s in report["steps"]] == ["places", "curvature"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/test_cli.py -q`
Expected: FAIL (`basemap,terrain` is still the default; `trails` is an unknown layer).

- [ ] **Step 3: Implement**

In `cli.py`:

```python
from maqs.curvature.step import CurvatureStep
from maqs.places.step import PlacesStep
from maqs.trails.step import TrailsStep

LAYER_ORDER: tuple[str, ...] = ("basemap", "terrain", "terrain-hd", "trails", "places", "curvature")
LAYER_STEPS: dict[str, type] = {**TILE_STEPS, "terrain-hd": TerrainHDStep, "trails": TrailsStep, "places": PlacesStep, "curvature": CurvatureStep}
DEFAULT_LAYERS: tuple[str, ...] = ("basemap", "terrain", "trails", "places", "curvature")


def _parse_layers(raw: str) -> list[str]:
    layers = [s.strip() for s in raw.split(",") if s.strip()]
    if not layers:
        raise click.UsageError("--layers must name at least one layer")
    for layer in layers:
        if layer not in LAYER_STEPS:
            raise click.UsageError(f"unknown layer '{layer}'; valid: {', '.join(LAYER_ORDER)}")
    return [layer for layer in LAYER_ORDER if layer in layers]
```

The `--layers` option's `show_default` prints the new default; its help text says "Comma-separated layer names, built in this order: basemap, terrain, terrain-hd, trails, places, curvature. terrain-hd is opt-in."

- [ ] **Step 4: Run the whole suite**

Run: `uv run pytest -q`
Expected: all pass (the existing `test_build_runs_steps_and_writes_report` passes `--layers`? If it relied on the old default of two layers, add `--layers basemap,terrain` to that invocation rather than stubbing the data steps there).

- [ ] **Step 5: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add pipeline/src/maqs/cli.py pipeline/tests/test_cli.py
git commit -m "feat(pipeline): trails, places and curvature are default layers, built in a fixed order"
```

---

### Task 12: Live builds, row-count expectations, network test

**Files:**
- Modify: `config/regions.yaml` (`expect` for `test`; adjust other ranges only if measured outside them), `pipeline/tests/test_integration_network.py`

- [ ] **Step 1: Extend the network test**

```python
# pipeline/tests/test_integration_network.py  (replace the body of the existing test)
@pytest.mark.network
def test_test_region_builds_end_to_end(tmp_path):
    result = CliRunner().invoke(main, ["--config", str(REAL), "build", "--region", "test", "--dist", str(tmp_path), "--cache", str(tmp_path / ".cache")])
    assert result.exit_code == 0, result.output
    report = json.loads((tmp_path / "test" / "build-report.json").read_text())
    assert report["validation"]["ok"] is True
    by_name = {s["name"]: s for s in report["steps"]}
    assert set(by_name) == {"basemap", "terrain", "trails", "places", "curvature"}
    basemap, terrain = by_name["basemap"]["outputs"][0], by_name["terrain"]["outputs"][0]
    assert basemap["compression"] == "gzip" and basemap["max_zoom"] == 14 and basemap["tiles"] > 20
    assert terrain["tile_type"] == "webp" and terrain["max_zoom"] == 12
    assert basemap["bytes"] + terrain["bytes"] < 5_000_000
    trails_db, trails_overlay = by_name["trails"]["outputs"]
    assert trails_db["rows"]["trails"] >= 3 and trails_overlay["tile_type"] == "mvt" and trails_overlay["min_zoom"] == 6
    assert by_name["places"]["outputs"][0]["rows"]["places"] > 0
    assert by_name["curvature"]["outputs"][0]["rows"]["segments"] > 0
    for name in ("test-trails.sqlite", "test-trails.pmtiles", "test-places.sqlite", "test-places.pmtiles", "test-curvature.sqlite"):
        assert (tmp_path / "test" / name).exists()
```

Note the `--cache` under `tmp_path`: the network test downloads the 625 MB Geofabrik file into it. Locally, point `--cache` at the repo's `.cache/` instead when iterating, so the file is downloaded once.

- [ ] **Step 2: Build the test region live, all layers**

Run (from `pipeline/`): `time uv run maqs build --region test --force --dist <scratch>/dist` (the default `--cache` is the repo root's `.cache/`, which keeps the Geofabrik file for the later steps).
Expected: exit 0, `ok`. Record: wall time (the first run includes the ~625 MB download), per-step seconds from the report, every output's bytes, `rows` for trails/places/segments/corners, `anomaly_count` per step and the kinds seen, `geometry_status` distribution (`sqlite3 <scratch>/dist/test/test-trails.sqlite "select geometry_status, count(*) from trails group by 1"`), and whether `ascent_m` is populated. Open `test-trails.sqlite` and eyeball three trails' names/refs for sanity.

- [ ] **Step 3: Set the `test` expectations**

Add to the `test` region in `config/regions.yaml`: `expect: { trails: [<floor>, <ceiling>], places: [<floor>, <ceiling>], curvature_segments: [<floor>, <ceiling>] }` with floor = about 60 % and ceiling = about 200 % of the measured counts (round numbers). Re-run `uv run pytest tests/test_config.py -q` and the build without `--force` (everything skipped, validation re-run against the new ranges, exit 0).

- [ ] **Step 4: Run the network test**

Run: `uv run pytest tests/test_integration_network.py --run-network -q -p no:cacheprovider`
Expected: `1 passed` (it downloads the Geofabrik file into its own temp cache; about a minute).

- [ ] **Step 5: Build Veneto's data layers**

Run: `time uv run maqs build --region veneto --layers trails,places,curvature --dist <scratch>/dist`
Expected: exit 0 with counts inside the configured `expect` ranges (trails 1,500–3,000; places 10,000–18,000). If a count lands outside, do not widen the range silently: record the measured number, compare with Phase 0 (1,955 relations with route=hiking inside the admin polygon; 13,408 place nodes), explain the difference in your report (the smart extract includes relations that merely touch the polygon, so trails may exceed 1,955), and set the range to about 60 %–200 % of the measured value with the reason in the commit body. Record: seconds per step, bytes per output, rows, anomaly counts by kind, the `geometry_status` distribution, and `segments`/`corners` counts.

- [ ] **Step 6: Build the data layers for `triveneto` and the other two regions**

Run: `uv run maqs build --region triveneto --layers trails,places,curvature --dist <scratch>/dist`, then the same for `friuli-venezia-giulia` and `trentino-alto-adige`. No tiles are downloaded (the Geofabrik file is cached; cuts come from it). Record bytes and rows per region. Compute ADR 0008's curvature-size figures: `triveneto-curvature.sqlite` bytes, and the sum of the three single-region curvature files, each against the 30 MB target; record also the places and trails sizes. Set `expect` ranges for the three regions as in Step 3 (measured × 0.6 … × 2). For Trentino-Alto Adige, check the `difficulty_scheme` distribution (`select difficulty_scheme, count(*) from trails group by 1`): ADR 0006 predicts many `sac_scale:ways` rows.

- [ ] **Step 7: Lint and commit**

```bash
uv run ruff check . && uv run ruff format .
git add config/regions.yaml pipeline/tests/test_integration_network.py
git commit -m "feat(pipeline): measured row-count expectations for every region; network test covers all layers"
```

Put every measurement in the report file; Task 14 writes them into ADR 0011. The build outputs stay in the scratch directory; nothing under `dist/` is committed.

---

### Task 13: CI: Geofabrik cache and the five-layer smoke build

**Files:**
- Modify: `.github/workflows/pipeline.yml`

- [ ] **Step 1: Edit the smoke job**

After the `Cache tool binaries` block and before `Bootstrap tools`, add:

```yaml
      - name: Geofabrik extract checksum
        id: geofabrik
        run: |
          md5=$(curl -fsSL -A "maqs-pipeline-ci (+https://github.com/lucavallin/maqs)" \
            https://download.geofabrik.de/europe/italy/nord-est-latest.osm.pbf.md5 | cut -d' ' -f1)
          echo "md5=$md5" >> "$GITHUB_OUTPUT"
      - name: Cache the Geofabrik extract
        uses: actions/cache@v6
        with:
          path: .cache/geofabrik
          key: geofabrik-nord-est-${{ steps.geofabrik.outputs.md5 }}
```

(The extract name is the one `config/regions.yaml` gives the `test` region; add a YAML comment saying so.) Change the build step to the default layers (drop nothing: `uv run maqs build --region test --dist "$GITHUB_WORKSPACE/dist" --cache "$GITHUB_WORKSPACE/.cache"`), keep `cat dist/test/build-report.json`, keep the network test step, and keep the artifact upload (it now carries eight files). Raise nothing else; the 30-minute timeout stays.

- [ ] **Step 2: Validate and push**

Run: `uv run --with pyyaml python -I -c "import yaml; yaml.safe_load(open('.github/workflows/pipeline.yml')); print('yaml ok')"`, then:

```bash
git add .github/workflows/pipeline.yml
git commit -m "ci: cache the Geofabrik extract by checksum; smoke-build all five layers"
git push origin main
gh run watch --exit-status
```

Expected: green. Record the cold-run duration (download + bootstrap on a cache miss), then `gh workflow run pipeline.yml --ref main` and record the warm run. If the download step or the data steps fail on the runner (missing shared library for pyosmium, disk space), fix and push again; at most 3 iterations, then stop and report. Record the artifact size.

---

### Task 14: Documentation, ADR 0010 and ADR 0011

**Files:**
- Modify: `docs/data-format.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: `docs/data-format.md`**

Replace the opening paragraph's "The SQLite layers … will be added here" sentence with the current state, then add these sections after "Tile archives", in this order, writing every value from the code and Task 12's measurements (no estimates):

1. **Geometry encoding** — Google encoded polyline, precision 6, TEXT; legs joined by `|`; points as `lon`/`lat` columns; a worked example (one coordinate pair and its encoding); link to ADR 0010.
2. **Overlay tiles** — `<region>-trails.pmtiles` (layer `trails`, z6–14, properties `id`, `ref`, `name`, `difficulty`, `network`, `osmc_symbol`; LineString or MultiLineString per primary trail) and `<region>-places.pmtiles` (layer `places`, z8–14, `id`, `kind`, `name`, `ele`, `rank_score`; Point). gzip MVT written by tippecanoe. The `id` property equals the SQLite row id.
3. **SQLite layers** — the common rules (metadata row, FTS5 tokenizer, R*Tree in degrees, read-only consumers, written atomically), then one subsection per layer with its `layer_schema_version` (1), the DDL from `sqlite_out.py` verbatim, column meanings, and the compatibility rule (additive columns keep the version; a rename, removal or meaning change bumps it).
   - Trails: `geometry_status` values; `secondary_of`; `difficulty` 1–6 with the CAI and SAC tables; `ascent_m`/`descent_m` method (25 m resampling, 5 m hysteresis, null without terrain); provenance columns.
   - Places: `kind` values and the tag mapping; `ele` parsing; **`rank_score = 1000 × [wikidata present] + ele`**, ele treated as 0 when null; the unnamed-settlement rule.
   - Curvature: one segment per way (two-node ways kept with score 0); `oneway` encoding; the formula — 5 m vertex merge, circumcircle radius per interior vertex, band weights 4/3/2/1 under 30/60/100/175 m, score = Σ segment length × weight of the segment's start vertex; corners as same-sign runs under 500 m, apex = tightest vertex, `min_radius_m` = circumcircle of entry/apex/exit, `entry_m`/`apex_m`/`exit_m` along the way; adjacency through `start_node`/`end_node`.
4. **Build report additions** — `rows` per SQLite output; `anomalies` (kind, id, message; capped at 1,000) and `anomaly_count` per step; the anomaly kinds the steps emit (`missing_member`, `reversed`, `gap`, `role`, `difficulty`, `terrain_missing`, `terrain_gap`, `ele`, `too_short`).
5. **Validation rules** — extend with the SQLite checks (integrity, tables, metadata, `expect` ranges, zero-row warning) and the overlay zoom expectations.

- [ ] **Step 2: `docs/architecture.md`**

Add a "Data layers" section: the input flow table from the spec (Geofabrik once per run with md5; hiking tags-filter; `.poly` from admin relations, one section per ring; `osmium extract` per region with `complete_ways`, and `smart`/`types=route` for hiking), the cache layout and the reuse rules (`--force` rebuilds cuts, never re-downloads), the step order and the trails→terrain dependency, the adapter/merge seam, and the known limit (a region with zero trails fails the overlay check). Update the CI paragraph: checksum step, Geofabrik cache, eight-file artifact, measured durations from Task 13. Mention the fixture rule that test PBFs are written nodes-first.

- [ ] **Step 3: `docs/decisions.md`**

Append, in the existing format:

**ADR 0010 — Geometry encoding and the Python dependencies for the data layers.** Context (two candidates; the 30 MB curvature target; Swift decoding cost). Decision: polyline6 TEXT everywhere; pyosmium 4.3.1 (BSD-2) and Pillow 12.x (MIT-CMU) added as the only new runtime dependencies, both maintained, wheels on macOS and Ubuntu 24.04; no shapely because osmium does the spatial cut. Rejected: float32 blobs (size), `pmtiles tile` subprocess per tile (slow), shapely (unneeded). Consequences: `MaqsData` decodes polyline6; ADR 0008's curvature size result is reported in ADR 0011.

**ADR 0011 — Data-layer formulas, thresholds and the first measurements.** The exact constants (25 m / 5 m; `rank_score`; 5 m merge; 500 m cutoff; the bands; difficulty tables; the smart-extract rule), the two-node-way refinement and why, the measured numbers from Task 12 per region (rows, bytes, seconds, anomaly counts, `geometry_status` and `difficulty_scheme` distributions), the curvature size against the 30 MB target with a decision line (met, or what the next step is), the `expect` ranges and how they were derived, and the CI durations from Task 13. Mark any brief contradiction with the `CONTRADICTS BRIEF` label used before.

- [ ] **Step 4: `README.md` and `CLAUDE.md`**

README: the status paragraph says the pipeline now builds all five layers; the build example lists the outputs; the "Develop" block mentions that the network test downloads the Geofabrik extract. CLAUDE.md §1: Commands (`--layers` default), the repository map (`pipeline/src/maqs/{osm,trails,places,curvature}`), two new traps: "pyosmium fixture writers must emit nodes before ways before relations, each by ascending id, or osmium rejects the file" and "`.poly` supports several sections, so a multi-relation clip is one file; `osmium extract --polygon` takes exactly one file". Pipeline rule 1's list of what Python computes stays accurate (it already names these).

- [ ] **Step 5: Humanizer pass, commit, push**

Run the `humanizer` skill over the README and ADR text; apply. Then:

```bash
git add docs/data-format.md docs/architecture.md docs/decisions.md README.md CLAUDE.md
git commit -m "docs: data-layer formats, formulas, ADR 0010 and 0011, architecture and README updates"
git push origin main
```

---

## Self-review notes

- **Spec coverage:** inputs and cuts (Task 3); layout (Tasks 1–10); config additions (Task 2); geometry encoding (Task 1, ADR in Task 14); trails record, adapter, difficulty, ascent/descent, merge, schema, overlay (Tasks 4, 6, 7, 8); places (Task 9); curvature formula and schema (Task 10); common SQLite rules and validation/report additions (Task 5); CI (Task 13); tests as listed in the spec (each task; the spec's `test_steps_data.py` is split per step file); documentation (Task 14); success criteria measured in Task 12.
- **Types:** `StepOutcome`, `Anomaly`, `SqliteExpectation`, `OutputInfo.rows`, `RowRange`, `TrailRecord`, `PlaceRecord`, `SegmentRecord`, `Corner`, `WayGeom`, `Metadata` are named identically wherever they appear. `expectation(ctx, output)` is the new two-argument form everywhere.
- **Review Focus coverage:** (1) Task 6 `test_assemble_flags_missing_member_but_keeps_the_rest`; (2) Task 10 `test_straight_roads_score_zero_with_no_corners` and the two-node way in `test_read_roads_filters_and_scores`; (3) Task 4 `test_ascent_descent_counts_missing_samples`; (4) Task 5 `test_validate_sqlite_fails_outside_the_expected_range`; (5) Task 3 `test_geofabrik_pbf_rejects_md5_mismatch`.
- **Deviations from the spec, each recorded in ADR 0011:** two-node ways kept; the trail `geometry` column joins legs with `|` (the spec says so); `--region all` includes fixtures (unchanged from plan 1).
