import Foundation

/// Turns a base style plus the run-time inputs into the one style JSON the map loads.
///
/// The package's own layers (installed-region overlays and the content lines and markers) are part of the
/// assembled JSON, so a style load needs only their data set again. Works on `JSONSerialization` values,
/// not a model of the style specification: whatever the base style says and this type does not touch
/// passes through unchanged.
enum StyleAssembler {
    private typealias JSON = [String: Any]

    static let reservedPrefix = "maqs-"

    static func assemble(_ base: Data, _ inputs: StyleInputs) throws(MapError) -> String {
        var style = try parse(base)
        var sources = style["sources"] as? JSON ?? [:]
        var layers = style["layers"] as? [JSON] ?? []

        sources["basemap"] = tileSource(sources["basemap"] as? JSON ?? [:], inputs.basemap, encoding: nil)
        if let terrain = inputs.terrain {
            if let source = sources["terrain"] as? JSON {
                sources["terrain"] = tileSource(source, terrain, encoding: "terrarium")
            }
        } else {
            sources["terrain"] = nil
            layers.removeAll { $0["source"] as? String == "terrain" }
        }

        style["glyphs"] = inputs.glyphs
        style["sprite"] = inputs.sprite
        layers = layers.map { adapt($0, inputs) }

        let overlay = overlayStyle(inputs)
        let content = contentStyle(inputs)
        sources.merge(overlay.sources) { _, new in new }
        sources.merge(content.sources) { _, new in new }
        // Every overlay layer goes under the base map's labels: place and road names stay readable over the trails,
        // and the base map's labels, towns among them, always win label placement over the overlays' plates and places.
        // Only the app's own lines and markers draw above them.
        let firstSymbol = layers.firstIndex { $0["type"] as? String == "symbol" } ?? layers.endIndex
        layers.insert(contentsOf: overlay.layers, at: firstSymbol)
        layers += content.layers
        style["sources"] = sources
        style["layers"] = layers

        do {
            // Sorted keys make the text depend on the inputs only: the map loads a style only when the text changes.
            let data = try JSONSerialization.data(withJSONObject: style, options: [.withoutEscapingSlashes, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw .invalidStyle("the assembled style cannot be written as JSON")
        }
    }

    // MARK: Base style

    private static func parse(_ base: Data) throws(MapError) -> JSON {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: base)
        } catch {
            throw .invalidStyle("the style is not valid JSON")
        }
        guard let style = parsed as? JSON else { throw .invalidStyle("the style is not a JSON object") }
        guard let layers = style["layers"] as? [Any] else { throw .invalidStyle("the style has no \"layers\" array") }
        guard let sources = style["sources"] as? JSON, let basemap = sources["basemap"] as? JSON else {
            throw .invalidStyle("the style has no \"basemap\" source")
        }
        guard basemap["type"] as? String == "vector" else { throw .invalidStyle("the \"basemap\" source is not a vector source") }
        if let name = sources.first(where: { !($0.value is JSON) })?.key {
            throw .invalidStyle("the source \"\(name)\" is not a JSON object")
        }
        if layers.contains(where: { !($0 is JSON) }) { throw .invalidStyle("a \"layers\" element is not a JSON object") }
        if let id = sources.keys.first(where: { $0.hasPrefix(reservedPrefix) }) {
            throw .invalidStyle("the source id \"\(id)\" starts with \"\(reservedPrefix)\", which the package reserves")
        }
        for case let layer as JSON in layers {
            if let id = layer["id"] as? String, id.hasPrefix(reservedPrefix) {
                throw .invalidStyle("the layer id \"\(id)\" starts with \"\(reservedPrefix)\", which the package reserves")
            }
        }
        return style
    }

    private static func tileSource(_ source: JSON, _ template: TileTemplate, encoding: String?) -> JSON {
        var source = source
        // MapLibre ignores `tiles` when a `url` is present, which would keep a custom style on its own host.
        source["url"] = nil
        source["tiles"] = [template.template]
        source["minzoom"] = template.minZoom
        source["maxzoom"] = template.maxZoom
        source["tileSize"] = template.tileSize
        source["attribution"] = template.attribution.joined(separator: " · ")
        source["encoding"] = encoding
        return source
    }

    /// Language coalescing for labels and visibility plus filter for point-of-interest layers.
    private static func adapt(_ layer: JSON, _ inputs: StyleInputs) -> JSON {
        var layer = layer
        var layout = layer["layout"] as? JSON ?? [:]
        if let language = inputs.labelLanguage, isPlainName(layout["text-field"]) {
            layout["text-field"] = nameExpression(language)
        }
        if let key = (layer["metadata"] as? JSON)?["maqs:poi-key"] as? String {
            let values = inputs.pointsOfInterest.filter { $0.key == key }.map(\.value).sorted()
            if values.isEmpty {
                layout["visibility"] = "none"
            } else {
                layout["visibility"] = "visible"
                let match: [Any] = ["in", ["get", key], ["literal", values]]
                layer["filter"] = layer["filter"].map { ["all", $0, match] as [Any] } ?? match
            }
        }
        if !layout.isEmpty { layer["layout"] = layout }
        return layer
    }

