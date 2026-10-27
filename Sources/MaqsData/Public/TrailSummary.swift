import Foundation

/// A trail as search and area queries list it: everything but the path.
public struct TrailSummary: Sendable, Equatable, Identifiable {
    /// The trail's stable key.
    public let id: TrailID
    /// The region of the file that holds the trail.
    public let region: String
    /// The row id in that region's file, for ``Trails/trail(region:featureID:)``.
    public let featureID: Int64
    /// The trail's number, such as `926` or `CdD27`.
    public let ref: String?
    /// The Italian hiking-network number (`ref:REI`).
    public let refREI: String?
    /// The trail's name.
    public let name: String?
    /// The place the trail starts at.
    public let from: String?
    /// The place the trail ends at.
    public let to: String?
    /// The trail's difficulty.
    public let difficulty: TrailDifficulty
    /// The trail network, such as `rwn` for a regional network.
    public let network: String?
    /// The organisation that maintains the trail, such as `CAI`.
    public let `operator`: String?
    /// The trail's waymark description (`osmc:symbol`).
    public let osmcSymbol: String?
    /// The trail's length in metres.
    public let length: Double
    /// The total climb in metres, from the pipeline's terrain data.
    public let ascent: Double?
    /// The total descent in metres, from the pipeline's terrain data.
    public let descent: Double?
    /// The box around the trail's geometry, or nil when it has none.
    public let area: QueryArea?
    /// How completely the geometry could be assembled.
    public let geometryStatus: GeometryStatus
}
