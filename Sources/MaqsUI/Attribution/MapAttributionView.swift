#if canImport(MapLibre)
import SwiftUI

/// The credits of the sources a ``MaqsMap`` draws, which the data's licences require on screen. The app places it in
/// its chrome, over or beside the map.
///
/// Collapsed, it is an info button with the first credit beside it; the button expands it to every credit, each a
/// link when its source has a page, and collapses it again. The text uses the `caption2` style, so it scales with
/// Dynamic Type and wraps, and the view takes the width it is given: it sets no padding or background of its own. The
/// symbol is the size of the text; the button around it takes taps in at least 44 points square. VoiceOver reads the
/// button as "Map data credits", collapsed or expanded, and each credit as its own element.
public struct MapAttributionView: View {
    /// The smallest side of the button's touch target, in points: the platform's minimum for a control.
    private static let minimumTouchSide: CGFloat = 44

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
                    .frame(minWidth: Self.minimumTouchSide, minHeight: Self.minimumTouchSide)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Map data credits", bundle: .module,
                                     comment: "VoiceOver label of the button that lists the map's data credits"))
            .accessibilityValue(expanded
                ? Text("Expanded", bundle: .module,
                       comment: "VoiceOver value of the credits button while every credit shows")
                : Text("Collapsed", bundle: .module,
                       comment: "VoiceOver value of the credits button while only the first credit shows"))
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
