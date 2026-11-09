import CoreGraphics
import Foundation
import ImageIO
import PhotonCore
import PhotonIndex
import UniformTypeIdentifiers

/// The two stored sizes, as long-edge pixels. Tiles run from 64 to 400 pt, so at 2x `small` covers
/// everything up to the default 160 pt tile, and `large` covers the largest tile exactly.
public enum ThumbnailSizes {
    public static let small = 320
    public static let large = 800
    /// JPEG quality. Thumbnails are viewed small, and every 1% of size adds up over a whole library.
    static let quality = 0.75
    /// Bytes read when looking for an embedded preview.
    static let previewPrefix = 512 * 1024
    /// Above this, a file isn't read in full just for a thumbnail.
    static let fullReadLimit: Int64 = 512 << 20
}

public struct EncodedThumbnail: Sendable {
    public var tier: ThumbnailTier
    public var data: Data
    public var width: Int
    public var height: Int

    public init(tier: ThumbnailTier, data: Data, width: Int, height: Int) {
        self.tier = tier
        self.data = data
        self.width = width
        self.height = height
    }
}

public struct ThumbnailSet: Sendable {
    public var thumbnails: [EncodedThumbnail]
    /// 0xRRGGBB.
    public var dominantColor: UInt32?
}

/// Makes thumbnails from a file's bytes. Everything comes through the `ByteSource`, and so through the
/// volume's I/O scheduler. A URL never reaches `CGImageSource`, because it could memory-map the file.
public enum Thumbnailer {
    /// ImageIO can't read these from part of a file (Spike 4), so there's no cheap preview for them.
    private static let fullReadFormats: Set<String> = ["heic", "heif", "hif", "avif"]

    /// Whether `embeddedPreview` has a chance, without reading anything.
    public static func mayHaveEmbeddedPreview(fileExtension: String) -> Bool {
        !fullReadFormats.contains(fileExtension.lowercased())
    }

    /// The preview a camera stored in the file, from a prefix of it. They're usually 160 px, too small
    /// to keep, but about 12 times faster to get than a full decode (Spike 4), so they fill tiles first.
    public static func embeddedPreview(from source: any ByteSource) throws -> ThumbnailSet? {
        let data = try source.read(offset: 0, length: ThumbnailSizes.previewPrefix)
        guard !data.isEmpty else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let imageSource = CGImageSourceCreateIncremental(options)
        CGImageSourceUpdateData(imageSource, data as CFData, Int64(data.count) >= source.size)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ThumbnailSizes.small,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary),
            let encoded = encode(image, tier: .preview)
        else { return nil }
        return ThumbnailSet(thumbnails: [encoded], dominantColor: dominantColor(of: image))
    }

    /// Both stored sizes from the whole file. Returns nil for a file that can't be decoded.
    /// Throws only what `source` throws, so that a removed drive is never mistaken for a bad file.
    public static func fullThumbnails(from source: any ByteSource) throws -> ThumbnailSet? {
        guard source.size <= ThumbnailSizes.fullReadLimit else { return nil }
        let data = try source.read(offset: 0, length: Int(source.size))
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ThumbnailSizes.large,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary)
        else { return nil }
        return thumbnails(from: image)
    }

    /// Both stored sizes from a decoded picture, such as a video's frame. `image` should already be
    /// at most `ThumbnailSizes.large` on its long edge.
    public static func thumbnails(from image: CGImage) -> ThumbnailSet? {
        var thumbnails: [EncodedThumbnail] = []
        let longEdge = max(image.width, image.height)
        var small = image
        if longEdge > ThumbnailSizes.small {
            guard let scaled = scale(image, toLongEdge: ThumbnailSizes.small) else { return nil }
            small = scaled
            // A file only just larger than `small` gains nothing from a second copy.
            if longEdge > ThumbnailSizes.small * 5 / 4, let large = encode(image, tier: .large) {
                thumbnails.append(large)
            }
        }
        guard let encoded = encode(small, tier: .small) else { return nil }
        thumbnails.append(encoded)
        return ThumbnailSet(thumbnails: thumbnails, dominantColor: dominantColor(of: small))
    }

    private static func encode(_ image: CGImage, tier: ThumbnailTier) -> EncodedThumbnail? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: ThumbnailSizes.quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return EncodedThumbnail(tier: tier, data: output as Data, width: image.width, height: image.height)
    }

    private static func scale(_ image: CGImage, toLongEdge longEdge: Int) -> CGImage? {
        let factor = Double(longEdge) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        let space = image.colorSpace?.supportsOutput == true ? image.colorSpace : nil
        guard let context = makeContext(width: width, height: height, space: space) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func makeContext(width: Int, height: Int, space: CGColorSpace?) -> CGContext? {
        guard let space = space ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The average color, as sRGB.
    static func dominantColor(of image: CGImage) -> UInt32? {
        let side = 8
        guard let context = makeContext(width: side, height: side, space: nil), let bytes = context.data else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = bytes.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * side)
        var red = 0, green = 0, blue = 0
        for row in 0..<side {
            for column in 0..<side {
                let pixel = pixels + row * context.bytesPerRow + column * 4
                red += Int(pixel[0])
                green += Int(pixel[1])
                blue += Int(pixel[2])
            }
        }
        let count = side * side
        return UInt32(red / count) << 16 | UInt32(green / count) << 8 | UInt32(blue / count)
    }
}
