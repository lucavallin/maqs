// swift-tools-version: 6.2
import PackageDescription

let warningsAsErrors: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Maqs",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MaqsCore", targets: ["MaqsCore"]),
        .library(name: "MaqsData", targets: ["MaqsData"]),
        .library(name: "MaqsTerrain", targets: ["MaqsTerrain"]),
    ],
    targets: [
        .target(
            name: "MaqsCore",
            resources: [.copy("Resources/sources.json")],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MaqsData",
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MaqsTerrain",
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MaqsTestSupport",
            path: "Tests/MaqsTestSupport",
            sources: ["Sources"],
            resources: [.copy("Fixtures")],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MaqsCoreTests",
            dependencies: ["MaqsCore", "MaqsTestSupport"],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MaqsDataTests",
            dependencies: ["MaqsData", "MaqsTestSupport"],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MaqsTerrainTests",
            dependencies: ["MaqsTerrain", "MaqsTestSupport"],
            swiftSettings: warningsAsErrors
        ),
    ],
    swiftLanguageModes: [.v6]
)
