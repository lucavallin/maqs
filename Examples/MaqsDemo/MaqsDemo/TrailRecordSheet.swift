import MaqsData
import SwiftUI

/// The record of a trail tapped on the map.
struct TrailRecordSheet: View {
    let model: DemoModel
    let trail: Trail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { TrailSummaryRow(trail: trail.summary) }
                Section("Details") {
                    OptionalRow("Number (REI)", trail.summary.refREI)
                    OptionalRow("Difficulty", trail.summary.difficulty.originalValue.map {
                        "\($0) (\(trail.summary.difficulty.scheme ?? "no scale"))"
                    })
                    OptionalRow("Descent", trail.summary.descent.map { "\(Int($0.rounded())) m" })
                    OptionalRow("Operator", trail.summary.operator)
                    OptionalRow("Waymark", trail.summary.osmcSymbol)
                    OptionalRow("Round trip", trail.roundtrip.map { $0 ? "Yes" : "No" })
                    OptionalRow("Surveyed", trail.surveyDate)
                    OptionalRow("Website", trail.website)
                    OptionalRow("Source", [trail.osmType, trail.osmID.map(String.init)].compactMap { $0 }.joined(separator: " "))
                    OptionalRow("Licence", trail.sourceLicence)
                    OptionalRow("Legs", trail.path.isEmpty ? "No geometry" : "\(trail.path.count)")
                }
            }
            .navigationTitle(trail.summary.ref ?? "Trail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Show", systemImage: "map") { model.select(trail.summary) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
