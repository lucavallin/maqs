import CoreLocation
import Foundation

/// The points of one bearing, located under the current providers.
private struct PreparedColumn {
    let index: Int
    let bearing: Double
    /// One point per ladder rung.
    let path: [SamplePoint]

    var tiles: Set<SourceTile> {
        Set(path.compactMap(\.tile))
    }
}

extension Terrain {
    /// A panorama is bounded so one call cannot ask for an unbounded number of samples.
    private static let maxPanoramaSamples = 2_000_000
    /// At most this many located samples are held at once: about 16 bearings of a 200 km fan, a few MB, and the actor
    /// serves other calls between chunks.
    static let panoramaChunkSamples = 50_000

    /// The highest ground in each distance band, for every bearing of a fan: the ridges an observer sees one behind
    /// another, as elevation angles from the eye.
    ///
    /// Each bearing is sampled along its great circle as ``profile(from:to:options:)`` samples a line: from one step out
    /// to the last band edge, `options.step` apart or one tile pixel of the zoom `options.bands` gives for the distance,
    /// with the curvature drop and refraction of `options.earth`. A sample belongs to the band whose lower edge it has
    /// reached; the last edge is the panorama's reach, and samples nearer than the first edge are left out. Bearings are
    /// read in chunks whose tiles fit the cache, so neighbouring bearings share their tile loads, and at most 128 online
    /// tiles are fetched per call.
    ///
    /// With `.aboveGround` height and no ground at the observer, every ridge is `nil`.
    /// - Parameter bands: Ascending distance edges in metres, at least two, the first at least 0, all finite.
    /// - Throws: ``TerrainError/invalidInput(_:)`` for a non-finite observer, invalid bands, a `step` under 1 m, an
    ///   unusable ``EarthModel`` or more than 2,000,000 samples; `CancellationError` when the calling task is cancelled;
    ///   otherwise as ``elevation(at:)``.
    public func panorama(
        from observer: Observer, bearings: PanoramaBearings, bands: [Double], options: ProfileOptions = ProfileOptions()
    ) async throws -> Panorama {
        try await panorama(from: observer, bearings: bearings, bands: bands, options: options, chunkSamples: Self.panoramaChunkSamples)
    }

    /// The panorama, read in chunks of at most `chunkSamples` located samples (and the tiles that fit the cache).
    func panorama(
        from observer: Observer, bearings: PanoramaBearings, bands: [Double], options: ProfileOptions, chunkSamples: Int
    ) async throws -> Panorama {
        try Task.checkCancellation()
        let origin = observer.coordinate
        guard origin.latitude.isFinite, origin.longitude.isFinite, abs(origin.latitude) <= 90 else {
            throw TerrainError.invalidInput("the observer must be a finite latitude within 90 degrees and a finite longitude")
        }
        guard let reach = bands.last, bands.count >= 2, bands[0] >= 0, bands.allSatisfy(\.isFinite),
              zip(bands, bands.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw TerrainError.invalidInput("a panorama's bands are at least two ascending, finite edges from 0 metres")
        }
        if let step = options.step, !(step >= 1) {
            throw TerrainError.invalidInput("a panorama step is at least 1 metre, not \(step)")
        }
        try options.earth.validate()
        let headings = bearings.all
        let ladder = Self.panoramaLadder(upTo: reach, latitude: origin.latitude, options: options)
        guard headings.count * ladder.count <= Self.maxPanoramaSamples else {
            throw TerrainError.invalidInput("a panorama has at most \(Self.maxPanoramaSamples) samples; use a larger step or fewer bearings")
        }
        let empty = [BandRidge?](repeating: nil, count: bands.count - 1)
        var columns = headings.map { PanoramaColumn(bearing: $0, ridges: empty) }

        var budget = Self.fetchCap
        let eye: Double
        switch observer.height {
        case .absolute(let metres):
            eye = metres
        case .aboveGround(let metres):
            let point = try locate(origin, zoomLimit: options.bands.zoom(atDistance: 0))
            let loaded = try await load(Set([point.tile].compactMap { $0 }), budget: &budget)
            guard case .elevation(let ground) = Self.resolve(point, loaded) else {
                return Panorama(bands: bands, columns: columns)
            }
            eye = ground + metres
        }
        guard eye.isFinite else { throw TerrainError.invalidInput("a panorama needs a finite eye height") }

        let tileLimit = tilesPerBatch
        var chunk: [PreparedColumn] = []
        var chunkTiles: Set<SourceTile> = []
        for (index, bearing) in headings.enumerated() {
            try Task.checkCancellation()
            var prepared = try prepareColumn(index: index, bearing: bearing, origin: origin, ladder: ladder, options: options)
            let held = chunk.reduce(0) { $0 + $1.path.count }
            if !chunk.isEmpty, chunkTiles.union(prepared.tiles).count > tileLimit || held + prepared.path.count > chunkSamples {
                try await settlePanorama(chunk, tiles: chunkTiles, into: &columns, budget: &budget, ladder: ladder, bands: bands, eye: eye, earth: options.earth)
                chunk = []
                chunkTiles = []
                // The actor may have run setArchives while the chunk loaded, which makes the provider indexes located above stale.
                prepared = try prepareColumn(index: index, bearing: bearing, origin: origin, ladder: ladder, options: options)
            }
            chunk.append(prepared)
            chunkTiles.formUnion(prepared.tiles)
        }
        try await settlePanorama(chunk, tiles: chunkTiles, into: &columns, budget: &budget, ladder: ladder, bands: bands, eye: eye, earth: options.earth)
        return Panorama(bands: bands, columns: columns)
    }

