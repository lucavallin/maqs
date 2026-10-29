import MaqsData
import SwiftUI

/// Trail search over the installed regions: the chosen trail is drawn in the accent and shown whole.
struct TrailSearchSheet: View {
    let model: DemoModel
    @State private var text = ""
    @State private var results: [TrailSummary] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(results) { trail in
                Button {
                    model.select(trail)
                } label: {
                    TrailSummaryRow(trail: trail)
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView("No trails", systemImage: "figure.hiking",
                                           description: Text("Type a trail number, a name or a place. Only downloaded regions are searched."))
                }
            }
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Number, name or place")
            .task(id: text) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    // The text changed again; that search replaces this one.
                    return
                }
                results = await model.searchTrails(text)
            }
            .navigationTitle("Trails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
