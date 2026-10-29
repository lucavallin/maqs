import MaqsData
import SwiftUI

/// The record of a place tapped on the map.
struct PlaceRecordSheet: View {
    let place: Place
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                OptionalRow("Kind", place.kind.displayName)
                OptionalRow("Elevation", place.elevation.map { "\(Int($0.rounded())) m" })
                ForEach(place.localizedNames.keys.sorted(), id: \.self) { language in
                    OptionalRow("Name (\(language))", place.localizedNames[language])
                }
                OptionalRow("Wikidata", place.wikidata)
                OptionalRow("Label priority", place.rankScore.formatted(.number.precision(.fractionLength(1))))
                OptionalRow("Region", place.region)
            }
            .navigationTitle(place.name ?? place.kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
