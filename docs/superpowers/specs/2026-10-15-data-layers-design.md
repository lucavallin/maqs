# Data layers: trails, places, curvature (Phase 1, plan 2)

**Date:** 2026-10-15 · **Status:** approved design, awaiting implementation plan · **Depends on:** plan 1 (`2026-10-08-pipeline-skeleton-and-tile-layers-design.md`), `docs/BRIEF.md` items 3–6, ADRs 0005, 0006, 0008, 0009.

## Goal

Extend the pipeline with the three data layers the brief lists for every region: a trails index and overlay, a places index and overlay, and a road-curvature index. All three are derived from the Geofabrik extract each region names in `config/regions.yaml`, cut per region by its admin polygon (or bbox), with our own Python doing what no maintained tool does: assembling hiking relations, ranking places, and scoring curvature. Outputs are validated, counted, checksummed and reported like the tile layers.

Out of scope for this plan: `manifest.json` and `sources.json` (Phase 2), the release workflow (Phase 3), any Swift code (Phase 4), trail sources other than OSM (each needs its own ADR first), map-matching or routing.

## Success criteria

- `uv run maqs build --region test` builds all five standard layers (`basemap`, `terrain`, `trails`, `places`, `curvature`) in under 5 minutes from a clean checkout, locally and in CI, and the CI artifact carries the SQLite files and overlays alongside the tile archives.
- `uv run maqs build --region veneto` produces `veneto-trails.sqlite`, `veneto-trails.pmtiles`, `veneto-places.sqlite`, `veneto-places.pmtiles`, `veneto-curvature.sqlite`, and the report's row counts are within the ranges derived from Phase 0 (ADR 0001: 1,955 hiking relations, 13,408 place nodes for Veneto; the curvature count is measured by this plan).
- No hiking relation is dropped silently: every relation in the region's extract becomes a row, and relations with gaps, reversals or missing members are listed in `build-report.json` as anomalies.
- The curvature SQLite for `triveneto` is measured against ADR 0008's 30 MB target and the result recorded; if over, the ADR decides (simplification or a per-region split), the target is not relaxed.
- One geometry encoding is used by every layer, decided in ADR 0010.
- `uv run pytest` and `uv run ruff check` stay green; every formula and every SQLite schema is unit-tested without the network or the real extract; one `network`-marked integration test builds the test region end to end.
- `docs/data-format.md` gains versioned sections for the three SQLite schemas, the two overlays, the geometry encoding and every formula; `docs/architecture.md` describes the data-layer flow.

## Inputs and the per-region cut

