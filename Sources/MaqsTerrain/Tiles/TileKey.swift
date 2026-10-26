/// The address of one tile in the XYZ scheme.
struct TileKey: Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int
}
