import Foundation
import Testing

@testable import MaqsUI

@Suite struct StyleAssemblerTests {
    typealias JSON = [String: Any]

    static let basemap = TileTemplate(
        template: "https://tiles.example/osm/{z}/{x}/{y}", minZoom: 0, maxZoom: 14, tileSize: nil, attribution: ["A", "B"])
    static let terrain = TileTemplate(
        template: "https://tiles.example/dem/{z}/{x}/{y}", minZoom: 0, maxZoom: 12, tileSize: 512, attribution: ["Terrain"])

    static func inputs(
        dark: Bool = false, terrain: TileTemplate? = StyleAssemblerTests.terrain, language: String? = nil,
        pois: Set<PointOfInterest> = [], overlays: [OverlaySource] = [], kinds: Set<String>? = nil, trails: Bool = true
    ) -> StyleInputs {
        StyleInputs(
            basemap: basemap, terrain: terrain, glyphs: "glyphs://{fontstack}/{range}", sprite: "sprite://base",
            labelLanguage: language, pointsOfInterest: pois, overlays: overlays, visiblePlaceKinds: kinds,
            showsTrails: trails, content: ContentStyle(dark: dark, accentHex: "#FF5500"))
    }

    static func overlays(_ regions: [String]) -> [OverlaySource] {
        regions.flatMap { region in
            [OverlayLayer.trails, .places].map {
                OverlaySource(region: region, layer: $0, fileURL: URL(filePath: "/data/\(region)-\($0.rawValue).pmtiles"))
            }
        }
    }

    static let minimal = Data(
        """
        {"version": 8, "sources": {"basemap": {"type": "vector", "tiles": ["maqs://placeholder"]}},
         "layers": [
          {"id": "background", "type": "background"},
          {"id": "fill", "type": "fill", "source": "basemap", "source-layer": "land"},
          {"id": "label", "type": "symbol", "source": "basemap", "source-layer": "place_labels",
           "layout": {"text-field": ["get", "name"]}},
          {"id": "label-brace", "type": "symbol", "source": "basemap", "source-layer": "place_labels",
           "layout": {"text-field": "{name}"}},
          {"id": "label-other", "type": "symbol", "source": "basemap", "source-layer": "place_labels",
           "layout": {"text-field": "{ref}"}},
          {"id": "label-expr", "type": "symbol", "source": "basemap", "source-layer": "place_labels",
           "layout": {"text-field": ["get", "ref"]}},
          {"id": "poi-amenity", "type": "symbol", "source": "basemap", "source-layer": "pois",
           "filter": ["has", "amenity"], "layout": {"visibility": "none"}, "metadata": {"maqs:poi-key": "amenity"}},
          {"id": "poi-tourism", "type": "symbol", "source": "basemap", "source-layer": "pois",
           "layout": {"visibility": "none"}, "metadata": {"maqs:poi-key": "tourism"}}
         ]}
        """.utf8)

