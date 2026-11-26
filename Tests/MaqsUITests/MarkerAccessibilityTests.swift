import CoreGraphics
import Testing

@testable import MaqsUI

@Suite struct MarkerAccessibilityTests {
    private func drawn(
        _ id: String, _ label: String?, _ x: CGFloat, _ y: CGFloat, spoken: String? = nil, selected: Bool = false
    ) -> DrawnMarker {
        DrawnMarker(id: id, label: label, spokenLabel: spoken, isSelected: selected, point: CGPoint(x: x, y: y))
    }

    @Test func oneButtonPerDrawnMarkerInReadingOrderLabelledWithItsLabelOrId() {
        let items = MarkerAccessibility.items([
            drawn("b", "Col Visentin", 200, 100),
            drawn("a", "Monte Pizzoc", 50, 100),
            drawn("a", "Monte Pizzoc", 50, 100),
            drawn("c", nil, 10, 300),
            drawn("off", "Away", -100, 0),
        ], in: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(items.map(\.id) == ["a", "b", "c"])
        #expect(items.map(\.label) == ["Monte Pizzoc", "Col Visentin", "c"])
        #expect(items[0].frame == CGRect(x: 28, y: 78, width: 44, height: 44))
    }

    /// An app can say what a marker means beyond its visible label, or keep a marker out of VoiceOver's reach with an
    /// empty spoken label; the selected marker says so.
    @Test func aSpokenLabelOverridesTheLabelAnEmptyOneHidesTheMarkerAndSelectionIsKept() {
        let items = MarkerAccessibility.items([
            drawn("glockner", "Großglockner", 50, 100, spoken: "Großglockner, hidden"),
            drawn("ring", nil, 100, 100, spoken: ""),
            drawn("pizzoc", "Monte Pizzoc", 150, 100, selected: true),
        ], in: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(items.map(\.label) == ["Großglockner, hidden", "Monte Pizzoc"])
        #expect(items.map(\.isSelected) == [false, true])
    }
}
