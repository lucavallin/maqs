# Data formats

This document lists every file maqs publishes, with a version for each format. A format change bumps the version named in its section and states the compatibility rule. The pipeline builds the tile archives, the trails and places overlay archives, the three SQLite layers (trails, places, curvature), the build report and `manifest.json`. `config/sources.json` is kept by hand and validated in CI.

Every layer file carries its layer's `layer_schema_version` in its name: `<label>-<layer>.v<N>.<ext>`. `<label>` is the region id, or `base-<pack>` for a base pack; `<layer>` is `basemap`, `terrain`, `terrain-hd`, `trails`, `places` or `curvature`; `<ext>` is `pmtiles` or `sqlite` (`output_name` in `pipeline/src/maqs/layers.py`). Two versions of one layer can therefore sit side by side in a release (see the [compatibility rule](#compatibility-rule)). All files of a layer share its version: the trails SQLite file and the trails overlay are both `.v1.` today.

## Tile archives (PMTiles v3)

Every tile output is a [PMTiles v3](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md) archive with `tile_compression` and `internal_compression` each gzip or none. The archives `versatiles` writes (basemap, terrain, base packs) are clustered, with gzip internal compression. MapLibre Native reads gzip or uncompressed tiles only and rejects brotli and zstd, so the pipeline recompresses VersaTiles' brotli basemap tiles to gzip.

Version 1 of the tile layers, as `pipeline/src/maqs/layers.py` records it:

- **basemap** (`layer_schema_version` 1): Shortbread 1.0 MVT, gzip tile compression, z0–14. A base pack is the same format up to its `max_zoom`.
- **terrain** (1): terrarium-encoded DEM, WebP, 512 px tiles, z0–12, tile compression none.
- **terrain-hd** (1): the same terrarium encoding at z13–`hd_max_zoom`, in the image format Mapterhorn stores (WebP or PNG).

A change of encoding, tile schema or zoom range bumps the layer's version. The table gives each archive's extent.