    private static func isPlainName(_ field: Any?) -> Bool {
        if let text = field as? String { return text == "{name}" }
        if let list = field as? [Any], list.count == 2 {
            return list[0] as? String == "get" && list[1] as? String == "name"
        }
        return false
    }

    private static func nameExpression(_ language: String?) -> [Any] {
        guard let language else { return ["get", "name"] }
        return ["coalesce", ["get", "name_\(language)"], ["get", "name"]]
    }

    // MARK: Palette

    private struct Palette {
        var accent: String
        var casing: String
        var hiddenLine: String
        var solidLine: String

        init(_ content: ContentStyle) {
            accent = content.accentHex
            casing = content.dark ? "#191F28" : "#FFFFFF"
            hiddenLine = content.dark ? "rgba(230,237,243,0.5)" : "rgba(16,22,32,0.5)"
            solidLine = content.dark ? "#737980" : "#8A8F96"
        }
    }

    private static var round: JSON { ["line-cap": "round", "line-join": "round"] }
    private static var boldFont: [String] { ["noto_sans_bold"] }
    private static func isSolid() -> [Any] { ["==", ["get", "maqs_style"], "solid"] }

    private static func line(
        _ id: String, source: String, sourceLayer: String? = nil, filter: Any? = nil, paint: JSON
    ) -> JSON {
        var layer: JSON = ["id": id, "type": "line", "source": source, "layout": round, "paint": paint]
        layer["source-layer"] = sourceLayer
        layer["filter"] = filter
        return layer
    }

    // MARK: Overlays

    /// The overlays' sources and their layers, as the one block that goes below the base map's labels: trail lines,
    /// settlement names, trail plates, place markers, each group in region order. Higher layers are placed first, so
    /// a place marker wins over a plate and a plate over a settlement name.
    private static func overlayStyle(_ inputs: StyleInputs) -> (sources: JSON, layers: [JSON]) {
        let palette = Palette(inputs.content)
        var sources: JSON = [:]
        var lines: [JSON] = []
        var plates: [JSON] = []
        var placeNames: [JSON] = []
        var placeMarkers: [JSON] = []
        for overlay in inputs.overlays {
            let id = "maqs-\(overlay.layer.rawValue)-\(overlay.region)"
            sources[id] = ["type": "vector", "url": "pmtiles://" + overlay.fileURL.absoluteString] as JSON
            switch overlay.layer {
            case .trails:
                guard inputs.showsTrails else { continue }
                lines += trailLines(id, palette)
                plates.append(trailPlate(id, dark: inputs.content.dark))
            case .places:
                placeNames.append(placesLayer(id, inputs, palette, settlements: true))
                placeMarkers.append(placesLayer(id, inputs, palette, settlements: false))
            }
        }
        return (sources, lines + placeNames + plates + placeMarkers)
    }

    /// The zoom from which the grey trails and their plates draw: below it a region's network is a solid mass. The
    /// selected trail draws at every zoom.
    static let trailMinZoom = 11

    private static func trailLines(_ source: String, _ palette: Palette) -> [JSON] {
        func trailLine(_ suffix: String, minZoom: Int? = nil, filter: Any? = nil, paint: JSON) -> JSON {
            var layer = line("\(source)-\(suffix)", source: source, sourceLayer: "trails", filter: filter, paint: paint)
            layer["minzoom"] = minZoom
            return layer
        }
        return [
            trailLine("casing", minZoom: trailMinZoom, paint: ["line-color": palette.casing, "line-width": 8]),
            trailLine("line", minZoom: trailMinZoom, paint: ["line-color": palette.solidLine, "line-width": 4]),
            trailLine("selected", filter: ["==", ["get", "id"], -1] as [Any], paint: ["line-color": palette.accent, "line-width": 5]),
        ]
    }

    private static func trailPlate(_ source: String, dark: Bool) -> JSON {
        [
            "id": "\(source)-plate", "type": "symbol", "source": source, "source-layer": "trails", "minzoom": trailMinZoom,
            "layout": [
                "symbol-placement": "line", "icon-image": dark ? "maqs-plate-dark" : "maqs-plate-light", "icon-text-fit": "both",
                "text-field": ["get", "ref"], "text-font": boldFont, "text-size": 11,
            ] as JSON,
            "filter": ["all", ["has", "ref"], ["!=", ["get", "ref"], ""]] as [Any],
            "paint": ["text-color": "#101620"] as JSON,
        ]
    }

    /// The kinds the places overlay draws as a name only, without a marker.
    static let settlementKinds = ["hamlet", "isolated_dwelling", "village"]

