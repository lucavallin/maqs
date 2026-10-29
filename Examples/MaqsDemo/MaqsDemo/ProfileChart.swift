import Charts
import SwiftUI

/// The ground along the sight line, darker where the observer sees it, with the places that have an elevation.
struct ProfileChart: View {
    let line: SightLine

    var body: some View {
        let floor = (line.samples.map(\.elevation).min() ?? 0) - 50
        Chart {
            ForEach(line.samples) { sample in
                AreaMark(x: .value("Distance", sample.distance / 1000),
                         yStart: .value("Floor", floor), yEnd: .value("Elevation", sample.elevation))
                    .foregroundStyle(.gray.opacity(0.2))
                LineMark(x: .value("Distance", sample.distance / 1000), y: .value("Elevation", sample.elevation),
                         series: .value("Stretch", sample.stretch))
                    .foregroundStyle(sample.inSight ? Color.primary : Color.secondary.opacity(0.5))
            }
            ForEach(line.sights.filter { $0.found.place.elevation != nil }) { sight in
                PointMark(x: .value("Distance", sight.found.distance / 1000),
                          y: .value("Elevation", sight.found.place.elevation ?? 0))
                    .foregroundStyle(sight.visible ? Color.brown : Color.gray)
            }
        }
        .chartXScale(domain: 0...(SightLine.length / 1000))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
        .accessibilityLabel("Elevation profile along the sight line")
    }
}
