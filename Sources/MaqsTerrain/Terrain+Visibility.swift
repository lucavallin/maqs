import CoreLocation
import Foundation

/// A target that is in range and farther than a metre, with the points its sight line needs.
private struct PreparedLine {
    let index: Int
    let distance: Double
    let bearing: Double
    let elevation: Double?
    /// The ground at the target; only located when the target has no elevation of its own.
    let targetPoint: SamplePoint?
    /// One point per ladder rung up to `distance - targetClearance`.
    let path: [SamplePoint]

    var tiles: Set<SourceTile> {
        Set(path.compactMap(\.tile) + [targetPoint?.tile].compactMap { $0 })
    }
}

extension Terrain {
    private static let maxVisibilityTargets = 5_000
    private static let maxSamplesPerLine = 100_000
    /// Targets whose points are held at once, whatever the tile count.
    private static let maxTargetsPerChunk = 64

    /// Which of `targets` the observer can see.
    ///
    /// Each sight line runs from the observer's eye to the target's apparent height, with the Earth's curvature and refraction from `options.earth`.
    /// Ground along the way hides the target only when it rises above the line by more than `options.margin`; the last
    /// `options.targetClearance` metres are not tested, so the target's own slope never hides it. When ``SightTarget/elevation``
    /// is known the line aims at it, otherwise at the ground under the target.
    /// A ridge that is known to hide the target wins over ground that is missing elsewhere; with no hiding ground but a gap, the
    /// answer is ``Visibility/unknown(at:reason:distance:)``, never visible.
    ///
    /// Targets are processed in order of bearing, in groups whose tiles fit the memory cache, so a full look reads each tile about once.
    /// At most 128 online tiles are fetched per call; ground that needs more is missing with ``MissingReason/requestCap``.
    /// A target whose coordinate is not a valid latitude and longitude is unknown at the target.
    /// - Returns: One result per target, in the order given.
    /// - Throws: ``TerrainError/invalidInput(_:)`` for more than 5,000 targets, an observer or option that is not finite (or a negative distance, margin or clearance),
    ///   or a sight line of more than 100,000 samples; `CancellationError` when the calling task is cancelled; ``PMTilesError`` for a damaged archive.
    public func visibility(of targets: [SightTarget], from observer: Observer, options: VisibilityOptions = VisibilityOptions()) async throws -> [Visibility] {
        guard targets.count <= Self.maxVisibilityTargets else {
            throw TerrainError.invalidInput("a visibility look has at most \(Self.maxVisibilityTargets) targets, not \(targets.count)")
        }
        let origin = observer.coordinate
        guard Self.isCoordinate(origin) else {
            throw TerrainError.invalidInput("the observer must be a finite latitude within 90 degrees and a finite longitude")
        }
        let eye: Double
        switch observer.height {
        case .aboveGround(let metres), .absolute(let metres): eye = metres
        }
        guard eye.isFinite, options.maxDistance >= 0, options.margin >= 0, options.targetClearance >= 0,
              options.maxDistance.isFinite, options.margin.isFinite, options.targetClearance.isFinite else {
            throw TerrainError.invalidInput("a visibility look needs a finite eye height and non-negative, finite distance, margin and clearance")
        }

        var results = [Visibility?](repeating: nil, count: targets.count)
        var lines: [(index: Int, distance: Double, bearing: Double)] = []
        for (index, target) in targets.enumerated() {
            guard Self.isCoordinate(target.coordinate) else {
                results[index] = .unknown(at: .target, reason: .noData, distance: 0)
                continue
            }
            let distance = Geodesy.distance(origin, target.coordinate)
            if distance > options.maxDistance {
                results[index] = .outOfRange(distance: distance)
            } else if distance < 1 {
                results[index] = .visible(distance: distance, bearing: 0, elevationAngle: 0)
            } else {
                lines.append((index, distance, Geodesy.initialBearing(from: origin, to: target.coordinate)))
            }
        }
        guard let farthest = lines.map(\.distance).max() else { return results.compactMap { $0 } }

        var budget = Self.fetchCap
        let eyeHeight: Double
        switch observer.height {
        case .absolute(let metres):
            eyeHeight = metres
        case .aboveGround(let metres):
            let point = try locate(origin, zoomLimit: options.bands.zoom(atDistance: 0))
            let loaded = try await load(Set([point.tile].compactMap { $0 }), budget: &budget)
            switch Self.resolve(point, loaded) {
            case .elevation(let ground):
                eyeHeight = ground + metres
            case .missing(let reason):
                for line in lines { results[line.index] = .unknown(at: .observer, reason: reason, distance: line.distance) }
                return results.compactMap { $0 }
            }
        }

        let ladder = try Self.ladder(upTo: farthest - options.targetClearance, latitude: origin.latitude, bands: options.bands)
        let tileLimit = tilesPerBatch

        var chunk: [PreparedLine] = []
        var chunkTiles: Set<SourceTile> = []
        for line in lines.sorted(by: { $0.bearing < $1.bearing }) {
            try Task.checkCancellation()
            var prepared = try prepare(line, target: targets[line.index], origin: origin, ladder: ladder, options: options)
            var tiles = prepared.tiles
            if !chunk.isEmpty, chunk.count >= Self.maxTargetsPerChunk || chunkTiles.union(tiles).count > tileLimit {
                try await settle(chunk, tiles: chunkTiles, into: &results, budget: &budget, origin: origin, eyeHeight: eyeHeight, ladder: ladder, options: options)
                chunk = []
                chunkTiles = []
                // The actor may have run setArchives while the chunk loaded, which makes the provider indexes located above stale.
                prepared = try prepare(line, target: targets[line.index], origin: origin, ladder: ladder, options: options)
                tiles = prepared.tiles
            }
            chunk.append(prepared)
            chunkTiles.formUnion(tiles)
        }
        try await settle(chunk, tiles: chunkTiles, into: &results, budget: &budget, origin: origin, eyeHeight: eyeHeight, ladder: ladder, options: options)
        return results.compactMap { $0 }
    }

