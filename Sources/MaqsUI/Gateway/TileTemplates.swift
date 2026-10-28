import Foundation

/// The two tile layers MapLibre asks for.
enum TileLayer: Sendable { case basemap, terrain }

/// One tile, as MapLibre requested it.
struct TileRequest: Sendable, Equatable {
    let layer: TileLayer
    let z: Int
    let x: Int
    let y: Int
}

/// The active online tile URL templates; recognises which requests are tiles and of which layer.
///
/// Matching is exact on scheme, host, port and path. `{z}`, `{x}` and `{y}` stand for plain base-10 integers and may
/// sit anywhere in the path. A request with a query or fragment, a sign, a decimal point, extra or missing segments,
/// or coordinates outside the tile pyramid is not a tile: it never reaches an archive.
struct TileTemplates: Sendable, Equatable {
    var basemap: String
    var terrain: String?

    /// The tile `url` asks for, or nil when it is not one of these templates' tiles.
    func request(for url: URL) -> TileRequest? {
        if let tile = Self.match(url, template: basemap) { return TileRequest(layer: .basemap, z: tile.z, x: tile.x, y: tile.y) }
        if let terrain, let tile = Self.match(url, template: terrain) {
            return TileRequest(layer: .terrain, z: tile.z, x: tile.x, y: tile.y)
        }
        return nil
    }

    /// The URL of `tile` under these templates, or nil when they have no template for its layer or the URL they make
    /// would not read back as the same tile.
    func url(for tile: TileRequest) -> URL? {
        guard let template = tile.layer == .basemap ? basemap : terrain else { return nil }
        let string = template.replacingOccurrences(of: "{z}", with: String(tile.z))
            .replacingOccurrences(of: "{x}", with: String(tile.x)).replacingOccurrences(of: "{y}", with: String(tile.y))
        guard let url = URL(string: string), request(for: url) == tile else { return nil }
        return url
    }

    private static let maximumZoom = 22

    private enum Piece: Equatable {
        case literal(String)
        case placeholder(Character)
    }

    private static func match(_ url: URL, template: String) -> (z: Int, x: Int, y: Int)? {
        guard let parts = split(template),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.query == nil, components.fragment == nil,
            components.user == nil, components.password == nil,
            components.scheme?.lowercased() == parts.scheme,
            components.host?.lowercased() == parts.host,
            components.port == parts.port
        else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.first == "", segments.count == parts.path.count + 1 else { return nil }

        var values: [Character: Int] = [:]
        for (segment, pieces) in zip(segments.dropFirst(), parts.path) {
            guard capture(segment, pieces: pieces, into: &values) else { return nil }
        }
        guard let z = values["z"], let x = values["x"], let y = values["y"],
            values.count == 3, (0...maximumZoom).contains(z)
        else { return nil }
        let size = 1 << z
        guard (0..<size).contains(x), (0..<size).contains(y) else { return nil }
        return (z, x, y)
    }

    /// Reads the placeholders out of one path segment; false when the segment does not fit the pieces or a placeholder
    /// repeats.
    private static func capture(_ segment: String, pieces: [Piece], into values: inout [Character: Int]) -> Bool {
        var rest = Substring(segment)
        for piece in pieces {
            switch piece {
            case .literal(let text):
                guard rest.hasPrefix(text) else { return false }
                rest = rest.dropFirst(text.count)
            case .placeholder(let name):
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty, digits.count <= 8, digits == "0" || !digits.hasPrefix("0"),
                    let value = Int(digits), values[name] == nil
                else { return false }
                values[name] = value
                rest = rest.dropFirst(digits.count)
            }
        }
        return rest.isEmpty
    }

    private static func split(_ template: String) -> (scheme: String, host: String, port: Int?, path: [[Piece]])? {
        guard let schemeEnd = template.range(of: "://") else { return nil }
        let scheme = template[..<schemeEnd.lowerBound].lowercased()
        let afterScheme = template[schemeEnd.upperBound...]
        guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
        let authority = afterScheme[..<pathStart]
        let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = hostAndPort.first, !host.isEmpty, hostAndPort.count <= 2 else { return nil }
        var port: Int?
        if hostAndPort.count == 2 {
            guard let value = Int(hostAndPort[1]) else { return nil }
            port = value
        }
        let path = afterScheme[afterScheme.index(after: pathStart)...]
            .split(separator: "/", omittingEmptySubsequences: false).map { pieces(of: String($0)) }
        return (scheme, host.lowercased(), port, path)
    }

    private static func pieces(of segment: String) -> [Piece] {
        var result: [Piece] = []
        var literal = ""
        var index = segment.startIndex
        while index < segment.endIndex {
            let tail = segment[index...]
            if let name = ["z", "x", "y"].first(where: { tail.hasPrefix("{\($0)}") }) {
                if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                result.append(.placeholder(Character(name)))
                index = segment.index(index, offsetBy: 3)
            } else {
                literal.append(segment[index])
                index = segment.index(after: index)
            }
        }
        if !literal.isEmpty { result.append(.literal(literal)) }
        return result
    }
}
