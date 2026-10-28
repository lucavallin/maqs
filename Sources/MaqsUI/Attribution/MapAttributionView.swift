#if canImport(MapLibre)
import SwiftUI

/// The credits of the sources a ``MaqsMap`` draws, which the data's licences require on screen. The app places it in
/// its chrome, over or beside the map.
///
/// Collapsed, it is an info button with the first credit beside it; the button expands it to every credit, each a
/// link when its source has a page, and collapses it again. The text uses the `caption2` style, so it scales with
/// Dynamic Type, and the view takes the width it is given: it sets no size, padding or background of its own. VoiceOver
/// reads the button as "Map data credits" and each credit as its own element.
public struct MapAttributionView: View {
    private let map: MaqsMap
    @State private var expanded = false

    /// Creates the credits of `map`, collapsed.
    public init(map: MaqsMap) {
        self.map = map
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel(Text("Map data credits", bundle: .module,
                                     comment: "VoiceOver label of the button that lists the map's data credits"))
            if expanded {
                VStack(alignment: .leading) {
                    ForEach(map.credits) { credit in
                        if let url = credit.url {
                            Link(destination: url) { Text(verbatim: credit.text) }
                        } else {
                            Text(verbatim: credit.text)
                        }
                    }
                }
            } else if let first = map.credits.first {
                Text(verbatim: first.text)
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .contain)
    }
}
#endif
