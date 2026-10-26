/// One decoded tile of metres above sea level, sampled with the pipeline's bilinear rule.
final class ElevationTile: Sendable {
    let size: Int
    private let elevations: [Float]

    /// `elevations` holds `size * size` values, row by row from the north-west corner.
    init(size: Int, elevations: [Float]) throws(TerrainError) {
        guard size > 0, elevations.count == size * size else {
            throw .invalidInput("tile of \(size) pixels needs \(size * size) elevations, got \(elevations.count)")
        }
        self.size = size
        self.elevations = elevations
    }

    /// Bilinear elevation at a pixel position; pixel centres sit at +0.5 and positions outside the outer centres clamp to the edge.
    func elevation(pixelX: Double, pixelY: Double) -> Double {
        let last = Double(size - 1)
        let x = min(max(pixelX - 0.5, 0), last)
        let y = min(max(pixelY - 0.5, 0), last)
        let x0 = Int(x)
        let y0 = Int(y)
        let x1 = min(x0 + 1, size - 1)
        let y1 = min(y0 + 1, size - 1)
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let top = value(x0, y0) * (1 - fx) + value(x1, y0) * fx
        let bottom = value(x0, y1) * (1 - fx) + value(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Memory held by the elevations, for cache accounting.
    var byteCount: Int { elevations.count * MemoryLayout<Float>.size }

    private func value(_ x: Int, _ y: Int) -> Double {
        Double(elevations[y * size + x])
    }
}