    /// Locates the points of one sight line under the current providers.
    private func prepare(
        _ line: (index: Int, distance: Double, bearing: Double), target: SightTarget, origin: CLLocationCoordinate2D,
        ladder: [Double], options: VisibilityOptions
    ) throws -> PreparedLine {
        let end = line.distance - options.targetClearance
        let rungs = ladder.firstIndex { $0 > end } ?? ladder.count
        var path: [SamplePoint] = []
        path.reserveCapacity(rungs)
        for distance in ladder[..<rungs] {
            let coordinate = Geodesy.destination(from: origin, bearing: line.bearing, distance: distance)
            path.append(try locate(coordinate, zoomLimit: options.bands.zoom(atDistance: distance)))
        }
        let known = target.elevation.flatMap { $0.isFinite ? $0 : nil }
        let targetPoint = known == nil ? try locate(target.coordinate, zoomLimit: options.bands.zoom(atDistance: line.distance)) : nil
        return PreparedLine(index: line.index, distance: line.distance, bearing: line.bearing, elevation: known, targetPoint: targetPoint, path: path)
    }

    /// Loads one chunk's tiles and decides each of its lines.
    private func settle(
        _ chunk: [PreparedLine], tiles: Set<SourceTile>, into results: inout [Visibility?], budget: inout Int,
        origin: CLLocationCoordinate2D, eyeHeight: Double, ladder: [Double], options: VisibilityOptions
    ) async throws {
        guard !chunk.isEmpty else { return }
        let loaded = try await load(tiles, budget: &budget)
        for line in chunk {
            results[line.index] = Self.decide(line, origin: origin, eyeHeight: eyeHeight, ladder: ladder, loaded: loaded, options: options)
        }
    }

    private static func isCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite && abs(coordinate.latitude) <= 90
    }

    /// Distances from the observer, one tile pixel apart at the zoom of the band they lie in, starting one step out: the profile's spacing.
    private static func ladder(upTo end: Double, latitude: Double, bands: ZoomBands) throws -> [Double] {
        var distances: [Double] = []
        var distance = 0.0
        while true {
            distance += WebMercator.pixelSize(zoom: bands.zoom(atDistance: distance), tileSize: 512, latitude: latitude)
            guard distance <= end else { return distances }
            guard distances.count < maxSamplesPerLine else {
                throw TerrainError.invalidInput("a sight line has at most \(maxSamplesPerLine) samples; use a shorter maximum distance")
            }
            distances.append(distance)
        }
    }

    private static func decide(
        _ line: PreparedLine, origin: CLLocationCoordinate2D, eyeHeight: Double,
        ladder: [Double], loaded: [SourceTile: TileLoad], options: VisibilityOptions
    ) -> Visibility {
        let targetHeight: Double
        if let elevation = line.elevation {
            targetHeight = elevation
        } else if let point = line.targetPoint {
            switch resolve(point, loaded) {
            case .elevation(let ground): targetHeight = ground
            case .missing(let reason): return .unknown(at: .target, reason: reason, distance: line.distance)
            }
        } else {
            return .unknown(at: .target, reason: .noData, distance: line.distance)
        }
        let apparentTarget = targetHeight - options.earth.drop(atDistance: line.distance)
        var hiding: (clearance: Double, distance: Double)?
        var firstGap: MissingReason?
        for (rung, point) in line.path.enumerated() {
            let distance = ladder[rung]
            switch resolve(point, loaded) {
            case .missing(let reason):
                firstGap = firstGap ?? reason
            case .elevation(let ground):
                let sight = eyeHeight + (apparentTarget - eyeHeight) * distance / line.distance
                let clearance = ground - options.earth.drop(atDistance: distance) - sight
                if clearance > options.margin, clearance > (hiding?.clearance ?? -.infinity) { hiding = (clearance, distance) }
            }
        }
        if let hiding {
            let blocked = Geodesy.destination(from: origin, bearing: line.bearing, distance: hiding.distance)
            return .hidden(distance: line.distance, blockedAt: blocked, blockedDistance: hiding.distance, clearance: hiding.clearance)
        }
        if let firstGap { return .unknown(at: .path, reason: firstGap, distance: line.distance) }
        let angle = atan2(apparentTarget - eyeHeight, line.distance) * 180 / .pi
        return .visible(distance: line.distance, bearing: line.bearing, elevationAngle: angle)
    }
}