| Stage | Tool | Cached where | Notes |
|---|---|---|---|
| Geofabrik extract | `curl -L` of `https://download.geofabrik.de/<extract>-latest.osm.pbf` and its `.md5` sidecar | `.cache/geofabrik/<extract with / → ->-latest.osm.pbf` | Once per distinct extract per run (one file for all launch regions). Verified against the `.md5`. Reused when present; `--force` does not re-download (delete the file to refresh). `osmium fileinfo` yields the data timestamp for `osm_timestamp`. |
| Hiking relations | `osmium tags-filter <extract> r/route=hiking` | `.cache/geofabrik/<extract>-hiking.osm.pbf` | Once per extract. Keeps relations and all referenced members (osmium's default). |
| Region polygon | `osmium getid -r -t <extract> r<id>…` piped to `osmium export -f geojsonseq --geometry-types=polygon`, then written as an Osmosis `.poly` file | `.cache/<region>/clip.poly` | One `.poly` section per outer ring, `!` sections for inner rings. Regions without `clip` use `--bbox` instead. |
| Region extract | `osmium extract --polygon clip.poly -s complete_ways` | `.cache/<region>/region.osm.pbf` | For places and curvature. |
| Region hiking extract | `osmium extract --polygon clip.poly -s smart -S types=route` on the hiking file | `.cache/<region>/hiking.osm.pbf` | Keeps every relation with a member in the region, with all its members, so border-crossing relations stay complete. |

Intermediates live under `.cache/` and follow the plan-1 skip rule (present → reused; `--force` → rebuilt). Nothing under `.cache/` is a release output.

## Pipeline layout additions

```
pipeline/src/maqs/
├── cache.py                 # .cache paths; download with md5 check; atomic writes
├── pmtiles_reader.py        # directory lookup + tile fetch for local archives (extends pmtiles_header.py)
├── geometry.py              # polyline6 encode/decode, haversine, bbox, three-point circle, resampling
├── sqlite_out.py            # metadata table, FTS5/R*Tree helpers, read-only validation
├── osm/
│   ├── extract.py           # Geofabrik fetch, tags-filter, .poly writer, osmium extract wrappers
│   └── terrain_sampler.py   # elevation along a line from <region>-terrain.pmtiles (Pillow WebP decode)
├── trails/
│   ├── model.py             # TrailRecord (the normalised record, ADR 0006)
│   ├── sources/osm.py       # adapter 1: pyosmium relation assembly, difficulty normalisation
│   ├── merge.py             # priority merge by ref + overlap; secondary references
│   └── step.py              # TrailsStep: sqlite + GeoJSONSeq + tippecanoe
├── places/step.py           # PlacesStep: nodes → sqlite + overlay; rank_score
└── curvature/
    ├── score.py             # per-vertex radius, bands, per-way score, corners
    └── step.py              # CurvatureStep
```

`steps/` keeps the runner and the tile steps. `LAYER_STEPS` grows to `basemap, terrain, trails, places, curvature, terrain-hd`; the default `--layers` becomes the first five. Step order within a region is fixed: tiles first, then trails (which reads the terrain archive), places, curvature.

## Configuration additions (`schema_version` stays 1; all new keys optional)

```yaml
curvature:                       # top level; classes and filters are configuration, not code
  highways: [motorway, trunk, primary, secondary, tertiary, unclassified, motorway_link, trunk_link, primary_link, secondary_link, tertiary_link]
  exclude_surfaces: [gravel, dirt, ground, grass, sand, unpaved, compacted, fine_gravel, mud, earth, wood, pebblestone]
regions:
  - id: veneto
    …
    trails:
      sources: [osm]               # priority order; only `osm` exists today
    expect:                        # row-count sanity ranges; validation fails outside them
      trails: [1500, 3000]
      places: [10000, 18000]
      curvature_segments: [1, 10000000]   # filled in after the first measured build
```

`expect` is absent for `test` until its first build measures it. A region with no `expect` records its counts and warns on zero rows; it does not fail. `trails.sources` defaults to `[osm]`.

## Geometry encoding (ADR 0010)

Every geometry column stores a **Google encoded polyline, precision 6** (coordinates × 10⁶, zigzag delta, base64-ish ASCII), as TEXT. About 3 bytes per coordinate against 8 for float32 pairs; sub-metre (0.11 m) precision; a 30-line decoder in Swift. Points (places, corner apexes) are stored as plain `lon`/`lat` REAL columns, not as polylines. `geometry.py` holds the encoder and decoder; tests round-trip known vectors from the published reference.

## Trails

**Normalised record** (`TrailRecord`, ADR 0006): `source`, `source_id`, `source_licence`, `source_date`, `osm_type`, `osm_id` (nullable for non-OSM sources), `ref`, `ref_rei`, `name`, `difficulty` (1–6 or null), `difficulty_scheme` (`cai_scale`, `sac_scale`, …), `difficulty_value` (original string), `network`, `operator`, `osmc_symbol`, `from_name`, `to_name`, `roundtrip`, `survey_date`, `website`, `geometry` (list of (lon, lat) legs), `geometry_status`, `anomalies` (list of strings).

**OSM adapter.** pyosmium reads `hiking.osm.pbf` with a location index: relations with `route=hiking`, their member ways (roles ignored except `alternative`/`excursion`/`connection`, which are kept but flagged), and the ways' node locations. Geometry assembly: start from the first member way, append ways that share an end node (reversing a way when its last node matches), repeat for the remaining ways to form legs; `geometry_status` is `ordered` (one leg, every way used), `gaps` (several legs or an unused way, each gap reported with the distance), or `incomplete` (a member way missing from the extract). Nothing is dropped: an `incomplete` relation keeps the legs it has. `operator` spellings for AVS are normalised (ADR 0006). When the relation has neither `cai_scale` nor `sac_scale`, the member ways' `sac_scale` is read and the highest value wins, with scheme `sac_scale:ways`.

**Difficulty normalisation** (1–6, SAC-like): `cai_scale` T→1, E→2, EE→3, EEA and EEA:F→4, EEA:PD→5, EEA:D/MD/ED→6, EAI→3; `sac_scale` hiking→1, mountain_hiking→2, demanding_mountain_hiking→3, alpine_hiking→4, demanding_alpine_hiking→5, difficult_alpine_hiking→6. Unknown values keep the original string with `difficulty` null and an anomaly.

**Ascent and descent.** From our own `<region>-terrain.pmtiles` (the archive built in the same run): each leg is resampled every 25 m, elevation is bilinear-sampled from the z12 terrarium tile under each sample (`pmtiles_reader.py` finds the tile, Pillow decodes the WebP), and climbs and descents are summed with a 5 m hysteresis so sensor-scale noise does not inflate them. When the terrain archive is absent (layer not requested) both are null and the report records it. `length_m` is the haversine sum over the legs.

**Merge.** `trails/merge.py` takes the per-source record lists in the region's priority order; a lower-priority record whose `ref` matches a higher-priority one and whose geometry overlaps it (more than half its length within 50 m) becomes a secondary reference row pointing at the winner. Tested with a synthetic second source so the seam exists before a real adapter does.

**`<region>-trails.sqlite`** (`layer_schema_version` 1):

```sql
CREATE TABLE metadata (schema_version INTEGER, layer TEXT, region TEXT, data_date TEXT, osm_timestamp TEXT, attribution TEXT);  -- one row
CREATE TABLE trails (
  id INTEGER PRIMARY KEY, source TEXT NOT NULL, source_id TEXT NOT NULL, source_licence TEXT, source_date TEXT,
  osm_type TEXT, osm_id INTEGER, ref TEXT, ref_rei TEXT, name TEXT,
  difficulty INTEGER, difficulty_scheme TEXT, difficulty_value TEXT,
  network TEXT, operator TEXT, osmc_symbol TEXT, from_name TEXT, to_name TEXT, roundtrip INTEGER, survey_date TEXT, website TEXT,
  length_m REAL NOT NULL, ascent_m REAL, descent_m REAL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
  geometry TEXT NOT NULL,            -- polyline6 legs joined by '|'
  geometry_status TEXT NOT NULL,     -- ordered | gaps | incomplete
  secondary_of INTEGER REFERENCES trails(id)
);
CREATE VIRTUAL TABLE trails_fts USING fts5(ref, name, from_name, to_name, operator, content='trails', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE trails_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
```

**`<region>-trails.pmtiles`**: tippecanoe from a GeoJSONSeq of the primary rows (one LineString or MultiLineString per trail), layer `trails`, properties `id`, `ref`, `name`, `difficulty`, `network`, `osmc_symbol`, zoom 6–14, gzip (tippecanoe's default), `-o <file>.pmtiles`. Validation expects MVT, zoom 6–14, gzip.

## Places

`PlacesStep` reads nodes from `region.osm.pbf` after `osmium tags-filter n/natural=peak,volcano,saddle n/mountain_pass=yes n/tourism=alpine_hut,wilderness_hut n/amenity=shelter n/place=village,hamlet,isolated_dwelling`. `kind` is one of `peak, volcano, saddle, pass, alpine_hut, wilderness_hut, shelter, village, hamlet, isolated_dwelling` (a saddle with `mountain_pass=yes` is `pass`). Unnamed villages, hamlets and dwellings are skipped (the brief says named); peaks and huts are kept even unnamed. `ele` is parsed as metres (plain number, or `1234 m`); unparsable values are null with an anomaly.

**`rank_score`** `= 1000 × [wikidata present] + ele` (0 when `ele` is null). Documented in data-format.md; no other inputs without updating both.

**`<region>-places.sqlite`** (`layer_schema_version` 1):

```sql
CREATE TABLE metadata (… as above …);
CREATE TABLE places (
  id INTEGER PRIMARY KEY, osm_type TEXT NOT NULL, osm_id INTEGER NOT NULL, kind TEXT NOT NULL,
  name TEXT, name_it TEXT, name_de TEXT, name_fur TEXT, name_sl TEXT,
  ele REAL, wikidata TEXT, lon REAL NOT NULL, lat REAL NOT NULL, rank_score REAL NOT NULL
);
CREATE VIRTUAL TABLE places_fts USING fts5(name, name_it, name_de, name_fur, name_sl, content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE places_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);  -- point boxes
```

**`<region>-places.pmtiles`**: layer `places`, properties `id`, `kind`, `name`, `ele`, `rank_score`, zoom 8–14, gzip.

## Curvature

`CurvatureStep` reads ways from `region.osm.pbf` after `osmium tags-filter w/highway=<configured classes>`, skipping ways whose `surface` is in `exclude_surfaces`, and ways with fewer than three nodes. One segment per OSM way.

**Formula** (normative text lives in data-format.md; ADR 0008 makes it the shared definition the Swift package will mirror):

1. Vertices closer than 5 m to the previous kept vertex are merged (noise control).
2. At every interior vertex, the radius is that of the circumcircle through the previous, current and next vertex; sign is the turn direction (left positive). Collinear triples have infinite radius.
3. **Per-way score** `= Σ segment_length × weight(radius at the segment's start vertex)`, with weight 4 for r < 30 m, 3 for 30–60, 2 for 60–100, 1 for 100–175, 0 above. Straight roads score 0.
4. **Corners**: a maximal run of consecutive interior vertices with the same sign and radius under 500 m. Apex is the vertex with the smallest radius; `min_radius_m` is the circumcircle radius of (entry vertex, apex, exit vertex); `direction` is `left` or `right`; `entry_m`, `apex_m`, `exit_m` are distances along the way from its first node.

Fixtures: a straight line scores 0 with no corners; a sampled circular arc of radius 50 m yields one corner with `min_radius_m` within 5 % of 50 and a score in band 3; an S-curve yields two corners of opposite direction.

**`<region>-curvature.sqlite`** (`layer_schema_version` 1):

```sql
CREATE TABLE metadata (… as above …);
CREATE TABLE segments (
  id INTEGER PRIMARY KEY, osm_way_id INTEGER NOT NULL, name TEXT, ref TEXT, highway TEXT NOT NULL, surface TEXT,
  oneway INTEGER NOT NULL DEFAULT 0, maxspeed TEXT, length_m REAL NOT NULL, score REAL NOT NULL,
  start_node INTEGER NOT NULL, end_node INTEGER NOT NULL,       -- adjacency across way splits (ADR 0008)
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL, geometry TEXT NOT NULL
);
CREATE TABLE corners (
  id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL REFERENCES segments(id), ordinal INTEGER NOT NULL,
  apex_lon REAL NOT NULL, apex_lat REAL NOT NULL, min_radius_m REAL NOT NULL, direction TEXT NOT NULL,
  entry_m REAL NOT NULL, apex_m REAL NOT NULL, exit_m REAL NOT NULL
);
CREATE INDEX corners_segment ON corners(segment_id, ordinal);
CREATE VIRTUAL TABLE segments_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
CREATE VIRTUAL TABLE corners_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);  -- point boxes
```

No overlay tiles for curvature in this plan.

## Common SQLite rules

Written with Python's `sqlite3` into a temporary file, `VACUUM`ed, then renamed into place. `metadata` has exactly one row: `schema_version` (the layer's `layer_schema_version`), `layer`, `region`, `data_date` (the build's UTC date), `osm_timestamp` (from the extract's header), `attribution` (`© OpenStreetMap contributors (ODbL)`). FTS5 uses `unicode61 remove_diacritics 2`; R*Tree boxes are lon/lat in degrees. OSM ids are stored with their type, never collapsed. Page size and journal mode are left default; files are opened read-only by consumers.

## Validation and report

For every SQLite output: size cap (1.9 GiB), `PRAGMA integrity_check` is `ok`, the expected tables and virtual tables exist, `metadata` has one row whose `layer` and `region` match, row counts recorded per table, counts inside the region's `expect` range when present (fail outside), a warning on zero rows, SHA-256. Overlays are validated as tile archives with their own zoom expectations. The curvature size against the 30 MB target (sum over the three single launch regions, and `triveneto` alone) is reported, not enforced.

`build-report.json` stays `report_version` 1 (additive): each output gains `rows` (table → count) when it is a SQLite file, and each step gains `anomalies` (a list of `{kind, id, message}`, capped at 1,000 entries with the total count) for flagged relations, unparsable tags and skipped features. Data anomalies never fail the build; size, schema, checksum and `expect` violations do.

## CI

`pipeline.yml`'s smoke job builds the test region with all five standard layers. The Geofabrik extract (625 MB) is downloaded once per run. A first step fetches only the tiny `.md5` sidecar and uses its value as the `actions/cache` key for the `.cache/geofabrik/` directory, so a run on an unchanged extract hits the cache and skips the download (Geofabrik rebuilds daily, so most monthly runs miss; locally the file is reused). The network test asserts the five outputs exist and validate. The 30-minute job timeout stays; expected cost is about one more minute for the download and under a minute for the three layers on the test region. The artifact `test-region-fixtures` now carries the SQLite files and overlays the Swift tests will read.

## Tests

- `test_geometry.py`: polyline6 round trip against reference vectors, haversine on known pairs, three-point radius on known triples (collinear → infinity).
- `test_osm_extract.py`: `.poly` writer from a GeoJSONSeq fixture (outer and inner rings); argv of every osmium call; md5 verification accepts and rejects.
- `test_trails_osm.py`: relation assembly on hand-built PBF fixtures written with pyosmium's writer: ordered, reversed way, gap, missing member, roles; difficulty mapping table; `sac_scale` from ways; AVS operator normalisation.
- `test_trails_merge.py`: synthetic second source wins and loses by priority; overlap threshold.
- `test_terrain_sampler.py`: bilinear sampling and ascent/descent hysteresis on a generated single-tile terrain archive (the plan-1 `write_pmtiles` helper extended with a real WebP tile).
- `test_places.py`: kind mapping, `ele` parsing, `rank_score`, unnamed-village skip.
- `test_curvature.py`: the three fixtures above, vertex merging, band weights, corner boundaries.
- `test_sqlite_out.py`: schemas created as documented, FTS query with diacritics, R*Tree query, metadata row, read-only validation rejects a missing table and an out-of-range count.
- `test_steps_data.py`: each step's `outputs()`, `expectation()` and argv with `tools.run` stubbed; skip rule.
- `test_integration_network.py`: extended to the five layers.

No test downloads anything; PBF fixtures are generated in code and stay under a few kB.

## Documentation

- `docs/data-format.md`: new sections for the geometry encoding, the three SQLite schemas (each with `layer_schema_version` 1 and the compatibility rule: additive columns do not bump; renames or removals do), the two overlays, the ascent/descent, `rank_score` and corner formulas, the report additions.
- `docs/architecture.md`: the data-layer flow, cache layout, step order and the terrain dependency of trails.
- `docs/decisions.md`: ADR 0010 (geometry encoding), ADR 0011 (the data-layer formulas and thresholds: 25 m / 5 m hysteresis, `rank_score`, 5 m vertex merge, 500 m corner cutoff, bands) with the measured counts and sizes, and the curvature-size result against ADR 0008.
- `CLAUDE.md`: commands and traps that change (default layers, the cache refresh rule, the `.poly` multi-section fact).
- `pipeline/bootstrap.sh`: unchanged (osmium and tippecanoe are already installed); `pyproject.toml` gains `osmium` and `pillow` as runtime dependencies (ADR 0010 records the dependency decision: BSD-2 and MIT-CMU, both maintained, both wheels on macOS and Ubuntu).

## Risks

- **Relation assembly quality.** OSM hiking relations are messy; the first Veneto build will show how many land in `gaps`/`incomplete`. They are reported, not fixed; the Swift reader renders legs as they are.
- **Curvature size.** All configured roads for `triveneto` may exceed 30 MB. The plan measures first; the ADR decides.
- **Geofabrik etiquette.** One download per run, `curl -L`, md5 check; CI caches by md5. No retries in a loop.
- **pyosmium location index memory.** A `flex_mem` index on the 625 MB extract fits a 16 GB runner; the per-region extracts are far smaller.
- **`.poly` even-odd rule.** Adjacent admin polygons share borders only, so a multi-section `.poly` is safe; the first `triveneto` cut is checked against the three single regions' counts.
