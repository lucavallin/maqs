import Testing
@testable import MaqsTerrain

@Suite struct TerrariumTests {
    @Test(arguments: [
        (UInt8(128), UInt8(0), UInt8(0), 0.0),
        (131, 232, 128, 1000.5),
        (0, 0, 0, -32768.0),
        (255, 255, 255, 32767.99609375),
    ])
    func decodesKnownValues(red: UInt8, green: UInt8, blue: UInt8, expected: Double) {
        #expect(Terrarium.elevation(red: red, green: green, blue: blue) == expected)
    }
}
