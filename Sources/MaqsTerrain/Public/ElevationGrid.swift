/// Elevation samples on a regular grid over an area, taken at cell centres.
public struct ElevationGrid: Sendable {
    /// The area the grid covers.
    public let area: TerrainArea
    /// The number of cells from west to east.
    public let columns: Int
    /// The number of cells from north to south.
    public let rows: Int
    /// The samples in row-major order, starting at the centre of the north-west cell.
    public let samples: [ElevationSample]

    init(area: TerrainArea, columns: Int, rows: Int, samples: [ElevationSample]) {
        self.area = area
        self.columns = columns
        self.rows = rows
        self.samples = samples
    }

    /// The sample of one cell; `column` counts from the west and `row` from the north. Traps when out of range, like an array.
    public subscript(column: Int, row: Int) -> ElevationSample {
        precondition((0..<columns).contains(column) && (0..<rows).contains(row), "cell outside the grid")
        return samples[row * columns + column]
    }
}
