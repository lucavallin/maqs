import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import MaqsTestSupport
import Testing
import UniformTypeIdentifiers
@testable import MaqsTerrain

@Suite struct SamplingTests {
    private static let fixture = "test/test-terrain.v1.pmtiles"

    private func coordinate(_ point: Golden.Point) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    private func fixtureProvider() throws -> LocalTileProvider {
        try LocalTileProvider(url: Fixtures.url(Self.fixture))
    }

    /// A 512 px PNG of one terrarium colour: (135, 208, 0) is 2000 m.
    private func constantPNG() throws -> Data {
        let size = 512
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in 0..<size * size {
            pixels[index * 4] = 135
            pixels[index * 4 + 1] = 208
            pixels[index * 4 + 3] = 255
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try #require(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func samplesMatchThePipeline() async throws {
        let golden = try Golden.load()
        let terrain = Terrain(providers: [try fixtureProvider()], memoryCacheBytes: 64 << 20)
        let coordinates = golden.points.map(coordinate)
        let samples = try await terrain.samples(at: coordinates, zoomLimits: coordinates.map { _ in Int.max })
        #expect(samples.count == golden.points.count)
        for (point, sample) in zip(golden.points, samples) {
            switch (point.elevation, sample) {
            case (nil, .missing(.noData)): break
            case (let expected?, .elevation(let value)): #expect(abs(value - expected) < 1e-6)
            default: Issue.record("lon \(point.lon) lat \(point.lat): expected \(String(describing: point.elevation)), got \(sample)")
            }
        }
    }

    @Test func aPointOutsideEveryArchiveIsNoData() async throws {
        let terrain = Terrain(providers: [try fixtureProvider()], memoryCacheBytes: 64 << 20)
        let far = [CLLocationCoordinate2D(latitude: -33.9, longitude: 151.2)]
        let samples = try await terrain.samples(at: far, zoomLimits: [Int.max])
        #expect(samples == [.missing(.noData)])
    }

    @Test func aTerrainHDArchiveIsPreferredWhereItCovers() async throws {
        let golden = try Golden.load()
        let first = try #require(golden.points.first)
        let hdZoom = 13
        let hdKey = try #require(WebMercator.position(longitude: first.lon, latitude: first.lat, zoom: hdZoom, tileSize: 512)).key
        let directory = try TemporaryDirectory()
        let hdURL = directory.url.appending(path: "hd.pmtiles")
        try PMTilesWriter.write(tiles: [(z: hdKey.z, x: hdKey.x, y: hdKey.y, data: try constantPNG())], to: hdURL, tileType: 2)
        // Listed after the fixture on purpose: the highest zoom wins whatever the order given.
        let terrain = Terrain(providers: [try fixtureProvider(), try LocalTileProvider(url: hdURL)], memoryCacheBytes: 64 << 20)
        let coordinates = golden.points.map(coordinate)
        let samples = try await terrain.samples(at: coordinates, zoomLimits: coordinates.map { _ in Int.max })
        var inside = 0
        for (point, sample) in zip(golden.points, samples) {
            let position = try #require(WebMercator.position(longitude: point.lon, latitude: point.lat, zoom: hdZoom, tileSize: 512))
            if position.key == hdKey {
                inside += 1
                #expect(sample == .elevation(2000))
            } else if let expected = point.elevation, case .elevation(let value) = sample {
                #expect(abs(value - expected) < 1e-6)
            } else {
                Issue.record("lon \(point.lon) lat \(point.lat): unexpected \(sample)")
            }
        }
        #expect(inside >= 1)
        #expect(inside < golden.points.count)
    }

    @Test func noOnlineLoadForAPointALocalArchiveCovers() async throws {
        let golden = try Golden.load()
        let online = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, isOnline: true) { _, _ in 1 }
        let terrain = Terrain(providers: [online, try fixtureProvider()], memoryCacheBytes: 64 << 20)
        let coordinates = golden.points.map(coordinate)
        _ = try await terrain.samples(at: coordinates, zoomLimits: coordinates.map { _ in Int.max })
        #expect(online.loads.isEmpty)
    }

    @Test func onlineFillsWhatLocalLacks() async throws {
        let online = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, isOnline: true) { _, _ in 321 }
        let terrain = Terrain(providers: [try fixtureProvider(), online], memoryCacheBytes: 64 << 20)
        let golden = try Golden.load()
        let covered = try #require(golden.points.first)
        let away = CLLocationCoordinate2D(latitude: 46.5, longitude: 13.5)
        let samples = try await terrain.samples(at: [coordinate(covered), away], zoomLimits: [12, 12])
        #expect(samples[1] == .elevation(321))
        #expect(samples[0] != .elevation(321))
        #expect(online.loads.count == 1)
    }

    @Test func a256PixelProviderSamplesCorrectly() async throws {
        let provider = SyntheticTerrain(tileSize: 256, zoomRange: 0...14) { _, lat in lat * 1000 }
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let (lon, lat) = (12.0123, 46.0456)
        let zoom = 10
        let samples = try await terrain.samples(at: [CLLocationCoordinate2D(latitude: lat, longitude: lon)], zoomLimits: [zoom])
        let position = try #require(WebMercator.position(longitude: lon, latitude: lat, zoom: zoom, tileSize: 256))
        let x = position.pixelX - 0.5
        let y = position.pixelY - 0.5
        let (x0, y0) = (Int(x), Int(y))
        #expect((0..<255).contains(x0) && (0..<255).contains(y0))
        func centre(_ column: Int, _ row: Int) -> Double {
            let place = SyntheticTerrain.lonLat(key: position.key, pixelX: column, pixelY: row, tileSize: 256)
            return Double(Float(place.lat * 1000))
        }
        let (fx, fy) = (x - Double(x0), y - Double(y0))
        let top = centre(x0, y0) * (1 - fx) + centre(x0 + 1, y0) * fx
        let bottom = centre(x0, y0 + 1) * (1 - fx) + centre(x0 + 1, y0 + 1) * fx
        let expected = top * (1 - fy) + bottom * fy
        guard case .elevation(let value) = samples[0] else {
            Issue.record("expected an elevation, got \(samples[0])")
            return
        }
        #expect(abs(value - expected) < 1e-6)
    }

    @Test func aCancelledCallThrowsCancellationError() async throws {
        let provider = SyntheticTerrain(tileSize: 256, zoomRange: 0...12) { _, _ in 5 }
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let point = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.2)
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await terrain.samples(at: [point], zoomLimits: [12])
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(provider.loads.isEmpty)
    }

    @Test func theOnlineBudgetStopsAt128() async throws {
        let online = SyntheticTerrain(tileSize: 256, zoomRange: 0...12, isOnline: true) { _, _ in 5 }
        let terrain = Terrain(providers: [online], memoryCacheBytes: 64 << 20)
        let coordinates = (0..<129).map { index -> CLLocationCoordinate2D in
            let place = SyntheticTerrain.lonLat(key: TileKey(z: 12, x: 2000 + index, y: 1400), pixelX: 128, pixelY: 128, tileSize: 256)
            return CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
        }
        let samples = try await terrain.samples(at: coordinates, zoomLimits: coordinates.map { _ in 12 })
        #expect(online.loads.count == 128)
        #expect(samples.filter { $0 == .missing(.requestCap) }.count == 1)
        #expect(samples.filter { $0 == .elevation(5) }.count == 128)
    }
}
