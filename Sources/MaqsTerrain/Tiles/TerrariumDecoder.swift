import CoreGraphics
import Foundation
import ImageIO

/// Turns a terrarium image (WebP or PNG) into an `ElevationTile` through ImageIO.
enum TerrariumDecoder {
    /// Decodes tile bytes; `expectedSize` rejects a tile whose side differs, nil accepts any square size.
    static func decode(_ data: Data, expectedSize: Int?) throws(TerrainError) -> ElevationTile {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == image.height, image.width > 0,
            expectedSize == nil || expectedSize == image.width,
            let rgba = providerBytes(of: image) ?? redrawnBytes(of: image)
        else {
            throw .undecodableTile
        }
        let size = image.width
        var elevations = [Float](repeating: 0, count: size * size)
        for index in 0..<size * size {
            let offset = index * 4
            elevations[index] = Float(Terrarium.elevation(red: rgba[offset], green: rgba[offset + 1], blue: rgba[offset + 2]))
        }
        return try ElevationTile(size: size, elevations: elevations)
    }

    /// The provider's own bytes, repacked to four per pixel, when the layout is plain 8-bit RGB(A).
    /// The layout differs between platforms, so it is checked, not assumed.
    private static func providerBytes(of image: CGImage) -> [UInt8]? {
        let bitsPerPixel = image.bitsPerPixel
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let alphaIsPlain: Bool
        switch image.alphaInfo {
        case .none: alphaIsPlain = true
        case .noneSkipLast, .last, .premultipliedLast: alphaIsPlain = bitsPerPixel == 32
        default: alphaIsPlain = false
        }
        guard image.bitsPerComponent == 8, bitsPerPixel == 24 || bitsPerPixel == 32,
            image.colorSpace?.model == .rgb,
            !image.bitmapInfo.contains(.floatComponents),
            byteOrder == [] || byteOrder == .byteOrder32Big,
            alphaIsPlain,
            let data = image.dataProvider?.data
        else { return nil }
        let bytesPerPixel = bitsPerPixel / 8
        let rowBytes = image.bytesPerRow
        let size = image.width
        guard image.height == size, rowBytes >= size * bytesPerPixel,
            CFDataGetLength(data) >= rowBytes * (size - 1) + size * bytesPerPixel,
            let base = CFDataGetBytePtr(data)
        else { return nil }
        var output = [UInt8](repeating: 255, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let source = row * rowBytes + column * bytesPerPixel
                let target = (row * size + column) * 4
                output[target] = base[source]
                output[target + 1] = base[source + 1]
                output[target + 2] = base[source + 2]
            }
        }
        return output
    }

    /// Draws into an RGBA8 context in the image's own colour space, so no colour conversion alters the encoded values.
    private static func redrawnBytes(of image: CGImage) -> [UInt8]? {
        guard let space = image.colorSpace, space.model == .rgb else { return nil }
        let size = image.width
        var output = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = output.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return drawn ? output : nil
    }
}
