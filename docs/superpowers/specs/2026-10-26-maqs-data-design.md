# Swift package, sub-project 3: `MaqsData` — design

**Date:** 2026-10-26 · **Status:** draft, for the owner's review
**Brief:** `docs/BRIEF.md` § Phase 4, MaqsData · **Builds on:** ADR 0006 (trail sources), 0008 (corner alert, shared corner formula, privacy), 0010 (polyline6), 0011 (data-layer formulas and measurements), 0014 (`MaqsCore`; read-only immutable opening; amended here for file protection), 0015 (`MaqsTerrain`; the line-of-sight targets)

## Problem

`MaqsData` reads the three SQLite layers of installed regions (trails, places, curvature) and answers a few simple questions about them, on the device, with no network. Three uses set the requirements (owner, 2026-10-26):

1. **A tight-corner alert while a ride is recorded.** The app gets a position and heading about once a second, matches them to a road, and wants the corners coming up.
2. **What lies along a sight line.** From where the user stands, which places lie in a direction, out to the distance the eye can see? The answer feeds `MaqsTerrain`'s visibility query.
3. **Finding a hiking trail.** People find a CAI or SAT trail on the map, or type its number, such as 926, and want its record and path.

## Approaches considered

1. **One reader per layer** (chosen): three actors, `Trails`, `Places` and `Roads`, each over the files of its own layer. An app opens only the layer it uses.
2. **One `MaqsData` actor over every layer.** One object to create, but an app that needs only roads would hand it trails and places too, or carry optional state for the missing layers.
3. **A thin SQL wrapper**, with each app writing its own queries. Rejected: every app would reimplement polyline decoding, the fork rule, the cone geometry and the search order, and they would disagree.
4. **Do nothing in Swift; precompute in the pipeline.** Rejected: the questions depend on the user's position, which is personal data and never leaves the device (CLAUDE.md, data classification).

## Decisions

Made by the owner in conversation (2026-10-26):

1. **The three uses above set the requirements.**
2. **Matching stays with the app** (brief; ADR 0008). `MaqsData` gives the app the road segments near a position to match against, and once the app has matched, the corners ahead from that segment, direction and position.
3. **At a fork, the lookahead takes the likeliest branch and marks the guess.** Likeliest means: same road number (`ref`), then same `name`, then same `highway` class, and the smallest turn among what is left. It never enters a one-way road against its direction. Each result says where the lookahead had to choose, so the app can treat corners past that point as less certain. The app asks again on every position update, so a wrong guess is corrected once the rider is through the junction. The accepted cost: a tight corner just past a fork, on the branch the guess did not take, is announced only after the junction.
4. **Places along a line are a cone.** A place counts when its direction from the origin is within a set angle either side of the bearing, so the corridor widens with distance. The default is 5° either side, and 180° is the whole circle around the user. The default reach is 100 km, the same as `MaqsTerrain`'s default sight range.
5. **Places come back nearest first, with an optional cap.** Each place carries its distance, its bearing from the origin and its angle off the cone's bearing. With a cap, the places with the highest `rank_score` are kept, still returned nearest first.
6. **Trail search: number first.** A typed number finds trails whose number is exactly that first, then numbers with letters around them (926A, E926), then any text match. Within each group the trails closest to a point the app passes come first. Name search ignores accents. Difficulty is a filter.
7. **Tapping the map leads to the record.** Overlay features carry their SQLite row `id`, so the app can get the full trail or place from the region and the feature id.
8. **A trail's path is never shown as whole when it isn't.** Every trail carries its `geometry_status` (`ordered`, `gaps`, `incomplete`).
9. **Offline only.** `MaqsData` opens no network connection, ever. Where nothing is installed it returns empty results; it cannot search trails outside installed regions, because no online source for trail data exists.
10. **The corner formula is also a Swift function** over a list of coordinates (ADR 0008, decision 2), so an app measures a recorded track exactly as the pipeline measured the roads. It is checked against the pipeline's own output. *(Proposed by the designer, accepted in the playback.)*
11. **No app knowledge.** Nothing in this sub-project names or describes the consuming apps.

Settled with the owner after the builder check (2026-10-26):