| File | Layer | Tile type | Zoom | Tile compression | Source and extent |
|---|---|---|---|---|---|
| `<region>-basemap.v1.pmtiles` | basemap | MVT, Shortbread 1.0 (OSM plus ESA WorldCover landcover) | 0–14 | gzip | `download.versatiles.org/osm-landcover.versatiles`: the region's bbox plus a ring of `bbox_border` tiles at every zoom (default 1, 0 for `test`) |
| `<region>-terrain.v1.pmtiles` | terrain | WebP 512 px, terrarium-encoded DEM | 0–12 | none | `download.versatiles.org/elevation.versatiles` (Mapterhorn's build), same bbox and border as the basemap |
| `<region>-terrain-hd.v1.pmtiles` | terrain-hd (opt-in) | terrarium, as Mapterhorn stores it (WebP or PNG accepted) | 13–`hd_max_zoom` (13 by default) | gzip or none | `download.mapterhorn.com/6-<x>-<y>.pmtiles`, the region's bbox, merged into one archive when the bbox spans several; no border |
| `base-<pack>-basemap.v1.pmtiles` | base pack, bundled inside apps | MVT, Shortbread 1.0 | 0–`max_zoom` (10 by default) | gzip | as the basemap, over the union bbox of the pack's regions; no border |

Region outputs are written to `dist/<region>/`, every base pack to `dist/base/`.

Terrarium decoding: `elevation_m = (R * 256 + G + B / 256) - 32768`. The tiles are 512 px, so at zoom 12 one pixel is about 13 m at 46° N (a z12 tile is about 6.8 km wide there).

The archive metadata is a JSON object. Basemap archives carry `tile_schema: "shortbread@1.0"`, terrain archives `tile_schema: "dem/terrarium"` and `tile_size: 512`. Both carry the upstream `attribution` string. The basemap also carries `planetiler:osm:osmosisreplicationtime`, the date of the OSM data in the VersaTiles build, which the build report copies out as `source_data_date`. The terrain archive has no date key, so terrain's `source_data_date` is null. `versatiles probe` shows the metadata; the pipeline reads it with its own header reader (`pipeline/src/maqs/pmtiles_header.py`).

Measured sizes per region are in [`docs/decisions.md`](decisions.md), ADR 0009.

## Geometry encoding

Every line in the SQLite layers is a [Google encoded polyline](https://developers.google.com/maps/documentation/utilities/polylinealgorithm) at precision 6, stored as TEXT ([ADR 0010](decisions.md)). Each coordinate is multiplied by 10⁶ and rounded. Each value is stored as the difference from the previous vertex, zigzag-encoded and split into five-bit groups, one ASCII character per group (`?` to `~`, codes 63–126). A vertex is written latitude first, as the format specifies; decoders hand it back as lon/lat. Precision 6 resolves 10⁻⁶ degrees, about 0.11 m of latitude. `pipeline/src/maqs/geometry.py` holds the encoder and decoder, and its tests check them against Google's published precision-5 example.

Worked example: the point lon 12.25, lat 46.1 encodes as `_av|vA_xtjV`, where `_av|vA` is 46,100,000 and `_xtjV` is 12,250,000. A second point at lon 12.2501, lat 46.1002 appends `oKgE` (+200, then +100): `_av|vA_xtjVoKgE`.

The first point already contains `|`, so `|` cannot separate two polylines. A trail's legs are joined by `;` (code 59, outside the alphabet); a road segment is a single polyline. Points (places, corner apexes) are not encoded: they are REAL columns in WGS 84 degrees (`lon` and `lat`, `apex_lon` and `apex_lat`).

## Overlay tiles

Two PMTiles v3 archives of gzip-compressed MVT tiles, written by tippecanoe from a GeoJSONSeq file the step generates. A feature's `id` property is the `id` of its row in the matching SQLite file, so a tapped feature leads to the full record.

| File | MVT layer | Zoom | Features | Properties |
|---|---|---|---|---|
| `<region>-trails.v1.pmtiles` | `trails` | 6–14 | one per primary trail with geometry: a LineString, or a MultiLineString when the trail has several legs | `id`, `ref`, `name`, `difficulty`, `network`, `osmc_symbol` |
| `<region>-places.v1.pmtiles` | `places` | 8–14 | one Point per place | `id`, `kind`, `name`, `ele`, `rank_score` |

Secondary trails (`secondary_of` set) and trails without geometry are in the SQLite file only. Apart from the layer name and the zoom range, tippecanoe runs with its defaults, so trail lines are simplified to each tile's resolution. The places overlay adds `-r1` (drop rate 1): every place is in every zoom from 8 to 14, and the style decides which to label, with `rank_score` for priority. Without it tippecanoe would keep about one point in 2.5 per zoom level below 14, chosen by density, not by `rank_score`. Measured on Triveneto (2026-10-15): all 29,198 places are present at z8, z11 and z14, in 7,515,620 bytes and 15,410 tiles. An overlay has its layer's `layer_schema_version`, 1 for both: renaming the MVT layer, changing the zoom range, or renaming or removing a property bumps `trails` or `places`.

## SQLite layers

Three files per region: `<region>-trails.v1.sqlite`, `<region>-places.v1.sqlite` and `<region>-curvature.v1.sqlite`. The schemas live in `pipeline/src/maqs/sqlite_out.py`; the DDL below is copied from it.

Rules shared by all three:

- **Writing.** Python's `sqlite3` builds the file as `<name>.sqlite.tmp`: schema, rows, the metadata row, an FTS5 `rebuild`, a commit, then `VACUUM`. The finished file is renamed into place, so a crash never leaves a half-written file under the final name. Page size and journal mode are SQLite's defaults.
- **Metadata.** Every file has this table with exactly one row. `schema_version` is the layer's `layer_schema_version`; `layer` is `trails`, `places` or `curvature`; `region` is the region id; `data_date` is the UTC date of the build run (`YYYY-MM-DD`), one value for the whole run and the same as the manifest entry's `data_date`; `osm_timestamp` is the `osmosis_replication_timestamp` in the Geofabrik extract's header (null when the header has none); `attribution` is `© OpenStreetMap contributors (ODbL)`.

  ```sql
  CREATE TABLE metadata (
    schema_version INTEGER NOT NULL, layer TEXT NOT NULL, region TEXT NOT NULL,
    data_date TEXT NOT NULL, osm_timestamp TEXT, attribution TEXT NOT NULL
  );
  ```

- **Ids.** `id` is the row's position in write order, from 1. The R\*Tree tables use the same `id` and the FTS5 tables use it as `rowid`. An `id`, and the overlay feature `id` that points at it, is valid only within one build: the same trail, place or segment can get another `id` in the next release. A reader that keeps a reference across releases stores the source key instead: `source` and `source_id` (or `osm_type` and `osm_id`) for a trail, `osm_type` and `osm_id` for a place, `osm_way_id` for a segment. OSM ids are stored as they are, with their type in a column (`osm_type`) or in the column name (`osm_way_id`, `start_node`), never folded into one number space.
- **Text search.** FTS5 with `tokenize='unicode61 remove_diacritics 2'`, as external-content tables over the main table (`content='…', content_rowid='id'`). The index keeps no copy of the text: match in the FTS table, then read the row from the main table by `rowid`.
- **Spatial search.** R\*Tree tables with columns `(id, min_lon, max_lon, min_lat, max_lat)` in WGS 84 degrees; a point is a box whose minimum equals its maximum.
- **Units.** Lengths and distances are metres along the Earth's surface, summed haversine distances with a radius of 6,371,008.8 m; elevation is ignored.
- **Readers** open the files read-only and never write to them.

Compatibility rule, the same for every layer: adding a column or a table keeps the `layer_schema_version`, so readers select columns by name and ignore the ones they do not know. Renaming or removing a column or table, or changing what a column means, bumps it.

### Trails (`layer_schema_version` 1)

```sql
CREATE TABLE trails (
  id INTEGER PRIMARY KEY, source TEXT NOT NULL, source_id TEXT NOT NULL,
  source_licence TEXT, source_date TEXT,
  osm_type TEXT, osm_id INTEGER, ref TEXT, ref_rei TEXT, name TEXT,
  difficulty INTEGER, difficulty_scheme TEXT, difficulty_value TEXT,
  network TEXT, operator TEXT, osmc_symbol TEXT, from_name TEXT, to_name TEXT, roundtrip INTEGER,
  survey_date TEXT, website TEXT,
  length_m REAL NOT NULL, ascent_m REAL, descent_m REAL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
  -- geometry: one encoded polyline per leg, legs joined by ';' (outside the polyline alphabet)
  geometry TEXT NOT NULL, geometry_status TEXT NOT NULL,
  secondary_of INTEGER REFERENCES trails(id)
);
CREATE VIRTUAL TABLE trails_fts USING fts5(ref, name, from_name, to_name, operator,
  content='trails', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE trails_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
```

One row per trail record from the region's trail sources (`trails.sources` in `config/regions.yaml`, OSM only today): primaries first, in source-priority order, then secondaries. The OSM adapter writes one record per `route=hiking` relation in the region's hiking extract, by ascending relation id, and drops none. A trail without geometry has an empty `geometry`, null bbox columns, no R\*Tree row and no overlay feature.

| Column | Meaning |
|---|---|
| `source`, `source_id`, `source_licence`, `source_date` | provenance ([ADR 0006](decisions.md)). OSM: `osm`, `relation/<id>`, `ODbL 1.0` and the extract's `osm_timestamp` |
| `osm_type`, `osm_id` | `relation` and the relation id; null for a source other than OSM |
| `ref`, `ref_rei`, `name`, `network`, `osmc_symbol`, `from_name`, `to_name`, `survey_date`, `website` | the relation's `ref`, `ref:REI`, `name`, `network`, `osmc:symbol`, `from`, `to`, `survey:date` and `website` tags, as tagged |
| `operator` | the `operator` tag, trimmed. A value that is `AVS` or contains `Alpenverein Südtirol` (also spelt `Suedtirol` or `Sudtirol`, any case) becomes `Alpenverein Südtirol` |
| `roundtrip` | 1 for `yes`, `true` or `1`; 0 for `no`, `false` or `0`; otherwise null |
| `difficulty`, `difficulty_scheme`, `difficulty_value` | the grade 1–6, the scheme it came from, and the original value (below) |
| `length_m` | the summed length of the legs; gaps between legs are not counted |
| `ascent_m`, `descent_m` | metres climbed and descended along the legs (below); null when unknown, never 0 for unknown |
| `min_lon` … `max_lat` | the bbox of all legs |
| `geometry` | one polyline per leg, legs joined by `;` |
| `geometry_status` | `ordered`: one continuous leg that uses every member way. `gaps`: several legs, no member way missing. `incomplete`, whatever the number of legs: a member way is missing from the extract (or has fewer than two located nodes), or the relation has no way at all |
| `secondary_of` | null for a primary; for a secondary, the `id` of the primary it duplicates |

**Geometry assembly (OSM adapter).** Member ways are chained into legs by shared end nodes. A leg starts at the first member way not yet used and grows at either end with any unused way that shares an end node, until none fits; then the next leg starts. Each way is used once. Each finished leg is then turned to follow member order (a way listed twice counts at its first position). An open leg starts at whichever of its two end ways is listed first. A closed loop starts with its first-listed way and runs towards the earlier-listed of that way's two neighbours. A leg of one way, and a loop of two ways, keep the direction of the leg's first way as stored, because member order cannot tell their direction. A way the leg walks against its stored direction is flagged `reversed`. Ways with the role `alternative`, `excursion` or `connection` stay in the geometry and are flagged. Node members are ignored. Relation members (superroutes) are ignored and flagged. Nodes without a location are left out of a way. Every irregularity becomes an anomaly in the build report.

**Merge.** Records arrive per source, in `trails.sources` priority order. A record whose `ref` matches that of a primary from a higher-priority source (whitespace collapsed, case ignored) becomes a secondary of the first such primary it follows on the ground: both are resampled every 25 m, leg by leg, and more than half of the record's points must lie within 62.5 m (50 m plus half the step) of one of the primary's points. Records without a `ref`, and records from the same source, are never merged. With OSM as the only source, every row is a primary.

**Difficulty.** The relation's `cai_scale` wins (compared in upper case), then its `sac_scale`, then the hardest `sac_scale` on its member ways, with scheme `sac_scale:ways`. An unknown value on the relation keeps `difficulty_scheme` and `difficulty_value`, leaves `difficulty` null, adds a `difficulty` anomaly and does not fall back to the next scheme. Unknown values on member ways are ignored.

| `difficulty` | `cai_scale` | `sac_scale` |
|---|---|---|
| 1 | `T` | `hiking` |
| 2 | `E` | `mountain_hiking` |
| 3 | `EE`, `EAI` | `demanding_mountain_hiking` |
| 4 | `EEA`, `EEA:F` | `alpine_hiking` |
| 5 | `EEA:PD` | `demanding_alpine_hiking` |
| 6 | `EEA:D`, `EEA:MD`, `EEA:ED` | `difficult_alpine_hiking` |

**Ascent and descent.** Each leg is resampled every 25 m, plus its end points. A sample's elevation comes from `<region>-terrain.v1.pmtiles` in the same output directory, at the archive's maximum zoom (12): the terrarium value interpolated bilinearly between the four nearest pixel centres of the tile under the sample, clamped at the tile's edge (no interpolation across tiles). Along a leg, a reference elevation moves only when a sample is more than 5 m above or below it; the whole difference then counts as ascent or descent. The legs' totals are summed. Samples without a terrain tile are skipped, so:

- with no terrain archive in the output directory, both columns are null for every trail (anomaly `terrain_missing`); when the archive cannot be read, they are null from that point on: for every trail if it cannot be opened, otherwise for the trail being sampled and every later one (`terrain_unreadable`);
- when no sample of a trail has a tile, both are null (`terrain_no_coverage`);
- when only some samples have a tile, as for a relation that runs beyond the region's terrain coverage (its bbox plus the tile border), the values cover only those samples (`terrain_gap`), while `length_m` is the whole relation (decision open, ADR 0011).

### Places (`layer_schema_version` 1)

```sql
CREATE TABLE places (
  id INTEGER PRIMARY KEY, osm_type TEXT NOT NULL, osm_id INTEGER NOT NULL, kind TEXT NOT NULL,
  name TEXT, name_it TEXT, name_de TEXT, name_fur TEXT, name_sl TEXT,
  ele REAL, wikidata TEXT, lon REAL NOT NULL, lat REAL NOT NULL, rank_score REAL NOT NULL
);
CREATE VIRTUAL TABLE places_fts USING fts5(name, name_it, name_de, name_fur, name_sl,
  content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE places_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
```

One row per OSM node of a kind below, by ascending node id; `osm_type` is always `node`. The first matching row of the table decides `kind`:

| Tags | `kind` |
|---|---|
| `mountain_pass=yes`, with or without `natural=saddle` | `pass` |
| `natural=peak`, `natural=volcano`, `natural=saddle` | `peak`, `volcano`, `saddle` |
| `tourism=alpine_hut`, `tourism=wilderness_hut` | `alpine_hut`, `wilderness_hut` |
| `amenity=shelter` | `shelter` |
| `place=village`, `place=hamlet`, `place=isolated_dwelling`, with a `name` tag | `village`, `hamlet`, `isolated_dwelling` |

A village, hamlet or isolated dwelling without a `name` tag is skipped (a `name:*` tag alone does not count); every other kind is kept with or without a name. A node without a location is skipped. `name`, `name_it`, `name_de`, `name_fur` and `name_sl` are the `name`, `name:it`, `name:de`, `name:fur` and `name:sl` tags; `wikidata` is the tag as written; `lon` and `lat` are the node's position.

**`ele`** is the `ele` tag in metres: an optional minus sign, digits, an optional decimal part, an optional unit `m`, `meters` or `metres` (any case), spaces around allowed. A comma followed by exactly three digits groups thousands (`1,763` is 1763); any other comma is a decimal comma (`1,5` is 1.5); a dot is always decimal. Anything else, such as `ca. 1700` or `5000 ft`, is null with an `ele` anomaly.

**`rank_score`** is the label priority:

```
rank_score = 1000 × [wikidata present] + ele
```

with `ele` taken as 0 when null and "wikidata present" meaning a non-empty `wikidata` tag. A 1,763 m peak with a `wikidata` tag scores 2763, the same peak without one 1763, an unnamed shelter with neither 0. A place tagged below sea level (`ele` < 0) can score below 0. Adding an input to the formula means changing this section and its ADR together ([ADR 0011](decisions.md)).

### Curvature (`layer_schema_version` 1)

```sql
CREATE TABLE segments (
  id INTEGER PRIMARY KEY, osm_way_id INTEGER NOT NULL, name TEXT, ref TEXT,
  highway TEXT NOT NULL, surface TEXT,
  oneway INTEGER NOT NULL DEFAULT 0, maxspeed TEXT, length_m REAL NOT NULL, score REAL NOT NULL,
  start_node INTEGER NOT NULL, end_node INTEGER NOT NULL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL, geometry TEXT NOT NULL
);
CREATE TABLE corners (
  id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL REFERENCES segments(id),
  ordinal INTEGER NOT NULL,
  apex_lon REAL NOT NULL, apex_lat REAL NOT NULL, min_radius_m REAL NOT NULL,
  direction TEXT NOT NULL,
  entry_m REAL NOT NULL, apex_m REAL NOT NULL, exit_m REAL NOT NULL
);
CREATE INDEX corners_segment ON corners(segment_id, ordinal);
CREATE VIRTUAL TABLE segments_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
CREATE VIRTUAL TABLE corners_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
```

**`segments`** has one row per OSM way whose `highway` is one of `curvature.highways` and whose `surface` is not one of `curvature.exclude_surfaces` (a way without `surface` is kept). Both lists are in `config/regions.yaml`. Rows follow the extract's way order. A way with fewer than two located nodes is skipped (`too_short` anomaly); a way with some unlocated nodes is kept and joined over them (`unlocated_nodes`). Two-node ways and straight ways are kept with score 0 and no corners, because they carry the adjacency a lookahead follows. A closed way, such as a roundabout drawn as one ring, is scored like any other way: its vertices all turn the same way, so it becomes a tight corner (a 20 m ring scores as one corner of radius 20 m); its first and last vertex, the same node, have no radius. Nothing marks a roundabout, and `oneway` is not inferred from `junction=roundabout`.

| Column | Meaning |
|---|---|
| `osm_way_id` | the way id |
| `name`, `ref`, `highway`, `surface`, `maxspeed` | the way's tags, as tagged |
| `oneway` | 1 for `oneway=yes`, `true` or `1` (traffic in the drawing direction), −1 for `oneway=-1` (against it), otherwise 0. Only the explicit tag counts: a roundabout or motorway without it is 0 |
| `start_node`, `end_node` | the OSM ids of the way's first and last located node. Segments that share a node id meet there; this is how a lookahead follows a road across way splits ([ADR 0008](decisions.md)) |
| `length_m` | the length of the stored geometry |
| `score` | the curvature score below, in metres of weighted length |
| `min_lon` … `max_lat`, `geometry` | the bbox and the polyline of the vertices left after the 5 m merge |

**`corners`** has one row per corner: `segment_id`, `ordinal` (0, 1, … in way order), the apex position `apex_lon`/`apex_lat`, `min_radius_m`, `direction` (`left` or `right`), and `entry_m`, `apex_m`, `exit_m`, the distances along the segment's stored geometry from its first vertex. All of it follows the way's drawing direction: for travel the other way, `left` and `right` swap and a distance d becomes `length_m − d`.

**Formula.** ADR 0008 makes this the one corner definition maqs uses. This text is normative; `pipeline/src/maqs/curvature/score.py` implements it.

1. **Vertex merge.** Walking from the first vertex, a vertex closer than 5 m to the last kept one is dropped; the last vertex is always kept. Then, from the end: while more than two vertices remain and the second-to-last is closer than 5 m to the last, the second-to-last is dropped. Consecutive vertices end up at least 5 m apart; the only exception is a way left with just its two end vertices, closer than 5 m to each other (a way shorter than 5 m, or one that doubles back, such as 0 m, 6 m, 4 m along a line). The stored geometry, `length_m`, the score and the corner distances all use the merged vertices.
2. **Radius.** At each interior vertex B, with neighbours A and C, the radius of the circle through A, B and C, computed in a local plane centred on B: x = Δlon × 111,320 × cos(lat_B), y = Δlat × 110,574, in metres. The turn is left when C lies to the left of the line from A through B, right otherwise. Collinear or coincident points (twice the triangle area under 10⁻⁹ m²) have an infinite radius and no turn.
3. **Band weight.** 4 under 30 m; 3 from 30 m to under 60 m; 2 from 60 m to under 100 m; 1 from 100 m to under 175 m; 0 from 175 m and for straight vertices.
4. **Score.** score = Σ over interior vertices B of weight(radius at B) × (|AB| + |BC|) / 2. Each vertex weighs half of each adjacent segment, so a way scores the same in both directions. The end vertices have no radius, so half of the first and half of the last segment weigh 0. With fewer than three merged vertices the score is 0.
5. **Corners.** A corner is a maximal run of consecutive interior vertices that turn the same way with a radius under 500 m. A straight vertex, a radius of 500 m or more, or a turn the other way ends the run; an opposite turn starts the next run at once. The apex is the run's vertex with the smallest radius (the first one on a tie); entry and exit are the vertices just before and just after the run. `min_radius_m` is the radius of the circle through entry, apex and exit (the apex's own radius if those three are collinear), so it can exceed both the apex vertex's radius and 500 m. `direction` is the run's turn. When the turn flips from one vertex to the next, the two corners overlap by one segment: the first corner's exit is the second run's first vertex, and the second corner's entry is the first run's last vertex.

## `manifest.json` (`manifest_version` 1)

One file per data release, uploaded as the release asset `manifest.json`. Clients read it from `https://github.com/lucavallin/maqs/releases/latest/download/manifest.json`, and that is the only file they fetch through `latest`: every `url` inside the manifest names the release tag its file was uploaded under, so a manifest keeps pointing at its own files after a newer release becomes latest.

`maqs manifest --release <tag>` writes it from the build reports in `dist/` (`pipeline/src/maqs/manifest.py`) and validates it against `config/schemas/manifest.schema.json` before writing. The schema is the format's single source of truth; the checks the command adds are under [Validation rules](#validation-rules).

The example is real, abridged: the manifest CI assembles from the `test` build and the `triveneto` base pack, written on 2026-10-16 by `maqs manifest --release data-ci --regions test`. A `data-ci` manifest exists only in CI and is never published (below). A real release is tagged `data-YYYY-MM` and lists every region that is not a fixture.

```jsonc
{
  "manifest_version": 1,
  "created_at": "2026-10-16T09:54:53Z",
  "release": "data-ci",
  "shortbread_version": "1.0",
  "attribution": [
    { "text": "© OpenStreetMap contributors", "licence": "ODbL 1.0", "url": "https://www.openstreetmap.org/copyright",
      "layers": ["basemap", "trails", "places", "curvature"] },
    { "text": "CC BY 4.0 ESA WorldCover 2021", "licence": "CC BY 4.0", "url": "https://esa-worldcover.org/en/data-access",
      "layers": ["basemap"] },
    { "text": "© Mapterhorn", "licence": "multiple open licences, listed at url", "url": "https://mapterhorn.com/attribution",
      "layers": ["terrain", "terrain-hd"] }
  ],
  "regions": [
    {
      "id": "test",
      "name": { "it": "Nevegal (test)", "en": "Nevegal (test)" },
      "bbox": [12.21, 46.08, 12.29, 46.13],
      "layers": {
        "basemap": [
          {
            "layer_schema_version": 1,
            "file": "test-basemap.v1.pmtiles",
            "url": "https://github.com/lucavallin/maqs/releases/download/data-ci/test-basemap.v1.pmtiles",
            "bytes": 1617480,
            "sha256": "748b46de5a711f228bbd3afcbecf2c7713a386d60cc2417dd46cceef65bdb952",
            "data_date": "2026-10-16",
            "osm_timestamp": "2026-06-07T23:59:58Z"
          }
        ],
        "terrain": [
          {
            "layer_schema_version": 1,
            "file": "test-terrain.v1.pmtiles",
            "url": "https://github.com/lucavallin/maqs/releases/download/data-ci/test-terrain.v1.pmtiles",
            "bytes": 1496730,
            "sha256": "e24d222d07bcd861eb9c66f73bc0e2c902f9f41b94d64cd9131c9105f062318d",
            "data_date": "2026-10-16",
            "osm_timestamp": null
          }
        ],
        "trails": [
          {
            "layer_schema_version": 1,
            "file": "test-trails.v1.sqlite",
            "url": "https://github.com/lucavallin/maqs/releases/download/data-ci/test-trails.v1.sqlite",
            "bytes": 126976,
            "sha256": "e1356b0d03031dbcfa714401fa65b3afbf299b9ed3c461343a23efeeba0fd137",
            "data_date": "2026-10-16",
            "osm_timestamp": "2026-10-14T20:21:12Z"
          },
          {
            "layer_schema_version": 1,
            "file": "test-trails.v1.pmtiles",
            "url": "https://github.com/lucavallin/maqs/releases/download/data-ci/test-trails.v1.pmtiles",
            "bytes": 190928,
            "sha256": "bad2caf361edea7d89305a485ae882782f3dd384d44125c0b9903dad431abb8d",
            "data_date": "2026-10-16",
            "osm_timestamp": null,
            "role": "overlay"
          }
        ],
        // "places": the same pair as trails, test-places.v1.sqlite then test-places.v1.pmtiles with "role": "overlay"
        // "curvature": one entry, test-curvature.v1.sqlite
      }
    }
  ],
  "base": [
    {
      "id": "triveneto",
      "regions": ["triveneto"],
      "max_zoom": 10,
      "layers": {
        "basemap": [
          {
            "layer_schema_version": 1,
            "file": "base-triveneto-basemap.v1.pmtiles",
            "url": "https://github.com/lucavallin/maqs/releases/download/data-ci/base-triveneto-basemap.v1.pmtiles",
            "bytes": 13165829,
            "sha256": "75430f171e1c1edc7a9678cb47becb02ecec94612335e19ccd319258b8dd0f91",
            "data_date": "2026-10-16",
            "osm_timestamp": "2026-06-07T23:59:58Z"
          }
        ]
      }
    }
  ]
}
```

The top level has exactly these fields. The schema sets `additionalProperties: false` on every object except region `name`, which allows further language keys: the producer is strict, while clients ignore what they do not know ([compatibility rule](#compatibility-rule)).

| Field | Rule |
|---|---|
| `manifest_version` | 1 |
| `created_at` | when `maqs manifest` ran, UTC, `YYYY-MM-DDTHH:MM:SSZ`; never older than the newest build report's `built_at` |
| `release` | the release tag: `data-YYYY-MM` with a month from 01 to 12, or `data-ci` in CI |
| `shortbread_version` | `"1.0"`, the Shortbread version of the newest basemap entries ([ADR 0001](decisions.md)). While a basemap bump is carried over, the older entries can follow another Shortbread version, so a client picks basemap files by `layer_schema_version` and reads which Shortbread version each basemap version means under [Tile archives](#tile-archives-pmtiles-v3) |
| `attribution` | the credits, at least one entry |
| `regions` | at least one region, in `config/regions.yaml` order |
| `base` | the base packs, in `config/regions.yaml` order; may be empty |

**Attribution.** Each entry has `text`, the display string verbatim from [`DATA_LICENSE.md`](../DATA_LICENSE.md) (a test checks that they agree); `licence`; `url`, an HTTPS link; and `layers`, the layers that need the credit (at least one, no repeats). The three entries are constants in `manifest.py` and are the same in every manifest: OpenStreetMap for basemap, trails, places and curvature, ESA WorldCover for basemap, Mapterhorn for terrain and terrain-hd.

**Region.** `id`, lowercase kebab-case (`^[a-z0-9]+(-[a-z0-9]+)*$`); `name`, with non-empty `it` and `en` (the schema allows further language keys, the pipeline writes these two); `bbox`, the four numbers `[lon_min, lat_min, lon_max, lat_max]` from `regions.yaml`; `layers`, with a non-empty list of entries for each of `basemap`, `terrain`, `trails`, `places` and `curvature`, plus `terrain-hd` when the region was built with it, and no other key.

A `data-YYYY-MM` manifest lists every region in `regions.yaml` that is not `fixture: true`, and `maqs manifest` refuses `--regions` for such a tag. `data-ci` exists so that CI can assemble and validate a manifest from the `test` build. The `release` and `url` patterns accept it, and `maqs manifest --release data-ci` requires `--regions <ids>` and lists exactly those regions, fixtures included. Its URLs point at a release that does not exist, so a `data-ci` manifest is never published.

**Base pack.** `id`; `regions`, the ids of the regions it covers (at least one); `max_zoom` (0–14); and `layers` with `basemap` only ([ADR 0007](decisions.md)), whose file is `base-<pack>-basemap.v<N>.pmtiles`. Every configured base pack is listed, in a `data-ci` manifest too.

**Entry.** One file of a layer:

| Field | Rule |
|---|---|
| `layer_schema_version` | integer ≥ 1, the version in the file name |
| `file` | the asset name, `<label>-<layer>.v<N>.<ext>`, matching `^[a-z0-9]+(-[a-z0-9]+)*-(basemap\|terrain\|terrain-hd\|trails\|places\|curvature)\.v[1-9][0-9]*\.(pmtiles\|sqlite)$` (no `.v0.`) |
| `url` | `https://github.com/lucavallin/maqs/releases/download/<tag>/<asset>`, where `<tag>` is `data-YYYY-MM` (month 01 to 12) or `data-ci` and `<asset>` matches the `file` pattern; never `latest`. The schema cannot tie `url` to the entry's `file` or to `release`, so `maqs manifest` checks that the last path segment is `file`. It builds each new URL from `release` and `file`, and an entry carried over from the previous release keeps that release's tag |
| `bytes` | the file size, from 1 to 2,040,109,465 (1.9 GiB) |
| `sha256` | 64 lowercase hex digits |
| `data_date` | `YYYY-MM-DD`: the UTC date of the build run that wrote the region's report, also for an output that run skipped because it already existed. It is one value per build run, taken when the run starts, so a run that crosses midnight does not mix two dates. In CI `dist/` starts empty, so this is the date of the build run that produced the release |
| `osm_timestamp` | `YYYY-MM-DDTHH:MM:SSZ` or null; the build report's `source_data_date`. Basemap and base packs: the OSM replication time of the VersaTiles build (`planetiler:osm:osmosisreplicationtime`), which lags the Geofabrik data by months ([ADR 0004](decisions.md)). Trails, places and curvature SQLite files: the Geofabrik extract's replication timestamp, as in their `metadata` row. Terrain, terrain-hd and the two overlays: null, because their archives carry no date |
| `role` | `"overlay"` on the trails and places tile archives, absent on every other entry |

A layer's entries are sorted by `layer_schema_version`, highest first. Within one version the SQLite file comes first, then the overlay with `role: "overlay"`.

### Compatibility rule

A client knows which `layer_schema_version`s it can read for each layer. When it gets a manifest it:

1. Checks `manifest_version`. An unknown value is a typed error: the client rejects the whole manifest and keeps using the last one it cached.
2. For each region and layer, takes the first entry whose `layer_schema_version` it can read. Entries are sorted highest first, so that is the newest version it understands. For trails and places it takes both files of that version, the SQLite file and the overlay.
3. Treats a layer with no readable entry as not available in that region. That is a typed error for that layer only: the other layers work, and the client can tell the user to update.
4. Ignores fields and layer keys it does not know, and any entry whose `role` it does not know.

Adding a field or a layer key keeps `manifest_version`. Renaming or removing a field, or changing what one means, bumps it. The schema is strict, so a new field goes into `config/schemas/manifest.schema.json` in the same change.

**Producer rule.** The release that bumps a layer from version N to N+1 also lists the vN files, for one release. A client that reads only vN keeps the layer for that month, then sees it as not available until it updates. `maqs manifest --previous <path to the latest manifest>` does the carry-over. For each region and base pack in the new manifest, and each layer it has, the command appends the previous manifest's entries whose version is below the lowest version the new build has for that layer and whose `url` names the previous manifest's own `release`. They are copied unchanged, so `url` still names the earlier release's tag and `sha256` its file; the format allows that because `url` is per entry. Entries of the same or a higher version are not carried, nor are layers the new build lacks or regions and base packs no longer configured.

An entry that the previous manifest had carried itself names an older tag, so it is dropped, and the window ends after one release. A same-month re-run, where the previous manifest's `release` is the new one, keeps every lower entry that manifest lists. Carried URLs are never rewritten: the tag in the URL is what ends the window. The previous manifest is validated against the schema first, and for a `data-YYYY-MM` release it must be an earlier dated release or the same month; `data-ci` or a later month is refused. The command prints how many entries it carried. Keeping the carried files online is up to the release workflow. The workflow never deletes or replaces an asset on an earlier release, so carried entries stay online. On the month's own release a re-run replaces same-named assets with `--clobber` (delete, then upload); after a successful run every file the new manifest names is present ([ADR 0013](decisions.md)).

## `sources.json` (`sources_version` 1)

`config/sources.json` lists the online tile sources per layer. Clients fetch it from `https://raw.githubusercontent.com/lucavallin/maqs/main/config/sources.json`, cache it, and carry a copy bundled in the package as a fallback (Phase 4). Shipped apps read the file on `main` at runtime, so editing it is a production change: it goes through review, and CI validates it with `maqs check-config` against `config/schemas/sources.schema.json`. The file today:

```json
{
  "sources_version": 1,
  "layers": {
    "basemap": [
      {
        "id": "versatiles-osm",
        "provider": "VersaTiles",
        "tiles": "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}",
        "tilejson": "https://tiles.versatiles.org/tiles/osm/tiles.json",
        "schema": "shortbread-1.0",
        "format": "mvt",
        "min_zoom": 0,
        "max_zoom": 14,
        "attribution": ["© OpenStreetMap contributors", "CC BY 4.0 ESA WorldCover 2021"]
      }
    ],
    "terrain": [
      {
        "id": "versatiles-elevation",
        "provider": "VersaTiles",
        "tiles": "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}",
        "tilejson": "https://tiles.versatiles.org/tiles/elevation/tiles.json",
        "schema": "terrarium",
        "format": "webp",
        "tile_size": 512,
        "min_zoom": 0,
        "max_zoom": 12,
        "attribution": ["© Mapterhorn"]
      }
    ]
  }
}
```

| Field | Rule |
|---|---|
| `sources_version` | 1 |
| `layers` | exactly `basemap` and `terrain`, each a non-empty list of sources in priority order. Each has one source today, VersaTiles ([ADR 0004](decisions.md)) |
| `id` | lowercase kebab-case |
| `provider` | the provider's display name |
| `tiles` | an HTTPS URL template containing `{z}`, `{x}` and `{y}`, in that order |
| `tilejson` | the HTTPS URL of the source's TileJSON |
| `schema` | `shortbread-1.0` for a basemap source, `terrarium` for a terrain source |
| `format` | `mvt` for a basemap source; `webp` or `png` for a terrain source |
| `tile_size` | terrain sources only, and required there: 256 or 512 |
| `min_zoom`, `max_zoom` | 0–22, with `min_zoom` ≤ `max_zoom`. JSON Schema cannot compare two fields, so `pipeline/src/maqs/schemas.py` checks the order after the schema |
| `attribution` | a non-empty list of display strings, each verbatim from `DATA_LICENSE.md` (a test checks) |

No other field is allowed, so a basemap source cannot carry `tile_size`. Every URL, zoom range, schema, format and attribution string in the file was checked against the live VersaTiles TileJSON on 2026-10-16, and the terrain tile size against a live tile ([ADR 0012](decisions.md)).

Compatibility rule: clients ignore fields they do not know, and a structural change bumps `sources_version`. A client that meets an unknown `sources_version`, or cannot parse the file, keeps using its cached or bundled copy. From each layer's list, which is in priority order, a client uses the first source it can use.

## Build report (`build-report.json`, `report_version` 1)

Every run writes `dist/<region>/build-report.json`, also when a step fails. `--region base` writes one `dist/base/build-report.json` for all base packs, with one step per pack named `base-<pack>`.

| Field | Meaning |
|---|---|
| `report_version` | 1 |
| `region` | the region id, or `base` for the base packs |
| `built_at` | ISO 8601 UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `tools` | tool name → version found (`dev` for the Homebrew `pmtiles` build) |
| `steps[]` | `name`, `status` (`built`, `skipped` or `failed`), `seconds`, `command` (the argv of the step's main tool run: the tile tool, or tippecanoe for trails and places; empty for curvature and when skipped), `outputs[]`, `anomalies`, `anomaly_count`, `anomaly_kinds`, and `error` when failed |
| `steps[].outputs[]` | `file`, `layer` (the step's layer; `basemap` for a base pack), `layer_schema_version` (the layer's version, as in the file name), `data_date` (the UTC date of this run, `YYYY-MM-DD`, one value for the whole run, also for the outputs of a skipped step), `bytes`, `sha256`, `tile_type`, `min_zoom`, `max_zoom`, `tiles`, `compression`, `attribution`, `source_data_date` (both null when the archive metadata has no value), and `source`: the archive the output was cut from (`https://download.versatiles.org/osm-landcover.versatiles` for basemap and base packs, `https://download.versatiles.org/elevation.versatiles` for terrain, `https://download.mapterhorn.com` for terrain-hd, which reads several archives there; null for the overlays and SQLite files). A SQLite output has `tile_type`, `min_zoom`, `max_zoom`, `tiles` and `compression` null, takes `attribution` and `source_data_date` from its metadata row (`attribution`, `osm_timestamp`), and adds `rows`: table → row count (`trails`; `places`; `segments` and `corners`) |
| `steps[].anomalies` | data problems the step recorded and built past, each `{kind, id, message}`, in the order found and capped at 1,000 entries. `id` names the object: `way/<id>`, `relation/<id>`, `node/<id>`, the region id (`terrain_missing`) or the terrain file name (`terrain_unreadable`) |
| `steps[].anomaly_count` | the total before the cap |
| `steps[].anomaly_kinds` | kind → count over all anomalies, not capped, sorted by kind |
| `validation` | `ok`, and `failures`: a list of `<step>: <message>` |

A skipped step builds nothing, so it reports no anomalies; they are in the report of the run that built its outputs. The tile steps record none. The data steps record these kinds:

| Step | Kind | Recorded for |
|---|---|---|
| trails | `missing_member` | a member way missing from the extract or with fewer than two located nodes |
| trails | `reversed` | a relation with member ways stored against the route direction; one entry per relation, "`<k>` of `<n>` member ways reversed" |
| trails | `gap` | the first way of every leg after the first, with the gap in metres |
| trails | `role` | a member way with role `alternative`, `excursion` or `connection`, kept in the geometry |
| trails | `relation_member` | a relation with relation members (a superroute), which are ignored |
| trails | `no_geometry` | a relation with no way member in the extract |
| trails | `difficulty` | an unknown `cai_scale` or `sac_scale` value on the relation |
| trails | `terrain_missing` | no terrain archive in the output directory; ascent and descent are null |
| trails | `terrain_unreadable` | a terrain archive or tile that cannot be read; ascent and descent are null from then on |
| trails | `terrain_no_coverage` | a trail none of whose samples has a terrain tile |
| trails | `terrain_gap` | a trail some of whose samples have no terrain tile |
| places | `ele` | an `ele` value that does not parse |
| curvature | `too_short` | a way with fewer than two located nodes, skipped |
| curvature | `unlocated_nodes` | a way with some unlocated nodes, kept and joined over them |

Compatibility rule: readers ignore unknown fields. A new `report_version` means a field changed meaning or was removed. `maqs manifest` reads `layer`, `layer_schema_version` and `data_date`; a report written before outputs had them is refused (below).

## Validation rules

Every output is checked, including the outputs of a step skipped because they already exist. Every tile archive, overlays included:

- smaller than 1.9 GiB (`1.9 × 2^30` bytes);
- a readable PMTiles v3 header, and every section (root directory, metadata, leaf directories, tile data) ends within the file, so a tail-truncated archive is rejected;
- tile compression gzip or none, internal compression gzip or none;
- metadata that parses as a JSON object; the stored metadata is at most 8 MiB and ends within the file, and gzip-compressed metadata may inflate to at most 8 MiB;
- the zoom range exactly as the layer specifies: 6–14 for the trails overlay, 8–14 for the places overlay, and the ranges in the tile-archive table above;
- the tile type the layer allows: MVT for the basemap, base packs and overlays, WebP or PNG for the terrain layers. MLT is rejected: the VersaTiles archive the basemap is cut from holds MVT, and whether MapLibre Native iOS 6.31.0 renders MLT is unverified;
- at least one tile;
- clustered (the header's `clustered` flag set), as the archives `versatiles convert`, `pmtiles extract`, `pmtiles merge` and tippecanoe write are;
- its SHA-256 recorded.

Every SQLite file:

- smaller than 1.9 GiB;
- opens read-only and `PRAGMA integrity_check` answers `ok`;
- every table of its layer exists: `metadata`, `trails`, `trails_fts`, `trails_rtree`; `metadata`, `places`, `places_fts`, `places_rtree`; `metadata`, `segments`, `corners`, `segments_rtree`, `corners_rtree`;
- `metadata` has exactly one row, its `layer` and `region` match the step and the region, and its `schema_version` is the layer's `layer_schema_version` (1 for all three today);
- the row counts of the counted tables are recorded, and a count outside the region's `expect` range in `config/regions.yaml` fails the step (`trails` for the `trails` table, `places` for `places`, `curvature_segments` for `segments`; `corners` has no range). A region without an `expect` entry records its counts unchecked. A table with zero rows logs a warning, also when zero is inside the range;
- its SHA-256 recorded.

Base packs must also be under 15 MB (15,000,000 bytes). For every `fixture: true` region (today `test`) the build prints a warning when its basemap plus terrain exceed 5,000,000 bytes. A failed check fails the step, and the build exits non-zero.

`maqs check-config` checks the configuration. It loads `config/regions.yaml` with the checks listed in [`docs/architecture.md`](architecture.md); an invalid file exits 1. It validates `config/sources.json` against `config/schemas/sources.schema.json` and then checks `min_zoom` ≤ `max_zoom` on every source. With `--manifest <path>` it also validates that manifest against `config/schemas/manifest.schema.json`. A schema violation exits 2 and names the file and the JSON Pointer of the offending value, for example `manifest.json: /regions/0/layers/trails/0/url: …`; when there are several, it reports the deepest.

Validation follows JSON Schema draft 2020-12, where `pattern` is an ECMA-262 regular expression. Python's `re` differs from it in two places the schemas would hit. `\d` matches any Unicode digit, so the patterns spell digits `[0-9]`. `$` also matches before a final newline, so `pipeline/src/maqs/schemas.py` makes a pattern's final `$` match only at the end of the string. A validator that hands the patterns to Python's `re` unchanged accepts a value ending in a newline that maqs rejects.

`maqs manifest` checks in code what the schema cannot express:

- every region it covers has `dist/<region>/build-report.json`: every non-fixture region for a `data-YYYY-MM` release, the `--regions` list for `data-ci`, where an unknown id fails;
- every report parses, has `validation.ok` true (otherwise the command lists its failures), and every output in it carries `layer`, `layer_schema_version` and `data_date`. A report from before the versioned file names is refused with a hint to rebuild with `--force`;
- every report belongs where it sits: its `region` is the name of its directory, and every output file starts with `<region>-`, or `base-<pack>-` for a base pack's step. A report copied into the wrong directory is refused;
- every covered region has entries for the five standard layers; the outputs of a failed step do not count;
- when base packs are configured, `dist/base/build-report.json` exists and every pack's step built at least one output, all of layer `basemap`;
- with `--previous`, the previous manifest passes the schema and, for a `data-YYYY-MM` release, is an earlier dated release or the same month;
- after the carry-over, every entry's `url` ends in its `file`, and no entry of a `data-YYYY-MM` manifest points at `data-ci`;
- `created_at` is UTC and not older than the newest report's `built_at`, and a NaN or infinite number is never written.

The whole manifest, carried-over entries included, is then validated against the schema and written through a temporary file and a rename. A failure exits 1 with the reason. A `--release` that is neither `data-YYYY-MM` (month 01 to 12) nor `data-ci`, `data-ci` without `--regions`, or `--regions` with a dated release is a usage error and exits 2.
