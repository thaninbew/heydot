import AppKit

/// Owner-selected round 3, "8. Open cradle". Original designer PNGs preserve the SVG's
/// filters and lighting exactly. 16/32 use the separately hinted small-size SVG renders;
/// intermediate iconset sizes downsample the lossless 1024 master with AppKit.
@MainActor
enum LogoAsset {
    static let master = Data(PackageResources.Logo8_1024_png)
    static let image = NSImage(data: master)!

    static func png(pixels: Int) throws -> Data {
        switch pixels {
        case 16: return Data(PackageResources.Logo8_16_png)
        case 32: return Data(PackageResources.Logo8_32_png)
        case 1024: return master
        default:
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }
}