    func assemble(_ base: Data, _ inputs: StyleInputs) throws -> JSON {
        let text = try StyleAssembler.assemble(base, inputs)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)
    }

    func bundled(dark: Bool, _ inputs: StyleInputs) throws -> JSON {
        try assemble(BundledAssets.defaultStyle(dark: dark), inputs)
    }

    func layers(_ style: JSON) -> [JSON] { style["layers"] as? [JSON] ?? [] }
    func ids(_ style: JSON) -> [String] { layers(style).compactMap { $0["id"] as? String } }
    func layer(_ style: JSON, _ id: String) throws -> JSON { try #require(layers(style).first { $0["id"] as? String == id }) }
    func sources(_ style: JSON) -> JSON { style["sources"] as? JSON ?? [:] }
    func json(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [false, true])
    func fillsTheTileTemplatesAndZooms(dark: Bool) throws {
        let style = try bundled(dark: dark, Self.inputs(dark: dark))
        let basemap = try #require(sources(style)["basemap"] as? JSON)
        #expect(basemap["type"] as? String == "vector")
        #expect(basemap["tiles"] as? [String] == [Self.basemap.template])
        #expect(basemap["minzoom"] as? Int == 0)
        #expect(basemap["maxzoom"] as? Int == 14)
        #expect(basemap["attribution"] as? String == "A · B")
        #expect(basemap["tileSize"] == nil)
        let terrain = try #require(sources(style)["terrain"] as? JSON)
        #expect(terrain["type"] as? String == "raster-dem")
        #expect(terrain["tiles"] as? [String] == [Self.terrain.template])
        #expect(terrain["encoding"] as? String == "terrarium")
        #expect(terrain["maxzoom"] as? Int == 12)
        #expect(terrain["tileSize"] as? Int == 512)
        #expect(terrain["attribution"] as? String == "Terrain")
    }

    /// The map compares the JSON it built with the JSON MapLibre shows and loads a style only when they differ, so the
    /// same inputs must give the same text: a reload clears what the map added at run time.
    @Test func theSameInputsGiveTheSameJSON() throws {
        let base = try BundledAssets.defaultStyle(dark: false)
        let inputs = Self.inputs(overlays: Self.overlays(["veneto", "test"]))
        let first = try StyleAssembler.assemble(base, inputs)
        for _ in 0..<5 {
            #expect(try StyleAssembler.assemble(base, inputs) == first)
        }
    }

    @Test func removesTheHillshadeAndTheTerrainSourceWithoutTerrain() throws {
        let style = try bundled(dark: false, Self.inputs(terrain: nil))
        #expect(sources(style)["terrain"] == nil)
        #expect(layers(style).allSatisfy { $0["source"] as? String != "terrain" })
        #expect(!ids(style).contains("hillshade"))
        #expect(ids(style).contains("background"))
    }

    @Test func keepsTheHillshadeWithTerrain() throws {
        #expect(try ids(bundled(dark: false, Self.inputs())).contains("hillshade"))
    }

    @Test func replacesGlyphsAndSprite() throws {
        let style = try bundled(dark: false, Self.inputs())
        #expect(style["glyphs"] as? String == "glyphs://{fontstack}/{range}")
        #expect(style["sprite"] as? String == "sprite://base")
    }

    @Test func coalescesOnlyTheExactNameExpressions() throws {
        let style = try assemble(Self.minimal, Self.inputs(language: "it"))
        let expected = #"["coalesce",["get","name_it"],["get","name"]]"#
        for id in ["label", "label-brace"] {
            let field = try (layer(style, id)["layout"] as? JSON)?["text-field"]
            #expect(json(field) == expected)
        }
        #expect((try layer(style, "label-other")["layout"] as? JSON)?["text-field"] as? String == "{ref}")
        #expect(json((try layer(style, "label-expr")["layout"] as? JSON)?["text-field"]) == #"["get","ref"]"#)
    }

    @Test func leavesNamesAloneWithoutALanguage() throws {
        let style = try assemble(Self.minimal, Self.inputs())
        #expect(json((try layer(style, "label")["layout"] as? JSON)?["text-field"]) == #"["get","name"]"#)
        #expect((try layer(style, "label-brace")["layout"] as? JSON)?["text-field"] as? String == "{name}")
    }

    @Test func showsOnlyThePointsOfInterestAsked() throws {
        let pois: Set = [
            PointOfInterest(key: "amenity", value: "fuel"), PointOfInterest(key: "amenity", value: "shelter"),
        ]
        let style = try assemble(Self.minimal, Self.inputs(pois: pois))
        let amenity = try layer(style, "poi-amenity")
        #expect((amenity["layout"] as? JSON)?["visibility"] as? String == "visible")
        #expect(json(amenity["filter"]) == #"["all",["has","amenity"],["in",["get","amenity"],["literal",["fuel","shelter"]]]]"#)
        let tourism = try layer(style, "poi-tourism")
        #expect((tourism["layout"] as? JSON)?["visibility"] as? String == "none")
        #expect(tourism["filter"] == nil)
    }

    @Test func buildsAFilterWhenThePointOfInterestLayerHadNone() throws {
        let style = try assemble(Self.minimal, Self.inputs(pois: [PointOfInterest(key: "tourism", value: "alpine_hut")]))
        #expect(json(try layer(style, "poi-tourism")["filter"]) == #"["in",["get","tourism"],["literal",["alpine_hut"]]]"#)
    }

    @Test(arguments: [false, true])
    func hidesEveryPointOfInterestLayerByDefault(dark: Bool) throws {
        let style = try bundled(dark: dark, Self.inputs(dark: dark))
        let poi = layers(style).filter { ($0["metadata"] as? JSON)?["maqs:poi-key"] != nil }
        #expect(!poi.isEmpty)
        #expect(poi.allSatisfy { ($0["layout"] as? JSON)?["visibility"] as? String == "none" })
    }

    static let trailLines = [
        "maqs-trails-veneto-casing", "maqs-trails-veneto-line", "maqs-trails-veneto-selected",
        "maqs-trails-friuli-casing", "maqs-trails-friuli-line", "maqs-trails-friuli-selected",
    ]
    /// The overlay layers that go among the base layers, right below its first symbol layer, in this order.
    static let underBaseLabels = trailLines + ["maqs-places-veneto-names", "maqs-places-friuli-names"]

    @Test func appendsPlatesAndPlacesAfterTheBaseLayersInOrder() throws {
        let overlays = Self.overlays(["veneto", "friuli"])
        let base = try Array(ids(bundled(dark: false, Self.inputs())).dropLast(7))
        let style = try bundled(dark: false, Self.inputs(overlays: overlays))
        // The trail lines and settlement names sit among the base layers (the next test); the rest follows them.
        let all = ids(style).filter { !Self.underBaseLabels.contains($0) }
        #expect(Array(all.prefix(base.count)) == base)
        let tail = Array(all.dropFirst(base.count).prefix(5))
        #expect(tail == [
            "maqs-trails-veneto-plate", "maqs-trails-friuli-plate", "maqs-places-veneto", "maqs-places-friuli",
            "maqs-lines-hidden",
        ])
        let source = try #require(sources(style)["maqs-trails-veneto"] as? JSON)
        #expect(source["type"] as? String == "vector")
        #expect(source["url"] as? String == "pmtiles://file:///data/veneto-trails.pmtiles")
        #expect(sources(style)["maqs-places-friuli"] != nil)
        let plate = try layer(style, "maqs-trails-veneto-plate")
        #expect(plate["source"] as? String == "maqs-trails-veneto")
        #expect(plate["source-layer"] as? String == "trails")
        #expect(try layer(style, "maqs-places-veneto")["source-layer"] as? String == "places")
    }

    /// Every base label stays above the trail lines and the settlement names, so the base map's town and road names
    /// win label placement; the base layers below them keep their order.
    @Test(arguments: [false, true])
    func putsTheTrailLinesAndSettlementNamesRightBelowTheFirstBaseSymbolLayer(dark: Bool) throws {
        let base = try layers(bundled(dark: dark, Self.inputs()))
        let firstSymbol = try #require(base.firstIndex { $0["type"] as? String == "symbol" })
        let style = try bundled(dark: dark, Self.inputs(dark: dark, overlays: Self.overlays(["veneto", "friuli"])))
        let all = ids(style)
        let block = Self.underBaseLabels
        #expect(Array(all[firstSymbol..<(firstSymbol + block.count)]) == block)
        #expect(Array(all.prefix(firstSymbol)) == base.prefix(firstSymbol).compactMap { $0["id"] as? String })
        #expect(all[firstSymbol + block.count] == base[firstSymbol]["id"] as? String)
    }

    @Test func putsTheTrailLinesAfterABaseWithNoSymbolLayer() throws {
        let base = Data(
            """
            {"sources": {"basemap": {"type": "vector"}},
             "layers": [{"id": "background", "type": "background"},
                        {"id": "fill", "type": "fill", "source": "basemap", "source-layer": "land"}]}
            """.utf8)
        let style = try assemble(base, Self.inputs(terrain: nil, overlays: Self.overlays(["v"])))
        #expect(Array(ids(style).prefix(7)) == [
            "background", "fill", "maqs-trails-v-casing", "maqs-trails-v-line", "maqs-trails-v-selected",
            "maqs-places-v-names", "maqs-trails-v-plate",
        ])
    }

    @Test func stylesTheTrailOverlay() throws {
        let style = try bundled(dark: false, Self.inputs(overlays: Self.overlays(["veneto"])))
        let casing = try layer(style, "maqs-trails-veneto-casing")
        #expect((casing["paint"] as? JSON)?["line-width"] as? Double == 8)
        #expect((casing["paint"] as? JSON)?["line-color"] as? String == "#FFFFFF")
        #expect(try (layer(style, "maqs-trails-veneto-line")["paint"] as? JSON)?["line-width"] as? Double == 4)
        let selected = try layer(style, "maqs-trails-veneto-selected")
        #expect(json(selected["filter"]) == #"["==",["get","id"],-1]"#)
        #expect((selected["paint"] as? JSON)?["line-color"] as? String == "#FF5500")
        #expect((selected["paint"] as? JSON)?["line-width"] as? Double == 5)
        let plate = try layer(style, "maqs-trails-veneto-plate")
        let layout = try #require(plate["layout"] as? JSON)
        #expect(layout["symbol-placement"] as? String == "line")
        #expect(layout["icon-image"] as? String == "maqs-plate-light")
        #expect(layout["icon-text-fit"] as? String == "both")
        #expect(json(layout["text-field"]) == #"["get","ref"]"#)
        #expect(json(layout["text-font"]) == #"["noto_sans_bold"]"#)
        #expect(layout["text-size"] as? Double == 11)
        #expect((plate["paint"] as? JSON)?["text-color"] as? String == "#101620")
        #expect(json(plate["filter"]) == #"["all",["has","ref"],["!=",["get","ref"],""]]"#)
    }

    @Test(arguments: [false, true])
    func greyTrailsAndTheirPlatesStartAtZoom11AndTheSelectedTrailShowsAtEveryZoom(dark: Bool) throws {
        let style = try bundled(dark: dark, Self.inputs(dark: dark, overlays: Self.overlays(["veneto"])))
        for suffix in ["casing", "line", "plate"] {
            #expect(try layer(style, "maqs-trails-veneto-\(suffix)")["minzoom"] as? Double == 11, "\(suffix)")
        }
        #expect(try layer(style, "maqs-trails-veneto-selected")["minzoom"] == nil)
    }

    @Test func namesThePlateOfTheSchemeInUse() throws {
        let style = try bundled(dark: true, Self.inputs(dark: true, overlays: Self.overlays(["veneto"])))
        let layout = try #require(try layer(style, "maqs-trails-veneto-plate")["layout"] as? JSON)
        #expect(layout["icon-image"] as? String == "maqs-plate-dark")
    }

    @Test func omitsTrailLayersWithoutTrails() throws {
        let style = try bundled(dark: false, Self.inputs(overlays: Self.overlays(["veneto"]), trails: false))
        #expect(!ids(style).contains { $0.hasPrefix("maqs-trails-") })
        #expect(ids(style).contains("maqs-places-veneto"))
    }

    @Test func stylesThePlacesOverlay() throws {
        let style = try bundled(dark: true, Self.inputs(dark: true, language: "de", overlays: Self.overlays(["veneto"])))
        let places = try layer(style, "maqs-places-veneto")
        let layout = try #require(places["layout"] as? JSON)
        #expect(json(layout["icon-image"]) == #"["coalesce",["image",["concat","maqs-place-",["get","kind"],"-dark"]],["image","maqs-place-other-dark"]]"#)
        #expect(json(layout["text-field"]) == #"["coalesce",["get","name_de"],["get","name"]]"#)
        #expect(json(layout["symbol-sort-key"]) == #"["-",0,["get","rank_score"]]"#)
        #expect(layout["text-size"] as? Double == 13)
        #expect(layout["text-offset"] as? [Double] == [0, 0.8])
        #expect((places["paint"] as? JSON)?["text-halo-width"] as? Double == 2)
        #expect((places["paint"] as? JSON)?["text-halo-color"] as? String == "#191F28")
        #expect(json(places["filter"]) == #"["!",["in",["get","kind"],["literal",["hamlet","isolated_dwelling","village"]]]]"#)
        #expect(layout["visibility"] as? String != "none")
    }

    @Test(arguments: [false, true])
    func settlementsAreANameWithNoIconAndNoOffset(dark: Bool) throws {
        let style = try bundled(dark: dark, Self.inputs(dark: dark, language: "de", overlays: Self.overlays(["veneto"])))
        let names = try layer(style, "maqs-places-veneto-names")
        #expect(names["type"] as? String == "symbol")
        #expect(names["source"] as? String == "maqs-places-veneto")
        #expect(names["source-layer"] as? String == "places")
        #expect(json(names["filter"]) == #"["in",["get","kind"],["literal",["hamlet","isolated_dwelling","village"]]]"#)
        let layout = try #require(names["layout"] as? JSON)
        #expect(layout["icon-image"] == nil)
        #expect(layout["text-offset"] == nil)
        #expect(layout["text-anchor"] == nil)
        #expect(json(layout["text-field"]) == #"["coalesce",["get","name_de"],["get","name"]]"#)
        #expect(json(layout["text-font"]) == #"["noto_sans_bold"]"#)
        #expect(layout["text-size"] as? Double == 13)
        #expect(json(layout["symbol-sort-key"]) == #"["-",0,["get","rank_score"]]"#)
        #expect((names["paint"] as? JSON)?["text-halo-width"] as? Double == 2)
        #expect((names["paint"] as? JSON)?["text-halo-color"] as? String == (dark ? "#191F28" : "#FFFFFF"))
    }

    @Test func filtersPlaceKindsAndHidesWhenEmpty() throws {
        let some = try bundled(dark: false, Self.inputs(overlays: Self.overlays(["v"]), kinds: ["peak", "village"]))
        let settlements = #"["literal",["hamlet","isolated_dwelling","village"]]"#
        #expect(json(try layer(some, "maqs-places-v")["filter"])
            == #"["all",["!",["in",["get","kind"],"# + settlements + #"]],["in",["get","kind"],["literal",["peak","village"]]]]"#)
        #expect(json(try layer(some, "maqs-places-v-names")["filter"])
            == #"["all",["in",["get","kind"],"# + settlements + #"],["in",["get","kind"],["literal",["peak","village"]]]]"#)
        let none = try bundled(dark: false, Self.inputs(overlays: Self.overlays(["v"]), kinds: []))
        for id in ["maqs-places-v", "maqs-places-v-names"] {
            #expect((try layer(none, id)["layout"] as? JSON)?["visibility"] as? String == "none", "\(id)")
        }
    }

    @Test func appendsTheContentLayersLastInOrder() throws {
        let light = ids(try bundled(dark: false, Self.inputs()))
        #expect(Array(light.suffix(7)) == [
            "maqs-lines-hidden", "maqs-lines-casing-edge", "maqs-lines-casing", "maqs-lines-solid", "maqs-lines-active",
            "maqs-markers", "maqs-markers-selected",
        ])
        let dark = ids(try bundled(dark: true, Self.inputs(dark: true)))
        #expect(Array(dark.suffix(7)) == [
            "maqs-lines-hidden", "maqs-lines-glow", "maqs-lines-casing", "maqs-lines-solid", "maqs-lines-active",
            "maqs-markers", "maqs-markers-selected",
        ])
        #expect(!light.contains("maqs-lines-glow"))
        #expect(!dark.contains("maqs-lines-casing-edge"))
    }

    @Test func contentSourcesAreEmptyGeoJSON() throws {
        let style = try bundled(dark: false, Self.inputs())
        for name in ["maqs-lines", "maqs-markers"] {
            let source = try #require(sources(style)[name] as? JSON)
            #expect(source["type"] as? String == "geojson")
            #expect(json(source["data"]) == #"{"features":[],"type":"FeatureCollection"}"#)
        }
    }

    @Test(arguments: [false, true])
    func stylesTheContentLines(dark: Bool) throws {
        let style = try bundled(dark: dark, Self.inputs(dark: dark))
        let casingColor = dark ? "#191F28" : "#FFFFFF"
        let hidden = try layer(style, "maqs-lines-hidden")
        #expect(json(hidden["filter"]) == #"["==",["get","maqs_style"],"hidden"]"#)
        #expect(json((hidden["paint"] as? JSON)?["line-dasharray"]) == "[1.333,1.667]")
        #expect((hidden["paint"] as? JSON)?["line-width"] as? Double == 3)
        #expect((hidden["paint"] as? JSON)?["line-color"] as? String == (dark ? "rgba(230,237,243,0.5)" : "rgba(16,22,32,0.5)"))
        let casing = try layer(style, "maqs-lines-casing")
        #expect((casing["paint"] as? JSON)?["line-width"] as? Double == 8)
        #expect((casing["paint"] as? JSON)?["line-color"] as? String == casingColor)
        let solid = try layer(style, "maqs-lines-solid")
        #expect((solid["paint"] as? JSON)?["line-width"] as? Double == 4)
        #expect((solid["paint"] as? JSON)?["line-color"] as? String == (dark ? "#737980" : "#8A8F96"))
        #expect(json(solid["filter"]) == #"["all",["==",["get","maqs_style"],"solid"],["!=",["get","maqs_active"],true]]"#)
        let active = try layer(style, "maqs-lines-active")
        #expect((active["paint"] as? JSON)?["line-width"] as? Double == 5)
        #expect((active["paint"] as? JSON)?["line-color"] as? String == "#FF5500")
        #expect(json(active["filter"]) == #"["all",["==",["get","maqs_style"],"solid"],["==",["get","maqs_active"],true]]"#)
        for id in ["maqs-lines-hidden", "maqs-lines-casing", "maqs-lines-solid", "maqs-lines-active"] {
            let layout = try #require(layer(style, id)["layout"] as? JSON)
            #expect(layout["line-cap"] as? String == "round")
            #expect(layout["line-join"] as? String == "round")
            #expect(try layer(style, id)["source"] as? String == "maqs-lines")
        }
    }

    @Test func glowIsAccentBlurredAndDarkOnly() throws {
        let glow = try layer(bundled(dark: true, Self.inputs(dark: true)), "maqs-lines-glow")
        let paint = try #require(glow["paint"] as? JSON)
        #expect(paint["line-color"] as? String == "#FF5500")
        #expect(paint["line-opacity"] as? Double == 0.6)
        #expect(paint["line-width"] as? Double == 12)
        #expect(paint["line-blur"] as? Double == 6)
        #expect(json(glow["filter"]) == #"["all",["==",["get","maqs_style"],"solid"],["==",["get","maqs_glow"],true]]"#)
    }

    @Test func casingEdgeIsALightOnlyThinOutline() throws {
        let edge = try layer(bundled(dark: false, Self.inputs()), "maqs-lines-casing-edge")
        let paint = try #require(edge["paint"] as? JSON)
        #expect(paint["line-width"] as? Double == 9)
        #expect(paint["line-color"] as? String == "#101620")
        #expect(paint["line-opacity"] as? Double == 0.25)
        #expect(json(edge["filter"]) == #"["==",["get","maqs_style"],"solid"]"#)
    }

    @Test func stylesTheMarkers() throws {
        let style = try bundled(dark: false, Self.inputs())
        let markers = try layer(style, "maqs-markers")
        #expect(markers["source"] as? String == "maqs-markers")
        #expect(json(markers["filter"]) == #"["!=",["get","maqs_selected"],true]"#)
        let layout = try #require(markers["layout"] as? JSON)
        #expect(json(layout["icon-image"]) == #"["get","maqs_image"]"#)
        #expect(json(layout["text-field"]) == #"["get","maqs_label"]"#)
        #expect(layout["text-anchor"] as? String == "top")
        #expect(layout["icon-allow-overlap"] as? Bool == true)
        #expect(layout["text-optional"] as? Bool == true)
        #expect(json(layout["text-font"]) == #"["noto_sans_bold"]"#)
        #expect(layout["text-size"] as? Double == 13)
        #expect((markers["paint"] as? JSON)?["text-halo-width"] as? Double == 2)
        #expect((markers["paint"] as? JSON)?["text-halo-color"] as? String == "#FFFFFF")
        let selected = try layer(style, "maqs-markers-selected")
        #expect(json(selected["filter"]) == #"["==",["get","maqs_selected"],true]"#)
        #expect(json((selected["layout"] as? JSON)?["icon-image"]) == #"["get","maqs_image"]"#)
    }

    @Test func worksOnAMinimalCustomStyle() throws {
        let style = try assemble(Self.minimal, Self.inputs(terrain: nil, overlays: Self.overlays(["v"])))
        #expect(ids(style).prefix(12) == [
            "background", "fill", "maqs-trails-v-casing", "maqs-trails-v-line", "maqs-trails-v-selected", "maqs-places-v-names",
            "label", "label-brace", "label-other", "label-expr", "poi-amenity", "poi-tourism",
        ])
        #expect(ids(style).last == "maqs-markers-selected")
    }

    @Test func rejectsABaseWithMaqsIds() throws {
        let layerClash = Data(#"{"sources":{"basemap":{"type":"vector"}},"layers":[{"id":"maqs-x","type":"background"}]}"#.utf8)
        let sourceClash = Data(#"{"sources":{"basemap":{"type":"vector"},"maqs-s":{"type":"vector"}},"layers":[]}"#.utf8)
        for base in [layerClash, sourceClash] {
            #expect(throws: MapError.self) { try StyleAssembler.assemble(base, Self.inputs()) }
        }
    }

    @Test func dropsASourceURLSoTheTemplateApplies() throws {
        let base = Data(
            """
            {"sources":{"basemap":{"type":"vector","url":"https://other.example/tiles.json"},
             "terrain":{"type":"raster-dem","url":"https://other.example/dem.json"}},"layers":[]}
            """.utf8)
        let style = try assemble(base, Self.inputs())
        for name in ["basemap", "terrain"] {
            let source = try #require(sources(style)[name] as? JSON)
            #expect(source["url"] == nil)
            #expect(source["tiles"] != nil)
        }
    }

    @Test func rejectsUnusableBases() {
        let bases = [
            "not json", "[]", #"{"sources":{"basemap":{"type":"vector"}}}"#, #"{"layers":[]}"#,
            #"{"sources":{"other":{"type":"vector"}},"layers":[]}"#, #"{"sources":{"basemap":{"type":"raster"}},"layers":[]}"#,
            #"{"sources":{"basemap":{"type":"vector"}},"layers":[{"id":"a","type":"background"},"x"]}"#,
            #"{"sources":{"basemap":{"type":"vector"},"extra":3},"layers":[]}"#,
        ]
        for base in bases {
            do {
                _ = try StyleAssembler.assemble(Data(base.utf8), Self.inputs())
                Issue.record("accepted \(base)")
            } catch {
                guard case .invalidStyle(let reason) = error else { Issue.record("wrong error for \(base)"); continue }
                #expect(!reason.isEmpty)
            }
        }
    }
}
