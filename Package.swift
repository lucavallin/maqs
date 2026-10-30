// swift-tools-version: 6.2
import PackageDescription

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
            resources: [.copy("Resources/sources.json")]
        ),
        .target(
            name: "MaqsData"
        ),
        .target(
            name: "MaqsPMTiles"
        ),
        .target(
            name: "MaqsTerrain",
            dependencies: ["MaqsPMTiles"]
        ),
        .target(
            name: "MaqsUI",
            dependencies: [
                "MaqsCore", "MaqsPMTiles",
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution", condition: .when(platforms: [.iOS])),
            ],
            resources: [.copy("MapAssets")]
        ),
        .target(
            name: "MaqsTestSupport",
            dependencies: ["MaqsPMTiles"],
            path: "Tests/MaqsTestSupport",
            sources: ["Sources"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MaqsCoreTests",
            dependencies: ["MaqsCore", "MaqsTestSupport"]
        ),
        .testTarget(
            name: "MaqsDataTests",
            dependencies: ["MaqsData", "MaqsTestSupport"]
        ),
        .testTarget(
            name: "MaqsPMTilesTests",
            dependencies: ["MaqsPMTiles", "MaqsTestSupport"]
        ),
        .testTarget(
            name: "MaqsTerrainTests",
            dependencies: ["MaqsTerrain", "MaqsTestSupport"]
        ),
        .testTarget(
            name: "MaqsUITests",
            dependencies: ["MaqsUI", "MaqsCore", "MaqsData", "MaqsTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