12. **The pipeline records where roads meet mid-way.** OSM does not split a way at a junction and the pipeline keeps ways whole, so a side road usually ends in the middle of another way, where no `start_node`/`end_node` matches. The curvature layer gains a `junctions` table (below), an additive change that keeps `layer_schema_version` 1. The lookahead follows exact node links, side roads become forks, and a road is never joined to one it crosses on a bridge. The pipeline and the fixtures are part of this sub-project; real data gets the table from the next monthly build after the change lands, and older v1 files fall back to end-node links. Rejected: guessing the links from geometry in Swift, which works on today's files but joins roads that cross on a bridge or in a tunnel.
13. **Roundabouts are one-way as OSM implies.** `segments` gains the `junction` tag as a column (additive, version 1). A way tagged `junction=roundabout` without a `oneway` tag is one-way in its drawing direction ([OSM wiki, junction=roundabout](https://wiki.openstreetmap.org/wiki/Tag:junction=roundabout): oneway=yes "is implied", ways "must be drawn in the direction of traffic flow"). `junction=circular` implies nothing and follows its own `oneway` tag ([wiki](https://wiki.openstreetmap.org/wiki/Tag:junction=circular)).
14. **Region files stay readable while the phone is locked.** `MaqsCore` marks installed files Protected Until First User Authentication explicitly, so an app whose default class is Complete still gets corners during a locked ride. `MaqsData` reports a file it cannot read as its own error, `unreadable`, never as `corruptData`.

**Changed after the conversation, the designer's call:** the playback offered a "gap report", saying from which distance along the line no places data was installed. It is dropped. The SQLite files do not record their region's outline, and the regions are clipped to admin polygons, so `MaqsData` cannot tell a stretch with no places from a stretch outside every region. A bounding box would claim coverage over land the file does not cover, which is the "pretending" decision 9 of ADR 0015 forbids. The app knows which regions are installed (`MaqsCore`'s catalog) and can say so. A report can be added later without breaking the API.

**The designer's calls after the builder check**, for the owner to check while reading:

- **Today's schema is the plan.** The curvature file is 3.7 times over its 30 MB target (ADR 0011). This design reads the v1 layout plus the two additions; any later fix for the size must keep what `Roads` reads, or bump the version with a reader for both.
- **A missing tag never matches at a fork,** and the `ref` and `name` compared against are the last non-empty ones on the path, so an unnamed link or a roundabout between two stretches of one road leads back onto it.
- **Motorways are one-way too.** `highway=motorway` without a `oneway` tag is one-way in its drawing direction, as the [OSM wiki, Key:oneway](https://wiki.openstreetmap.org/wiki/Key:oneway) says it is implied; `motorway_link` follows its tag (the page says nothing about it). It needs no new column.
- **The no-revisit rule works on stretches, not segment ids,** so a roundabout drawn as one ring is walked round across its closing node, and a road that leaves a way and rejoins it further on is followed.
- **A fork's branches carry a direction** (`RoadBranch`), because a way met mid-way can be taken both ways.
- **The error is `unreadable`, not "locked".** SQLite reports an I/O failure, not its cause; the description names data protection as the likely one.
- **Map taps during an update** (an overlay tile from one build, the SQLite file from another) are `MaqsUI`'s to prevent, by installing both from one manifest; `trail(region:featureID:)` then returns nil or the wrong row only if they disagree, which the DocC comment says.

The builder's calls are marked *(builder's call)* where they appear; anything not marked is required.

## Success criteria

- `MaqsData` is a product with no dependency; it imports only Foundation, SQLite3, CoreLocation (for `CLLocationCoordinate2D`) and os. It builds for iOS 18 and macOS 15 with warnings as errors.
- Every fixture file opens with the reader of its layer and is rejected by the other two with a typed error. Every malformed input in the test list (wrong layer, unknown schema version, missing table or column, not SQLite, truncated, bad polyline) is a typed `QueryError`: no crash, no trap.
- Opening never writes: after any sequence of queries, no `-wal`, `-shm` or `-journal` file exists next to a data file (ADR 0014).
- The Swift polyline decoder and corner formula agree with the pipeline's on the golden file (counts, directions and ordinals exactly; lengths, radii, scores and distances within 1e-6 m).
- The fork rule, one-way handling, reverse travel and cone geometry each have a test over a synthetic file built in the test.
- A lookahead of 1 km takes under 5 ms, and a full-circle cone of 100 km over 30,000 places under 100 ms, on macOS in a debug build *(designer's call)*. A test logs both; neither is a CI assertion, since runner timings vary. The simulator is measured once by hand.
- On a file without the `junctions` table or the `junction` column (`data-2026-10`), every query works and the lookahead follows end nodes only.
- An installed file and its `pack.json` carry Protected Until First User Authentication.
- `swift test` and the iOS Simulator leg pass; `uv run pytest` passes with the junction tests, the golden-file generator and its staleness test; `uv run maqs build --region test` stays under 5 minutes.

## Facts verified while designing (2026-10-26)

- macOS's `sqlite3` is 3.54.0. On the fixtures, a URI `file:<path>?immutable=1` opens read-only and serves FTS5 and R\*Tree queries, and leaves no `-wal` or `-shm` file.
- FTS5 accepts each search word as a double-quoted string, and `"200"*` is a prefix match: it finds the six test trails numbered 2003–2009, three of them by `name`, three by `ref`.
- **Three of the ten test trails carry their number only in `name`** (`2003`, `2004`, `2005`, with no `ref`). Number search must look at `name` as well as `ref`.
- R\*Tree stores 32-bit floats, rounded outward: a stored `min_lon` of 12.2029055 reads back as 12.2029037. Boxes still contain the original geometry, so a point query must allow for it.
- `segments.start_node` and `end_node` have no index. A full scan of Triveneto's 221,044 segments per position update is too slow, so segments ending at a node are found through `segments_rtree` at the node's coordinate, then filtered by node id.
- **Roads meet mid-way.** In the test region, 70 of the 272 segment ends share no end node with another segment, and 22 of those lie within 3 m of another segment, the shape of a T-junction at a node inside the other way. The reviewer measured 34,775 of Veneto's 257,180 way ends meeting another way mid-way, about one in seven, and 8,998 of its 9,019 `junction=roundabout` ways without a `oneway` tag.
- The curvature layer holds only `motorway` to `unclassified` and their links, paved (`config/regions.yaml`). A junction with a residential or unpaved road looks like a dead end in the data.
- Apple Platform Security: Protected Until First User Authentication "is the default class for all third-party app data not otherwise assigned to a Data Protection class" ([Data Protection classes](https://support.apple.com/guide/security/secb010e978a/web)). An app can choose a stricter default, which is why `MaqsCore` sets the class itself. On this Mac, `FileManager.setAttributes` with `.protectionKey: .completeUntilFirstUserAuthentication` succeeds and reads back, and it type-checks for iOS 18 and macOS 15.
- No package version has been tagged, so no installed pack predates the protection change; nothing needs migrating.
- Triveneto (ADR 0011): 8,686 trails, 29,198 places, 221,044 segments, 460,364 corners. The test region: 10 trails, 22 places (15 hamlets, 4 villages, 3 peaks; no passes or huts), 136 segments, 623 corners. Kinds the fixture lacks are tested on synthetic files.

## Package layout

```
Sources/MaqsData/
  Logging.swift                 # os.Logger, category "data"
  Store/                        # SQLite connection, opening and checking a layer file, prepared statements
  Geometry/                     # polyline6 decoder, haversine, bearings, point-to-line distance (internal)
  Trails/   Trails.swift (actor), search tiers
  Places/   Places.swift (actor), cone
  Roads/    Roads.swift (actor), lookahead, fork rule
  Curvature/ Curvature.swift    # the shared corner formula (public, pure)
  Public/                       # value types and QueryError, one per file
Tests/MaqsDataTests/            # Swift Testing; Support/ holds a writer for synthetic layer files
```

`Package.swift` gains the `MaqsData` library and target (no dependency) and `MaqsDataTests` (on `MaqsData` and `MaqsTestSupport`). The builder chooses file splits inside these folders.

Outside `MaqsData`: `pipeline/src/maqs/curvature/step.py` and its tests (the junctions table and the `junction` column), the regenerated fixtures, and `Sources/MaqsCore/Storage/PackStore.swift` with `Tests/MaqsCoreTests/StorageTests.swift` (file protection).

## Public API

Signatures are the contract; doc comments and small helpers are the builder's. Distances are metres, angles degrees, coordinates `CLLocationCoordinate2D`.

```swift
public actor Trails {
    public init(files: [URL]) throws(QueryError)
    public func setFiles(_ urls: [URL]) throws(QueryError)
    public func search(_ text: String, near: CLLocationCoordinate2D? = nil,
                       difficulty: ClosedRange<Int>? = nil, limit: Int = 50) throws(QueryError) -> [TrailSummary]
    public func trails(in area: QueryArea, difficulty: ClosedRange<Int>? = nil, limit: Int = 200) throws(QueryError) -> [TrailSummary]
    public func trail(_ id: TrailID) throws(QueryError) -> Trail?
    public func trail(region: String, featureID: Int64) throws(QueryError) -> Trail?
}

public actor Places {
    public init(files: [URL]) throws(QueryError)
    public func setFiles(_ urls: [URL]) throws(QueryError)
    public func places(in cone: BearingCone, kinds: Set<PlaceKind>? = nil, limit: Int? = nil) throws(QueryError) -> [PlaceInCone]
    public func places(in area: QueryArea, kinds: Set<PlaceKind>? = nil, limit: Int = 500) throws(QueryError) -> [Place]
    public func place(_ id: PlaceID) throws(QueryError) -> Place?
    public func place(region: String, featureID: Int64) throws(QueryError) -> Place?
}

public actor Roads {
    public init(files: [URL]) throws(QueryError)
    public func setFiles(_ urls: [URL]) throws(QueryError)
    public func segments(near: CLLocationCoordinate2D, within: Double = 50, limit: Int = 20) throws(QueryError) -> [NearbySegment]
    public func segment(_ id: RoadSegment.ID) throws(QueryError) -> RoadSegment?
    public func cornersAhead(from position: RoadPosition, distance: Double = 1_000) throws(QueryError) -> Lookahead
}

public enum Curvature {
    public static func analyze(_ coordinates: [CLLocationCoordinate2D]) throws(QueryError) -> CurvatureAnalysis
}
```

Whether the methods use typed `throws(QueryError)` or plain `throws` documented as `QueryError` is the builder's call; it must match one way across the module.

**Values** (all `Sendable`, `Equatable` where it makes sense):

- `QueryArea`: min/max lon/lat, validated (finite, in range, minimum below maximum). Named so it does not clash with `MaqsCore.BoundingBox` in an app that imports both *(designer's call)*.
- `TrailID`: `source` and `sourceID` (`osm`, `relation/123`), the key that survives a new release. `PlaceID`: `osmType` and `osmID`. `RoadSegment.ID`: the OSM way id (`Int64`). Row ids are valid only within one build (`data-format.md`), so they appear only as `featureID` alongside the region.
- `TrailSummary`: `id`, `region`, `featureID`, `ref`, `refREI`, `name`, `from`, `to`, `difficulty` (grade 1–6, scheme, original value; each optional), `network`, `operator`, `osmcSymbol`, `length`, `ascent?`, `descent?`, `area: QueryArea?`, `geometryStatus`. `Trail`: the summary plus `roundtrip?`, `surveyDate`, `website`, `sourceLicence`, `sourceDate`, `osmType`/`osmID`, `secondaryOf: TrailID?` and `path: [[CLLocationCoordinate2D]]`, one array per leg. Lists return summaries, so a search never decodes a 350 km path.
- `GeometryStatus`: `ordered`, `gaps`, `incomplete`, `other(String)`.
- `Place`: `id`, `region`, `featureID`, `kind`, `name` and `localizedNames` (`it`, `de`, `fur`, `sl`), `ele?`, `wikidata?`, `coordinate`, `rankScore`. `PlaceKind`: the ten kinds of `data-format.md` plus `other(String)`, so a newer file with a new kind still reads.
- `BearingCone`: `origin`, `bearing`, `halfAngle` (default 5), `maxDistance` (default 100,000), with `init(from:to:halfAngle:)` that takes the bearing and distance between two points *(designer's call)*. `PlaceInCone`: `place`, `distance`, `bearing`, `offset` (negative to the left of the cone's bearing).
- `RoadSegment`: `id`, `name`, `ref`, `highway`, `surface`, `junction` and `maxspeed` (as tagged; `junction` nil in older files), `oneway` (`none`, `forward`, `backward`; the effective one-way the lookahead obeys, see Roads), `length`, `score`, `startNode`, `endNode`, `geometry`, `corners: [Corner]` in drawing direction. `NearbySegment`: `segment`, `distance` from the position, `along` (metres from the first vertex to the nearest point) and `heading` (the drawing direction there).
- `RoadPosition`: `segment`, `direction` (`TravelDirection.forward` or `.backward`, relative to the drawing direction), `along` (metres from the first vertex, drawing direction).
- `Lookahead`: `corners: [UpcomingCorner]`, `path: [PathStep]` (segment, direction, `along` where it is entered in drawing direction, distance ahead where it starts), `forks: [Fork]`, `end` (`reachedDistance` or `noContinuation(at:)`).
- `RoadBranch`: `segment` and `direction`, one way to leave a junction.
- `UpcomingCorner`: `turn` (`left`/`right` for the direction of travel), `minRadius`, `entry`, `apex`, `exit` (metres ahead of the position; `entry` can be negative while the rider is in the corner), `apexCoordinate`, `segment`, `afterFork: Bool`.
- `Fork`: `distance` ahead, `chosen: RoadBranch`, `alternatives: [RoadBranch]`, `reason` (`sameRef`, `sameName`, `sameHighway`, `smallestTurn`).
- `Corner`: `ordinal`, `apex` coordinate, `minRadius`, `turn`, `entry`, `apexDistance`, `exit` (along the geometry). `CurvatureAnalysis`: `merged` coordinates, `length`, `score`, `corners`.

## Opening files

- Each URL is opened as a URI `file:<path>?immutable=1` with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`. The path is percent-encoded for the URI, so `Application Support` and file names with `#`, `?` or `%` work (CLAUDE.md: `URL.path()` traps).
- A file is accepted only when its `metadata` table has exactly one row, its `layer` matches the reader, its `schema_version` is 1, and the tables and columns this design reads exist. Columns are selected by name and unknown ones are ignored (the compatibility rule). The curvature `junctions` table and `junction` column are optional: files built before them (`data-2026-10`) are valid v1 files. Anything else is a typed error naming the file (its last path component, never the full path, which holds the app's container).
- `init` and `setFiles` open every file or none: one failure is logged with the file name and the error case, and thrown; `setFiles` then leaves the previous set in place, as `Terrain.setArchives` does. Two files with the same `metadata.region` are rejected (`duplicateRegion`).
- No query suspends: every method runs its SQLite calls to completion inside the actor, so `setFiles` cannot interleave with a query and no generation counter is needed. Connections close when replaced and on deinit.
- Several files of one layer are read together (Triveneto and Veneto may both be installed). A record found in more than one file is returned once, by its stable key; the first file in the order given wins *(designer's call)*.
- No files is a valid state: every query returns an empty result, and `cornersAhead` throws `unknownSegment`.

## Trails

**Search.** The text is trimmed and runs of whitespace collapsed; an empty text returns nothing. Results come in three groups, each trail once, in the first group it qualifies for:

1. `ref`, `ref_rei` or `name` equals the text, ignoring case.
2. Only for a text of digits: `ref` or `ref_rei` contains the number as a whole run of digits: `926` matches `926A`, `E926` and `926/1`, never `1926` or `9260`.
3. FTS5 over `trails_fts` (`ref`, `name`, `from_name`, `to_name`, `operator`). Each word is quoted as an FTS5 string (inner `"` doubled), the last word is a prefix (`"dolo"*`), and words are ANDed. User text never reaches FTS5 unquoted, so `"`, `*`, `-`, `:`, `^`, `NEAR(` and `AND` are words, not syntax.

Within a group, when `near` is given, the trail whose bounding box is closest to the point comes first (0 inside it), trails without geometry last; otherwise file order, then `id`. `limit` is 1 to 500. Secondaries (`secondary_of` set) are left out of search and area queries; `trail(_:)` returns any row. Tiers 1 and 2 scan the `ref`, `ref_rei` and `name` columns, which is fast at Triveneto's 8,686 rows *(builder's call how)*.

**Difficulty filter.** A range within 1–6; trails with no grade are left out when a filter is set.

**Area.** Primaries whose R\*Tree box intersects the area, longest first, up to `limit` (1 to 2,000).

**By id.** `trail(_:)` looks the stable key up in each file (`source`, `source_id`); `trail(region:featureID:)` reads the row of that region's file. The path is decoded here: legs split on `;`, each leg a polyline6.

## Places

**Cone.** For every place in the cone's R\*Tree prefilter: distance by haversine and initial great-circle bearing from the origin, on a sphere of 6,371,008.8 m, the radius the pipeline and `MaqsTerrain` use. A place counts when its distance is at most `maxDistance` and its offset (the signed difference from the cone's bearing, in −180 to 180) is within `halfAngle`, both inclusive. A place less than 1 m from the origin has no direction and is left out *(designer's call)*. `bearing` is normalised to 0–360; `halfAngle` is above 0 and at most 180; `maxDistance` above 0 and at most 500 km *(designer's call)*. The prefilter only has to contain the cone; the circle's bounding box is enough, and a full-circle 100 km look reads at most every place in the file (29,198 in Triveneto). A tighter box is the builder's call. Results are nearest first; with `limit`, the `limit` highest `rank_score` (ties by `id`) are kept, then sorted nearest first.

**Area.** Places whose point lies in the area, highest `rank_score` first, up to `limit` (1 to 5,000).

**To line of sight.** The app builds `SightTarget(coordinate: place.coordinate, elevation: place.ele)` from each result; `MaqsData` does not import `MaqsTerrain` (rule 1: products are independent). The README shows the two calls together.

## Roads

**Segments near a position.** R\*Tree candidates whose box, widened by `within`, holds the position; then the distance from the position to each segment's polyline (local plane per vertex pair, as in the corner formula) *(builder's call)*. Kept when the distance is at most `within` (1 to 500 m), nearest first, up to `limit` (1 to 100). Each result gives `along` and the drawing-direction `heading` at the nearest point, which is what an app's matcher needs.

**Corners ahead.** `distance` is above 0 and at most 10,000 m; `along` is clamped to 0…`length`, since a projected GPS position can overshoot. The walk:

1. Start on the given segment in the given direction. For `backward` travel everything on a segment flips: a distance `d` becomes `length − d`, entry and exit swap, `left` and `right` swap, ordinals run in reverse.
2. Find the next **junction point** ahead in the direction of travel: the segment's end, or, in a file with the `junctions` table, the nearest of the segment's junction rows strictly ahead of the position. Collect the segment's corners whose apex lies ahead of the position (apex distance ≥ 0), up to that point and within `distance`. A corner whose entry is behind the rider but whose apex is ahead is still reported.
3. At the junction point's node, list the **branches**: every segment through that node in any open file, each with the direction that leads away from it.
   - Segments that end at the node come from each file's `segments_rtree` at the node's coordinate (a box of about ±1e-5°, which covers the polyline and float32 rounding *(builder's call)*), filtered by `start_node`/`end_node`. They are travelled `forward` from their `start_node`, `backward` from their `end_node`.
   - Segments that pass through the node come from `junctions` by `node`, and offer both directions. The current segment is one of them, so going straight on is a branch. A closed way (`start_node` = `end_node`) leads on across its closing node, so a roundabout drawn as one ring is walked round.
   - Left out: branches against an effective one-way (below), and branches whose first stretch is already on the path. The stretch just travelled is one, so the walk never turns back, and a loop cannot repeat.
4. None: stop with `noContinuation(at:)` the distance of that node. One: continue, no fork. More than one: the fork rule (decision 3). Narrow by `ref` (whitespace collapsed, case ignored; equal whole strings), then `name`, then `highway`, each step only when it leaves at least one candidate. The `ref` and `name` compared against are the last non-empty ones on the path; a branch without the tag never matches. Among what remains, the smallest absolute turn between the last stretch before the node and the first stretch after it (how far a stretch reaches is the builder's call), ties by lower way id, then `forward` first. `reason` is the last rule that narrowed the set, or `smallestTurn` when none did. Corners from here on are `afterFork`. The app can weigh them by the fork's `reason`: staying on the same `ref` is far likelier than a smallest-turn guess.
5. Stop with `reachedDistance` once the walk has covered `distance`.

**Effective one-way.** `RoadSegment.oneway` is what the walk obeys: the `oneway` column, or, when it is 0, `forward` for `junction=roundabout` (decision 13) and for `highway=motorway` (the designer's call above). `junction=circular` and `motorway_link` follow their tag only. A file without the `junction` column infers only for motorways. The starting segment is used in the direction the app gives, even against its one-way: the app's matcher has the evidence, and refusing would silence the alert.

**Files without the junction data.** In a file without the `junctions` table the walk knows end nodes only: it passes side roads that meet mid-way without a fork, and where the road it is on ends in the middle of another way it stops with `noContinuation`. The DocC comment says so.

## Pipeline: junctions and the `junction` tag

Both are additive to the curvature layer, so `layer_schema_version` stays 1 ([compatibility rule](../../data-format.md)). The first release that carries them is the monthly build after the change lands.

- `segments` gains `junction TEXT`, the way's `junction` tag as tagged.
- A new table:

  ```sql
  CREATE TABLE junctions (
    segment_id INTEGER NOT NULL REFERENCES segments(id),
    node INTEGER NOT NULL,
    along_m REAL NOT NULL
  );
  CREATE INDEX junctions_node ON junctions(node);
  CREATE INDEX junctions_segment ON junctions(segment_id, along_m);
  ```

  One row for every located node inside a segment (not its first or last) that is also a located node of another segment in the file, at its end or inside it. `along_m` is the distance along the stored geometry to the point nearest the node, because the 5 m merge may have dropped the node's own vertex. A node a way passes twice gets two rows. Ends are not listed: `start_node`/`end_node` already carry them, and a row per way end would grow a file that is already over its size target.
- `read_roads` reads each way once with locations; knowing which nodes are shared needs every kept way's node ids first, so the step keeps them per way or reads twice *(builder's call)*. The builder measures the file growth on Veneto and records it in ADR 0016.
- `pipeline/tests/test_curvature.py` (or `test_steps_curvature.py`, wherever the step's tests live): a T-junction gives one row on the through way and none on the stem; a crossing at a shared node gives a row on each way; a ring with two entries gives two rows on the ring; a node dropped by the merge gets `along_m` at the nearest point; a node shared only with an excluded way (residential, unpaved) gives no row; a way through one node twice gives two rows; the `junction` column holds the tag. The test region's expectation checks the new table exists.

## `MaqsCore`: readable while the device is locked

`PackStore.moveIntoPlace` sets `FileAttributeKey.protectionKey` to `FileProtectionType.completeUntilFirstUserAuthentication` on the verified file before the rename, so no reader ever sees it in another class. A failure is `StorageError.writeFailed` and the file is not installed. `pack.json` gets the same class, so the catalog reads in the background too *(designer's call)*.

This is a §1 security-critical path (download and install). The class is weaker than Complete on purpose: the files hold public OSM data and must be read during a locked ride, and nothing personal is in them. `StorageTests` checks that an installed file and its `pack.json` read back the class. It was probed on macOS only; if the iOS Simulator does not report the attribute, the test runs on macOS only and says why.

## The corner formula in Swift

`Curvature.analyze` implements `data-format.md` § Curvature, steps 1–5: the 5 m vertex merge, the three-point radius in the local plane, the band weights, the score and the corners. It is the same arithmetic as `pipeline/src/maqs/curvature/score.py` and `geometry.py`. The text in `data-format.md` is normative; if the Python and the text disagree, the builder stops and reports. Non-finite coordinates or ones out of range throw `invalidInput`; fewer than three merged vertices give score 0 and no corners. Road corners read from the files use the same `Corner` type.

ADR 0008 also lists aggregates (corner count, tightest radius, turning share). The first two follow from `corners`; "turning share" has no normative definition anywhere, so it is not built. Defining it is an ADR and a `data-format.md` change.

## Polyline decoding

Polyline6 per `data-format.md` § Geometry encoding: latitude first, handed back as coordinates. Bounded and defensive: characters outside 63–126 are rejected, a value of more than 12 five-bit groups is rejected (no overflow), a value cut short or an odd number of values is rejected, and every decoded latitude and longitude must be in range. A rejection is `QueryError.corruptData` naming the file. An empty geometry is an empty path.

## Errors and logging

`QueryError` (CLAUDE.md names it), `LocalizedError` with descriptions that say what to do: `cannotOpen(file:)`, `wrongLayer(file:expected:found:)`, `unsupportedSchemaVersion(file:version:)`, `incompatibleFile(file:missing:)`, `duplicateRegion(_:)`, `corruptData(file:detail:)`, `unreadable(file:)`, `invalidInput(_:)`, `unknownSegment(_:)`. During a query, an I/O or permission failure (`SQLITE_IOERR` and its extended codes, `SQLITE_PERM`, `SQLITE_CANTOPEN`) is `unreadable`; its description says the file could not be read, that on iOS a file under Complete data protection cannot be read while the device is locked, and to try again or reinstall the region. Every other SQLite error during a query is `corruptData` with SQLite's result code, never the SQL text.

Logging through `os.Logger`, subsystem `com.lucavallin.maqs`, category `data`: each file opened (name, region, layer, row count) at info, each rejection at error. Queries are not logged at info: a lookahead runs every second. Anything position-derived (a query point, a cone origin) is `privacy: .private`.

## Tests (`Tests/MaqsDataTests`, Swift Testing)

A test-support writer builds synthetic layer files with the DDL copied from `data-format.md` (FTS5 and R\*Tree included) in a temporary directory, so kinds, forks and edge cases the fixture lacks are covered without new committed binaries.

- `PolylineTests`: the worked example (`_av|vA_xtjV` is lon 12.25, lat 46.1; `oKgE` adds lon 12.2501, lat 46.1002); the golden decodes; each malformed case.
- `CurvatureTests`: the golden file (every fixture segment re-scored by the pipeline, plus synthetic tracks: a 40 m circle, an S-bend, a straight line, points under 5 m apart, two points, a closed ring); empty, one-point and non-finite input.
- `OpeningTests`: each fixture opens with its reader and is rejected by the other two; schema version 2; missing metadata, table or column; an extra column accepted; not SQLite; a truncated file; a path with a space, `#`, `?` and `%`; no `-wal`, `-shm` or `-journal` after queries; duplicate region; `setFiles` failure keeps the old set; no files gives empty results; a curvature file without `junctions` or `junction` opens; an I/O failure is `unreadable`, not `corruptData` (the builder finds a way to inject one).
- `TrailSearchTests`: on the fixture, `2005` finds trail 3 by `name`, `2009` trail 6 by `ref`, `27` finds `CdD27` in group 2, `cammino dolo` finds trails 2, 9 and 10. On synthetic files: group order; nearest first; trails without geometry last; accents (`Pelmo` finds `Pèlmo`); the difficulty filter; FTS5 syntax characters as plain words; secondaries left out; one result for a relation in two files; `limit` bounds.
- `TrailTests`: by stable key and by region and feature id; the `gaps` trail (id 4) has several legs; `incomplete` status; unknown ids give nil; the trail with no geometry has an empty path.
- `PlaceConeTests` (synthetic places at known bearings and distances): inside and outside the half-angle and the reach, both edges inclusive; wrap-around (bearing 358°, a place at 2°); the full circle; a place at the origin left out; the cap keeps the top `rank_score` in distance order; kinds; one result per place across files; an unknown kind reads as `other`; `init(from:to:)`. On the fixture: the three peaks from a known point.
- `PlaceAreaTests`: order, kinds, limit.
- `NearbySegmentTests` (fixture): a point on a known segment returns it at distance about 0 with the right `along` and `heading`; `within` and `limit`.
- `LookaheadTests` (synthetic networks): a way split continues with no fork; forks decided by `ref`, `name`, `highway` and smallest turn; ties by way id and direction; the carried `ref` across an unnamed link; a branch without the tag never matches; one-way forbids a branch, and the starting segment ignores its own one-way; `junction=roundabout` and `highway=motorway` without a tag are one-way, `junction=circular` is not; `noContinuation` distance; a loop does not repeat; backward travel flips turns, distances and order; a corner with entry behind and apex ahead is reported, one with apex behind is not; corners past the reach are left out; `afterFork` marks; a continuation in a second file; `along` clamped; each invalid input; unknown segment. With the `junctions` table: a side road meeting mid-way is a fork on the through road; the stem of a T-junction turns onto the through road both ways; a crossing at a shared node; a ring roundabout with entries and exits is walked round to the exit on the carried `ref`; a road that leaves a way and rejoins it is followed. Without it: the same T-junction stem stops with `noContinuation`. On the fixture: corners ahead on one segment equal its `corners` rows, shifted by `along`; a lookahead across a known T-junction records a fork.
- `QueryMeasurement`: logs the two timings of the success criteria.

**Golden file.** `pipeline/src/maqs/data_golden.py`, run by `scripts/update-data-golden.sh` (and from `scripts/update-fixtures.sh`), writes `Tests/MaqsTestSupport/Fixtures/test/data-golden.json` from the committed fixtures with the pipeline's decoder and `score_way`, as `terrain-golden.json` does for terrain. A pytest checks that the committed file matches what the script produces now. Expected size well under 1 MB; fixtures stay under the 8 MB cap.

## Documentation

- ADR 0016: `MaqsData`, with the decisions above, the fork rule, the search order, the dropped gap report, the adjacency lookup, the junctions table with its measured size, the inferred one-way, and the file protection class (amending ADR 0014, whose status line points to it).
- `docs/data-format.md` § Curvature: the `junctions` table and the `junction` column with the release that first carries them; that `start_node`/`end_node` have no index and readers find segments ending at a node through `segments_rtree`; that readers infer one-way for `junction=roundabout` and `highway=motorway` (the `oneway` column itself stays explicit-only). The sentence "Nothing marks a roundabout" becomes true only of older files.
- `docs/architecture.md`: the protection class in the install state machine.
- `docs/architecture.md`: the MaqsData section (three readers, files from `MaqsCore`, offline only).
- `README.md`: a short example: trail search, a cone handed to `Terrain.visibility`, and corners ahead.
- `CLAUDE.md` §1: where we are, the repository map, the `MaqsDataTests` commands, and new traps (immutable URI encoding, R\*Tree float32, FTS5 quoting). `CONTRIBUTING.md`: the test-run line.

## Out of scope

Map-matching; routing; searching places by name (the FTS table exists; it can be added without breaking anything); the gap report; "turning share"; any network access; writing to the files; MapLibre or anything visual (sub-project 4 calls `trail(region:featureID:)` and `place(region:featureID:)` from map taps); the `MaqsCore` link (the app passes `InstalledFile.url`s).

## Risks

- **Bends across way splits.** The formula gives a way's end vertices no radius, so a bend through a way split can come out as two milder corners or none. The lookahead reports what the file holds. Fixing it changes the formula: an ADR and a schema version.
- **Real data lags a month.** Until the first release with the `junctions` table, installed files have only end-node links, so the lookahead stops at many ordinary junctions.
- **A bigger curvature file.** The table adds rows to a file already over its target; the builder measures how many.
- **`oneway=no` on a roundabout** reads as one-way, because the `oneway` column stores 0 for both `no` and no tag. Telling them apart would need another column.
- **Small roads end the lookahead.** Residential and unpaved roads are not in the layer, so a junction with one looks like a dead end and a turn onto one is invisible.
- **Compass error.** A phone compass is often several degrees off, so 5° either side may miss a place the user is looking at. It is a parameter; the app can widen it.
- **Multi-value refs** (`SS51;SP1`) are compared as whole strings, so a fork between `SS51` and `SS51;SP1` falls through to `name`.
- **Overlapping regions from different releases.** The first file wins for a record found in both; the app orders the files.
- **Blocking.** SQLite calls run synchronously on the actor. A full-circle cone over a large region is the longest query (the success criteria bound it); if the measurement misses, the builder narrows the prefilter before anything else.

## Found while designing, not fixed here

The trails and places overlay fixtures (`test-trails.v1.pmtiles`, `test-places.v1.pmtiles`) carry absolute local paths in their metadata (tippecanoe's `name`, `description` and `generator_options`), which name the build machine's home directory and change the file when the fixtures are regenerated elsewhere. Release overlays are built by the same step and probably carry the CI runner's paths (not checked). It is a separate change.
