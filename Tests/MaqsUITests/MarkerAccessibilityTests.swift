import CoreGraphics
import Testing

@testable import MaqsUI

@Suite struct MarkerAccessibilityTests {
    @Test func oneButtonPerDrawnMarkerInReadingOrderLabelledWithItsLabelOrId() {
        let drawn: [(id: String, label: String?, point: CGPoint)] = [
            ("b", "Col Visentin", CGPoint(x: 200, y: 100)),
            ("a", "Monte Pizzoc", CGPoint(x: 50, y: 100)),
            ("a", "Monte Pizzoc", CGPoint(x: 50, y: 100)),
            ("c", nil, CGPoint(x: 10, y: 300)),
            ("off", "Away", CGPoint(x: -100, y: 0)),
        ]
        let items = MarkerAccessibility.items(drawn, in: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(items.map(\.id) == ["a", "b", "c"])
        #expect(items.map(\.label) == ["Monte Pizzoc", "Col Visentin", "c"])
        #expect(items[0].frame == CGRect(x: 28, y: 78, width: 44, height: 44))
    }
}
