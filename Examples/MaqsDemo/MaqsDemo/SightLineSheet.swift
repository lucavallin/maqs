import CoreLocation
import SwiftUI

/// Places along a bearing from the map's centre: a bearing slider, the sight line and the places on the map, and the
/// elevation profile along the line.
struct SightLineSheet: View {
    let model: DemoModel
    @State private var bearing = 0.0
    @State private var detent = PresentationDetent.medium
    @State private var origin: CLLocationCoordinate2D?
    /// The origin the map was last fitted around.
    @State private var framed: Request?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Slider(value: $bearing, in: 0...359, step: 1) {
                        Text("Bearing")
                    } minimumValueLabel: {
                        Text("0°")
                    } maximumValueLabel: {
                        Text("359°")
                    }
                    .accessibilityValue("\(Int(bearing)) degrees")
                    Button("Start from the map's centre", systemImage: "scope") { origin = model.map.camera.center }
                } header: {
                    Text("Bearing \(Int(bearing))°, \(Int(SightLine.length / 1000)) km")
                }
                if let line = model.sightLine {
                    Section("Elevation profile") {
                        ProfileChart(line: line)
                            .frame(height: 180)
                    }
                    Section("Places near the line") {
                        if line.sights.isEmpty {
                            Text("No places within \(Int(SightLine.halfAngle))° of the line in the downloaded regions.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(line.sights) { sight in
                            LabeledContent(sight.found.place.name ?? sight.found.place.kind.displayName) {
                                Text("\(distance(sight.found.distance)), \(sight.visible ? "in sight" : "out of sight")")
                            }
                        }
                    }
                } else {
                    ProgressView("Sampling the terrain")
                }
            }
            .navigationTitle("Sight line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // The map above the medium sheet stays in use, so its centre and fitted boxes keep clear of the sheet. The large
        // sheet covers the map; its height would only push the centre off the screen, so the medium height stays.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if detent == .medium { model.sheetHeight = height }
        }
        .onAppear { origin = model.map.camera.center }
        .onDisappear {
            model.sheetHeight = 0
            model.clearSightLine()
        }
        .task(id: Request(origin: origin, bearing: bearing)) {
            guard let origin else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // The slider moved again; that bearing replaces this one.
                return
            }
            let place = Request(origin: origin, bearing: 0)
            if framed != place {
                framed = place
                model.frameSightLine(around: origin)
            }
            await model.showSightLine(from: origin, bearing: bearing)
        }
    }

    private func distance(_ metres: Double) -> String {
        Measurement(value: metres / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// What the line depends on, so a new origin or bearing computes it again.
    private struct Request: Equatable {
        let latitude: Double?
        let longitude: Double?
        let bearing: Double

        init(origin: CLLocationCoordinate2D?, bearing: Double) {
            latitude = origin?.latitude
            longitude = origin?.longitude
            self.bearing = bearing
        }
    }
}
