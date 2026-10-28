import Testing

@testable import MaqsUI

#if canImport(MapLibre)
import MapLibre
#endif

@Suite struct PackageTests {
    @Test func theModuleBuildsOnEveryPlatform() {
        #expect(MaqsUI.moduleName == "MaqsUI")
    }

    #if canImport(MapLibre)
    @Test func mapLibreLinksOnIOS() {
        #expect(NSStringFromClass(MLNMapView.self) == "MLNMapView")
    }
    #endif
}
