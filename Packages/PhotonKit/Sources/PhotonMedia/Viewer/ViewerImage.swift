import CoreGraphics
import Foundation
import IOSurface
import ImageIO

/// A photo decoded for the viewer, ready to assign to `CALayer.contents` on the main thread. Like
/// thumbnails these are IOSurfaces, and at this size assigning a `CGImage` would cost far more.
public final class ViewerImage: @unchecked Sendable {
    public let surface: IOSurface
    public let width: Int
    public let height: Int
    /// The original's own pixels, not a smaller copy of them.
    public let isFullResolution: Bool
    /// The original's long edge, which is what actual size means whatever this image's own size.
    public let originalLongEdge: Int
    /// How far past SDR white the pixels go. 1 means an SDR photo.
    public let headroom: CGFloat

    init(surface: IOSurface, width: Int, height: Int, originalLongEdge: Int, headroom: CGFloat) {
        self.surface = surface
        self.width = width
        self.height = height
        self.originalLongEdge = originalLongEdge
        self.isFullResolution = max(width, height) >= originalLongEdge
        self.headroom = headroom
    }

    public var isHDR: Bool { headroom > 1 }
    public var longEdge: Int { max(width, height) }
    var byteCount: Int { surface.allocationSize }
}

/// Decodes a photo from bytes already in memory, so that nothing here can touch a file. Decoding happens
/// here and in full, off the main thread, which only assigns the result.
public enum PhotoDecoder {
    /// The largest texture Apple silicon takes. A panorama past this is shown smaller, which is better
    /// than not at all.
    public static let maximumEdge = 16384
    /// 480 MB at 8 bits. A larger original is decoded smaller, so one photo can't use the memory budget.
    public static let maximumPixels = 120_000_000
    /// For a PQ or HLG photo that doesn't say how bright it gets. The value of
    /// `kCGDefaultHDRImageContentHeadroom`, which Swift 6 won't read because it's a global `var`.
    private static let defaultHeadroom: CGFloat = 4.93

    /// - Parameter maximumEdge: The long edge wanted, or nil for the original's size.
    /// - Returns: Nil for bytes that can't be decoded.
    public static func decode(_ data: Data, maximumEdge wanted: Int?) -> ViewerImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            let longEdge = longEdge(of: source)
        else { return nil }
        let edge = min(wanted ?? longEdge, limit(forLongEdge: longEdge, source: source))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        if let headroom = headroom(of: image) {
            guard let surface = hdrSurface(of: image, headroom: headroom) else { return nil }
            return ViewerImage(
                surface: surface, width: image.width, height: image.height, originalLongEdge: longEdge,
                headroom: headroom)
        }
        guard let surface = SurfaceDrawing.displayP3Surface(of: image) else { return nil }
        return ViewerImage(
            surface: surface, width: image.width, height: image.height, originalLongEdge: longEdge, headroom: 1)
    }

    static func longEdge(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(width, height)
    }

    private static func limit(forLongEdge longEdge: Int, source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return min(longEdge, maximumEdge) }
        return edgeLimit(width: width, height: height)
    }

    /// The longest edge this photo may decode to, under both limits.
    static func edgeLimit(width: Int, height: Int) -> Int {
        let longEdge = max(width, height)
        guard width > 0, height > 0 else { return min(longEdge, maximumEdge) }
        let scale = min(1, (Double(maximumPixels) / (Double(width) * Double(height))).squareRoot())
        return min(maximumEdge, Int((Double(longEdge) * scale).rounded(.down)))
    }

    /// The headroom of an HDR image, or nil for an SDR one. Decoding a gain map gives a PQ image tagged
    /// with its headroom. A PQ or HLG file may carry no tag at all.
    private static func headroom(of image: CGImage) -> CGFloat? {
        let usesHDRCurve = image.colorSpace.map(CGColorSpaceUsesITUR_2100TF) ?? false
        let tagged = CGFloat(image.contentHeadroom)
        if tagged > 1 { return tagged }
        return usesHDRCurve ? defaultHeadroom : nil
    }

    /// Half-float pixels in extended linear P3, where values past 1 survive. Tagged with the headroom,
    /// which is what lets Core Animation show them past SDR white.
    private static func hdrSurface(of image: CGImage, headroom: CGFloat) -> IOSurface? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
            let surface = IOSurface(properties: [
                .width: image.width, .height: image.height, .bytesPerElement: 8,
                .pixelFormat: 0x5247_6841 as UInt32,  // 'RGhA'
            ])
        else { return nil }
        surface.setAttachment(CGColorSpace.extendedLinearDisplayP3 as String, forKey: "IOSurfaceColorSpace")
        surface.setAttachment(NSNumber(value: Double(headroom)), forKey: kIOSurfaceContentHeadroom as String)
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let bitmapInfo =
            CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: surface.baseAddress, width: image.width, height: image.height, bitsPerComponent: 16,
                bytesPerRow: surface.bytesPerRow, space: space, bitmapInfo: bitmapInfo)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return surface
    }
}

enum SurfaceDrawing {
    /// 8-bit pixels in Display P3, so that wide-gamut photos keep their color on a P3 screen.
    static func displayP3Surface(of image: CGImage) -> IOSurface? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
            let surface = IOSurface(properties: [
                .width: image.width, .height: image.height, .bytesPerElement: 4,
                .pixelFormat: 0x4247_5241 as UInt32,  // 'BGRA'
            ])
        else { return nil }
        surface.setAttachment(CGColorSpace.displayP3 as String, forKey: "IOSurfaceColorSpace")
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let context = CGContext(
                data: surface.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: space, bitmapInfo: bitmapInfo)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return surface
    }
}
