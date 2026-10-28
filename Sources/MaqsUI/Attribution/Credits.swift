import Foundation
import MaqsCore

/// Works out the credits for the layers the map is drawing.
enum Credits {
    /// The layers that draw something, in the order their credits appear.
    private static let order: [Layer] = [.basemap, .terrain, .trails, .places]

    /// Credits for the `drawn` layers: per layer, the online provider strings when it is online (`online` has the
    /// layer), then the manifest's entries for it when its data is installed. A string that equals a manifest
    /// entry's text is that entry, with its URL. Duplicates by text are dropped, the first kept.
    static func credits(
        drawn: Set<Layer>, online: [Layer: [String]], manifest: [Attribution], installed: Set<Layer>
    ) -> [MapCredit] {
        var result: [MapCredit] = []
        var seen: Set<String> = []
        func add(_ credit: MapCredit) {
            if seen.insert(credit.text).inserted { result.append(credit) }
        }
        for layer in order where drawn.contains(layer) {
            for text in online[layer] ?? [] {
                add(MapCredit(text: text, url: manifest.first { $0.text == text }?.url))
            }
            if installed.contains(layer) {
                for entry in manifest where entry.layers.contains(layer) {
                    add(MapCredit(text: entry.text, url: entry.url))
                }
            }
        }
        return result
    }

    /// The `drawn` layers that get no credit at all from these inputs, in credit order: their sources are drawn
    /// without the credit they require, so the map reports them.
    static func uncredited(
        drawn: Set<Layer>, online: [Layer: [String]], manifest: [Attribution], installed: Set<Layer>
    ) -> [Layer] {
        order.filter { layer in
            drawn.contains(layer)
                && credits(drawn: [layer], online: online, manifest: manifest, installed: installed).isEmpty
        }
    }
}
