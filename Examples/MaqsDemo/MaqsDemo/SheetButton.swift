import SwiftUI

/// A bottom-bar button: title and symbol, or the symbol alone at the accessibility text sizes, where three titled
/// buttons no longer fit one row. VoiceOver reads the title either way.
struct SheetButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            Button(title, systemImage: systemImage, action: action).labelStyle(.iconOnly)
        } else {
            Button(title, systemImage: systemImage, action: action)
        }
    }
}