    /// One of a region's two places layers: its settlements as a name only (`<source>-names`), or every other kind as a
    /// round marker with the name under it (`<source>-markers`). Like every overlay layer, each id is its source id plus
    /// a one-word suffix, so no region id can make two layer ids equal.
    private static func placesLayer(_ source: String, _ inputs: StyleInputs, _ palette: Palette, settlements: Bool) -> JSON {
        let scheme = inputs.content.dark ? "-dark" : "-light"
        var layout: JSON = [
            "text-field": nameExpression(inputs.labelLanguage), "text-font": boldFont, "text-size": 13,
            "symbol-sort-key": ["-", 0, ["get", "rank_score"]] as [Any],
        ]
        if !settlements {
            layout["icon-image"] = [
                "coalesce", ["image", ["concat", "maqs-place-", ["get", "kind"], scheme]], ["image", "maqs-place-other\(scheme)"],
            ] as [Any]
            layout["text-anchor"] = "top"
            layout["text-offset"] = [0, 0.8]
            layout["text-optional"] = true
        }
        let isSettlement: [Any] = ["in", ["get", "kind"], ["literal", settlementKinds]]
        var filter: [Any] = settlements ? isSettlement : ["!", isSettlement]
        var layer: JSON = [
            "id": "\(source)-\(settlements ? "names" : "markers")", "type": "symbol", "source": source, "source-layer": "places",
            "paint": ["text-color": inputs.content.dark ? "#E6EDF3" : "#101620", "text-halo-color": palette.casing, "text-halo-width": 2] as JSON,
        ]
        if let kinds = inputs.visiblePlaceKinds {
            if kinds.isEmpty {
                layout["visibility"] = "none"
            } else {
                filter = ["all", filter, ["in", ["get", "kind"], ["literal", kinds.sorted()]]]
            }
        }
        layer["filter"] = filter
        layer["layout"] = layout
        return layer
    }

    // MARK: Content

    private static func contentStyle(_ inputs: StyleInputs) -> (sources: JSON, layers: [JSON]) {
        let palette = Palette(inputs.content)
        let empty: JSON = ["type": "FeatureCollection", "features": [Any]()]
        let sources: JSON = [
            "maqs-lines": ["type": "geojson", "data": empty] as JSON,
            "maqs-markers": ["type": "geojson", "data": empty] as JSON,
        ]
        let active: [Any] = ["==", ["get", "maqs_active"], true]
        var layers: [JSON] = [
            line("maqs-lines-hidden", source: "maqs-lines", filter: ["==", ["get", "maqs_style"], "hidden"] as [Any], paint: [
                "line-color": palette.hiddenLine, "line-width": 3, "line-dasharray": [1.333, 1.667],
            ]),
        ]
        if inputs.content.dark {
            layers.append(line("maqs-lines-glow", source: "maqs-lines", filter: ["all", isSolid(), ["==", ["get", "maqs_glow"], true]] as [Any], paint: [
                "line-color": palette.accent, "line-opacity": 0.6, "line-width": 12, "line-blur": 6,
            ]))
        } else {
            layers.append(line("maqs-lines-casing-edge", source: "maqs-lines", filter: isSolid(), paint: [
                "line-color": "#101620", "line-opacity": 0.25, "line-width": 9,
            ]))
        }
        layers += [
            line("maqs-lines-casing", source: "maqs-lines", filter: isSolid(), paint: ["line-color": palette.casing, "line-width": 8]),
            line("maqs-lines-solid", source: "maqs-lines", filter: ["all", isSolid(), ["!=", ["get", "maqs_active"], true]] as [Any], paint: [
                "line-color": palette.solidLine, "line-width": 4,
            ]),
            line("maqs-lines-active", source: "maqs-lines", filter: ["all", isSolid(), active] as [Any], paint: [
                "line-color": palette.accent, "line-width": 5,
            ]),
            markerLayer("maqs-markers", filter: ["!=", ["get", "maqs_selected"], true], palette),
            markerLayer("maqs-markers-selected", filter: ["==", ["get", "maqs_selected"], true], palette),
        ]
        return (sources, layers)
    }

    private static func markerLayer(_ id: String, filter: [Any], _ palette: Palette) -> JSON {
        [
            "id": id, "type": "symbol", "source": "maqs-markers", "filter": filter,
            "layout": [
                "icon-image": ["get", "maqs_image"], "icon-allow-overlap": true,
                "text-field": ["get", "maqs_label"], "text-font": boldFont, "text-size": 13,
                "text-anchor": "top", "text-offset": [0, 0.8], "text-optional": true,
            ] as JSON,
            "paint": ["text-color": palette.casing == "#FFFFFF" ? "#101620" : "#E6EDF3", "text-halo-color": palette.casing, "text-halo-width": 2] as JSON,
        ]
    }
}
