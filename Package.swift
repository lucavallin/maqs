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
        .library(name: "MaqsUI", targets: ["MaqsUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", "6.31.0"..<"7.0.0"),
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
            name: "MaqsPMTiles",
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MaqsTerrain",
            dependencies: ["MaqsPMTiles"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MaqsUI",
            dependencies: [
                "MaqsCore", "MaqsPMTiles",
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources")],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MaqsTestSupport",
            dependencies: ["MaqsPMTiles"],
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
            name: "MaqsPMTilesTests",
            dependencies: ["MaqsPMTiles", "MaqsTestSupport"],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MaqsTerrainTests",
            dependencies: ["MaqsTerrain", "MaqsTestSupport"],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MaqsUITests",
            dependencies: ["MaqsUI", "MaqsCore", "MaqsData", "MaqsTestSupport"],
            swiftSettings: warningsAsErrors
        ),
    ],
    swiftLanguageModes: [.v6]
)
