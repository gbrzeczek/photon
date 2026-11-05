import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes camera-shaped JPEGs: about 17 MP after cropping, around 7 MB each, with an embedded thumbnail and EXIF date,
/// in folders of 200. Run it only against a scratch disk image.
func generate(root: String, count: Int) throws {
    let width = 6000, height = 4000
    let noise = makeNoise(width: width, height: height)
    let lock = NSLock()
    nonisolated(unsafe) var failed = 0
    DispatchQueue.concurrentPerform(iterations: count) { i in
        let folder = "\(root)/DCIM/\(100 + i / 200)PHOTO"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: "\(folder)/IMG_\(String(format: "%05d", i)).JPG") as CFURL
        // A per-file crop of the noise keeps files distinct without regenerating it.
        let crop = noise.cropping(to: CGRect(x: i % 997, y: i % 613, width: width - 1000, height: height - 700))!
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier as CFString, 1, nil) else {
            lock.withLock { failed += 1 }
            return
        }
        let quality = 0.55 + Double(i % 5) * 0.05
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:06:\(String(format: "%02d", 1 + i % 28)) 12:00:00"]
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationEmbedThumbnail: true,
            kCGImagePropertyExifDictionary: exif,
        ]
        CGImageDestinationAddImage(dest, crop, options as CFDictionary)
        if !CGImageDestinationFinalize(dest) { lock.withLock { failed += 1 } }
    }
    print("generated \(count) files, \(failed) failed")
}

private func makeNoise(width: Int, height: Int) -> CGImage {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    // Low-frequency colour with fine grain, so JPEG sizes resemble real photos, not pure noise.
    for y in 0..<height {
        for x in 0..<width {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let grain = Int(state & 0x3F) - 32
            let i = (y * width + x) * 4
            pixels[i] = UInt8(clamping: 128 + (x / 40 % 80) + grain)
            pixels[i + 1] = UInt8(clamping: 90 + (y / 30 % 90) + grain)
            pixels[i + 2] = UInt8(clamping: 60 + ((x + y) / 50 % 100) + grain)
            pixels[i + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
