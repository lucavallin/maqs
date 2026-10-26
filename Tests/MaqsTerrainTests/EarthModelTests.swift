import Testing
@testable import MaqsTerrain

@Suite struct EarthModelTests {
    @Test func dropWithoutRefractionIsDistanceSquaredOverTwoRadii() {
        let earth = EarthModel(refraction: 0)
        #expect(abs(earth.drop(atDistance: 10_000) - 7.848) < 0.001)
        #expect(abs(earth.drop(atDistance: 100_000) - 784.8) < 0.02)
    }

    @Test func refractionReducesTheDrop() {
        let earth = EarthModel()
        #expect(abs(earth.drop(atDistance: 10_000) - 6.828) < 0.001)
        #expect(abs(earth.drop(atDistance: 100_000) - 682.8) < 0.03)
    }

    @Test func aFlatEarthDropsNothing() {
        #expect(EarthModel.none.drop(atDistance: 100_000) == 0)
    }
}
