import SwiftUI

/// A labelled value of a record, or nothing when the record has none.
struct OptionalRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }
}