    /// Distances from the observer out to `reach`, starting one step out: the profile's spacing.
    private static func panoramaLadder(upTo reach: Double, latitude: Double, options: ProfileOptions) -> [Double] {
        var distances: [Double] = []
        var distance = 0.0
        while true {
            distance += options.step ?? WebMercator.pixelSize(zoom: options.bands.zoom(atDistance: distance), tileSize: 512, latitude: latitude)
            guard distance <= reach, distances.count < maxPanoramaSamples else { return distances }
            distances.append(distance)
        }
    }

    private func prepareColumn(
        index: Int, bearing: Double, origin: CLLocationCoordinate2D, ladder: [Double], options: ProfileOptions
    ) throws -> PreparedColumn {
        let path = try ladder.map { distance in
            try locate(Geodesy.destination(from: origin, bearing: bearing, distance: distance), zoomLimit: options.bands.zoom(atDistance: distance))
        }
        return PreparedColumn(index: index, bearing: bearing, path: path)
    }

    /// Loads one chunk's tiles and finds each of its bearings' ridges.
    private func settlePanorama(
        _ chunk: [PreparedColumn], tiles: Set<SourceTile>, into columns: inout [PanoramaColumn], budget: inout Int,
        ladder: [Double], bands: [Double], eye: Double, earth: EarthModel
    ) async throws {
        guard !chunk.isEmpty else { return }
        let loaded = try await load(tiles, budget: &budget)
        for column in chunk {
            columns[column.index] = PanoramaColumn(
                bearing: column.bearing, ridges: Self.ridges(column.path, ladder: ladder, bands: bands, eye: eye, earth: earth, loaded: loaded))
        }
        // A caller that gave up while the tiles loaded gets no answer.
        try Task.checkCancellation()
    }

    /// Each band's highest apparent ground along one bearing, as an angle from the eye.
    private static func ridges(
        _ path: [SamplePoint], ladder: [Double], bands: [Double], eye: Double, earth: EarthModel,
        loaded: [SourceTile: TileLoad]
    ) -> [BandRidge?] {
        var ridges = [BandRidge?](repeating: nil, count: bands.count - 1)
        var band = 0
        for (point, distance) in zip(path, ladder) where distance >= bands[0] {
            while band < ridges.count - 1, distance >= bands[band + 1] { band += 1 }
            guard case .elevation(let ground) = resolve(point, loaded) else { continue }
            let angle = atan2(ground - earth.drop(atDistance: distance) - eye, distance)
            if angle > ridges[band]?.angle ?? -.infinity {
                ridges[band] = BandRidge(angle: angle, distance: distance)
            }
        }
        return ridges
    }
}
