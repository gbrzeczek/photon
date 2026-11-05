import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small deterministic generator, so that a seed always gives the same library.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Real, decodable media built from noise. Nothing here comes from a person's photos.
public enum SyntheticMedia {
    public struct ImageOptions: Sendable {
        public var width = 64
        public var height = 48
        public var seed: UInt64 = 1
        /// `yyyy:MM:dd HH:mm:ss`, or nil for no date.
        public var captureDate: String?
        public var subseconds: String?
        public var utcOffset: String?
        public var orientation: Int?
        public init() {}
    }

    public static func jpeg(_ options: ImageOptions = ImageOptions()) -> Data? {
        encode(options, type: .jpeg)
    }

    public static func png(_ options: ImageOptions = ImageOptions()) -> Data? {
        encode(options, type: .png)
    }

    /// Nil where the machine has no HEIC encoder.
    public static func heic(_ options: ImageOptions = ImageOptions()) -> Data? {
        encode(options, type: .heic)
    }

    private static func encode(_ options: ImageOptions, type: UTType) -> Data? {
        guard let image = noiseImage(width: options.width, height: options.height, seed: options.seed) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if let orientation = options.orientation { properties[kCGImagePropertyOrientation] = orientation }
        var exif: [CFString: Any] = [:]
        if let captureDate = options.captureDate { exif[kCGImagePropertyExifDateTimeOriginal] = captureDate }
        if let subseconds = options.subseconds { exif[kCGImagePropertyExifSubsecTimeOriginal] = subseconds }
        if let utcOffset = options.utcOffset { exif[kCGImagePropertyExifOffsetTimeOriginal] = utcOffset }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func noiseImage(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var generator = SeededGenerator(seed: seed)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = generator.next()
            pixels[index] = UInt8(truncatingIfNeeded: value)
            pixels[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Adds a comment segment after the JPEG start marker, which makes a file unique without
    /// re-encoding it. A million encodes would take hours, and this takes no time at all.
    public static func uniquified(jpeg: Data, marker: UInt64) -> Data {
        var comment = Data([0xFF, 0xFE, 0x00, 0x0A])
        withUnsafeBytes(of: marker.littleEndian) { comment.append(contentsOf: $0) }
        var result = Data(capacity: jpeg.count + comment.count)
        result.append(jpeg.prefix(2))
        result.append(comment)
        result.append(jpeg.dropFirst(2))
        return result
    }

    // MARK: Video

    public struct MovieOptions: Sendable {
        public var width: UInt32 = 1920
        public var height: UInt32 = 1080
        public var timescale: UInt32 = 600
        public var durationUnits: UInt64 = 6_000
        /// Seconds since 1904, the QuickTime epoch.
        public var created: UInt64 = 3_600_000_000
        /// A clockwise rotation of 0, 90, 180 or 270.
        public var rotation = 0
        public var moovAtEnd = false
        public var mediaBytes = 4096
        public var seed: UInt64 = 1
        /// Uses 64-bit `mvhd` and `tkhd` fields, as long recordings do.
        public var largeHeaders = false
        public init() {}
    }

    /// The boxes a player reads for metadata, with noise as the media. It parses, but it doesn't play.
    public static func movie(_ options: MovieOptions = MovieOptions()) -> Data {
        let ftyp = box("ftyp", Data("isom".utf8) + uint32(512) + Data("isommp42".utf8))
        var generator = SeededGenerator(seed: options.seed)
        var media = Data(capacity: options.mediaBytes)
        while media.count < options.mediaBytes { media.append(contentsOf: uint64(generator.next())) }
        let mdat = box("mdat", media.prefix(options.mediaBytes))

        let handler = fullBox("hdlr", version: 0, uint32(0) + Data("vide".utf8) + Data(count: 12) + Data([0]))
        let track = box("trak", trackHeader(options) + box("mdia", handler))
        let moov = box("moov", movieHeader(options) + track)
        return options.moovAtEnd ? ftyp + mdat + moov : ftyp + moov + mdat
    }

    private static func movieHeader(_ options: MovieOptions) -> Data {
        var body = Data()
        if options.largeHeaders {
            body += uint64(options.created) + uint64(options.created) + uint32(options.timescale)
            body += uint64(options.durationUnits)
        } else {
            body += uint32(UInt32(options.created)) + uint32(UInt32(options.created)) + uint32(options.timescale)
            body += uint32(UInt32(options.durationUnits))
        }
        body += Data(count: 80)
        return fullBox("mvhd", version: options.largeHeaders ? 1 : 0, body)
    }

    private static func trackHeader(_ options: MovieOptions) -> Data {
        var body = Data()
        if options.largeHeaders {
            body += uint64(options.created) + uint64(options.created) + uint32(1) + uint32(0)
            body += uint64(options.durationUnits)
        } else {
            body += uint32(UInt32(options.created)) + uint32(UInt32(options.created)) + uint32(1) + uint32(0)
            body += uint32(UInt32(options.durationUnits))
        }
        body += Data(count: 8 + 8)
        let one: Int32 = 0x10000
        let matrix: (Int32, Int32, Int32, Int32)
        switch options.rotation {
        case 90: matrix = (0, one, -one, 0)
        case 180: matrix = (-one, 0, 0, -one)
        case 270: matrix = (0, -one, one, 0)
        default: matrix = (one, 0, 0, one)
        }
        body += int32(matrix.0) + int32(matrix.1) + uint32(0)
        body += int32(matrix.2) + int32(matrix.3) + uint32(0)
        body += uint32(0) + uint32(0) + uint32(0x4000_0000)
        body += uint32(options.width << 16) + uint32(options.height << 16)
        return fullBox("tkhd", version: options.largeHeaders ? 1 : 0, body)
    }

    private static func box(_ type: String, _ body: Data) -> Data {
        uint32(UInt32(body.count + 8)) + Data(type.utf8) + body
    }

    private static func fullBox(_ type: String, version: UInt8, _ body: Data) -> Data {
        box(type, Data([version, 0, 0, 0]) + body)
    }

    private static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func int32(_ value: Int32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
