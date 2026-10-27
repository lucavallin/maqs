import CoreLocation

/// The corner formula the pipeline applies to every road, available for a recorded track.
///
/// It implements `data-format.md`, Curvature, steps 1 to 5, with the arithmetic of `pipeline/src/maqs/curvature`, so a
/// track measured here is comparable with the scores and corners stored for roads.
public enum Curvature {
    private static let mergeDistance = 5.0
    private static let cornerMaxRadius = 500.0
    /// Below this, twice the triangle area in m² is treated as zero: the points are collinear.
    private static let collinearArea = 1e-9

    /// Measures `coordinates` as the pipeline measures a road.
    ///
    /// Vertices closer than 5 m are merged, then the score and the corners are computed over the merged line. Fewer
    /// than three merged vertices have no interior: score 0 and no corners.
    /// - Throws: ``QueryError/invalidInput(_:)`` when a coordinate is not finite or is out of range, which includes
    ///   `kCLLocationCoordinate2DInvalid`.
    public static func analyze(_ coordinates: [CLLocationCoordinate2D]) throws(QueryError) -> CurvatureAnalysis {
        guard coordinates.allSatisfy(Geodesy.isValid) else {
            throw .invalidInput("a coordinate is not finite or is out of range")
        }
        let merged = mergeClose(coordinates)
        let distances = cumulativeDistances(merged)
        let length = distances.last ?? 0
        guard merged.count >= 3 else {
            return CurvatureAnalysis(merged: merged, length: length, score: 0, corners: [])
        }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(merged.count - 2)
        for index in 1..<(merged.count - 1) {
            vertices.append(vertex(merged[index - 1], merged[index], merged[index + 1]))
        }
        var score = 0.0
        for (offset, vertex) in vertices.enumerated() {
            let index = offset + 1
            score += (distances[index + 1] - distances[index - 1]) / 2 * Double(bandWeight(vertex.radius))
        }
        let corners = findCorners(merged, vertices, distances)
        return CurvatureAnalysis(merged: merged, length: length, score: score, corners: corners)
    }

    /// The radius at a vertex and its turn; the turn is nil when the three points are collinear or coincident.
    private struct Vertex {
        let radius: Double
        let turn: Turn?
    }

    private static func mergeClose(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2, let first = coordinates.first, let last = coordinates.last else {
            return coordinates
        }
        var kept = [first]
        for point in coordinates.dropFirst().dropLast() where Geodesy.distance(kept[kept.count - 1], point) >= mergeDistance {
            kept.append(point)
        }
        kept.append(last)
        while kept.count > 2 && Geodesy.distance(kept[kept.count - 2], kept[kept.count - 1]) < mergeDistance {
            kept.remove(at: kept.count - 2)
        }
        return kept
    }

    private static func cumulativeDistances(_ line: [CLLocationCoordinate2D]) -> [Double] {
        guard !line.isEmpty else { return [] }
        var distances = [0.0]
        for index in 1..<line.count {
            distances.append(distances[index - 1] + Geodesy.distance(line[index - 1], line[index]))
        }
        return distances
    }

    /// `point` in metres in the local plane centred on `origin`.
    private static func offset(from origin: CLLocationCoordinate2D, to point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let scale = Geodesy.metresPerDegreeLongitudeAtEquator * cos(origin.latitude * .pi / 180)
        return (
            (point.longitude - origin.longitude) * scale,
            (point.latitude - origin.latitude) * Geodesy.metresPerDegreeLatitude
        )
    }

    /// The circle through `p`, `q`, `r` and the turn at `q`.
    private static func vertex(
        _ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D, _ r: CLLocationCoordinate2D
    ) -> Vertex {
        let (ax, ay) = offset(from: q, to: p)
        let (cx, cy) = offset(from: q, to: r)
        let cross = ax * cy - ay * cx
        guard abs(cross) >= collinearArea else { return Vertex(radius: .infinity, turn: nil) }
        let a = hypot(ax, ay)
        let b = hypot(cx, cy)
        let c = hypot(cx - ax, cy - ay)
        let direction = (-ax) * cy - (-ay) * cx
        return Vertex(radius: (a * b * c) / (2 * abs(cross)), turn: direction > 0 ? .left : .right)
    }

    private static func bandWeight(_ radius: Double) -> Int {
        if radius < 30 { return 4 }
        if radius < 60 { return 3 }
        if radius < 100 { return 2 }
        if radius < 175 { return 1 }
        return 0
    }

    /// Corners in order. `vertices[i - 1]` belongs to merged vertex `i`.
    private static func findCorners(
        _ line: [CLLocationCoordinate2D], _ vertices: [Vertex], _ distances: [Double]
    ) -> [Corner] {
        var corners: [Corner] = []
        var run: [Int] = []

        func closeRun() {
            guard var apex = run.first else { return }
            for index in run where vertices[index - 1].radius < vertices[apex - 1].radius { apex = index }
            let entry = run[0] - 1
            let exit = run[run.count - 1] + 1
            var radius = vertex(line[entry], line[apex], line[exit]).radius
            if radius.isInfinite { radius = vertices[apex - 1].radius }
            corners.append(
                Corner(
                    ordinal: corners.count, apex: line[apex], minRadius: radius,
                    turn: vertices[apex - 1].turn == .left ? .left : .right,
                    entry: distances[entry], apexDistance: distances[apex], exit: distances[exit]))
            run.removeAll()
        }

        for (offset, vertex) in vertices.enumerated() {
            let index = offset + 1
            let turning = vertex.turn != nil && vertex.radius < cornerMaxRadius
            if turning, run.isEmpty || vertices[run[run.count - 1] - 1].turn == vertex.turn {
                run.append(index)
                continue
            }
            closeRun()
            if turning { run.append(index) }
        }
        closeRun()
        return corners
    }
}
