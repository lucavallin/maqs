import CoreGraphics
import Foundation
import ImageIO
import MaqsPMTiles
import MaqsTestSupport
import Testing
import UniformTypeIdentifiers
@testable import MaqsTerrain

@Suite struct TerrariumDecoderTests {
    @Test func theFixtureTileDecodesLikePillow() throws {
        let archive = try PMTilesArchive(url: Fixtures.url("test/test-terrain.v1.pmtiles"))
        let data = try #require(try archive.tile(z: 12, x: 2187, y: 1455))
        let tile = try TerrariumDecoder.decode(data, expectedSize: 512)
        #expect(tile.size == 512)
        let expected: [(Int, Int, Double)] = [(0, 0, 334.0), (100, 200, 438.5), (255, 255, 907.0), (511, 511, 1468.75), (300, 17, 584.0)]
        for (x, y, metres) in expected {
            #expect(tile.elevation(pixelX: Double(x) + 0.5, pixelY: Double(y) + 0.5) == metres)
        }
    }

    /// RGB for pixel (x, y) of the test images.
    private func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        (UInt8(120 + x), UInt8(10 + y * 40 + x), UInt8(255 - x * 50 - y))
    }

    private func png(width: Int = 4, height: Int = 4, bitsPerComponent: Int) throws -> Data {
        let bytesPerComponent = bitsPerComponent / 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4 * bytesPerComponent)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = rgb(x, y)
                let base = (y * width + x) * 4 * bytesPerComponent
                for (channel, value) in [r, g, b, 255].enumerated() {
                    for part in 0..<bytesPerComponent { pixels[base + channel * bytesPerComponent + part] = value }
                }
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let info = bitsPerComponent == 16
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let image = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: bitsPerComponent,
                bytesPerRow: width * 4 * bytesPerComponent, space: space, bitmapInfo: info))
            return try #require(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func expectValues(_ tile: ElevationTile) {
        for y in 0..<4 {
            for x in 0..<4 {
                let (r, g, b) = rgb(x, y)
                #expect(tile.elevation(pixelX: Double(x) + 0.5, pixelY: Double(y) + 0.5) == Terrarium.elevation(red: r, green: g, blue: b))
            }
        }
    }

    @Test func an8BitPNGDecodesThroughTheProviderBytes() throws {
        expectValues(try TerrariumDecoder.decode(try png(bitsPerComponent: 8), expectedSize: 4))
    }

    @Test func a16BitPNGDecodesThroughTheRedrawToTheSameValues() throws {
        expectValues(try TerrariumDecoder.decode(try png(bitsPerComponent: 16), expectedSize: nil))
    }

    @Test func aNonSquareImageIsUndecodable() throws {
        #expect(throws: TerrainError.undecodableTile) { try TerrariumDecoder.decode(try png(width: 4, height: 2, bitsPerComponent: 8), expectedSize: nil) }
    }

    @Test func aSizeOtherThanExpectedIsUndecodable() throws {
        #expect(throws: TerrainError.undecodableTile) { try TerrariumDecoder.decode(try png(bitsPerComponent: 8), expectedSize: 512) }
    }

    @Test func garbageIsUndecodable() {
        #expect(throws: TerrainError.undecodableTile) { try TerrariumDecoder.decode(Data("not an image".utf8), expectedSize: nil) }
        #expect(throws: TerrainError.undecodableTile) { try TerrariumDecoder.decode(Data(), expectedSize: nil) }
    }
}
