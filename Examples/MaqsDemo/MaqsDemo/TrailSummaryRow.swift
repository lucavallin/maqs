import MaqsData
import SwiftUI

/// A trail's number, name, ends and length.
struct TrailSummaryRow: View {
    let trail: TrailSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let ref = trail.ref { Text(ref).bold() }
                if let name = trail.name {
                    Text(name)
                } else if trail.ref == nil {
                    Text("Unnamed trail")
                }
            }
            if trail.from != nil || trail.to != nil {
                Text("\(trail.from ?? "?") to \(trail.to ?? "?")").font(.footnote).foregroundStyle(.secondary)
            }
            Text(details).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var details: String {
        var parts = [Measurement(value: trail.length / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))]
        if let grade = trail.difficulty.grade { parts.append("difficulty \(grade) of 6") }
        if let ascent = trail.ascent { parts.append("\(Int(ascent.rounded())) m up") }
        parts.append(trail.region)
        return parts.joined(separator: " · ")
    }
}
