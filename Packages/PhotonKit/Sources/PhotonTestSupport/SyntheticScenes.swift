import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Drawn landscapes for screenshots: a sky, a sun or moon, and layers of hills, in colors from a seeded
/// palette. They stand in for real photos, which must never be committed or shown, and they look enough
/// like photos that a screenshot reads as a photo browser.
public enum SyntheticScenes {
    public struct Manifest: Sendable {
        public var photos = 0
    }

    private struct Palette {
        let skyTop: (CGFloat, CGFloat, CGFloat)
        let skyBottom: (CGFloat, CGFloat, CGFloat)
        let sun: (CGFloat, CGFloat, CGFloat)
        let land: (CGFloat, CGFloat, CGFloat)
    }

    /// Dawn, noon, dusk, night and a few seasons, so a grid has variety without looking random.
    private static let palettes: [Palette] = [
        Palette(skyTop: (0.16, 0.36, 0.72), skyBottom: (0.72, 0.86, 0.98), sun: (1.0, 0.97, 0.86), land: (0.20, 0.45, 0.28)),
        Palette(skyTop: (0.98, 0.55, 0.35), skyBottom: (1.0, 0.86, 0.60), sun: (1.0, 0.95, 0.80), land: (0.35, 0.20, 0.30)),
        Palette(skyTop: (0.10, 0.12, 0.30), skyBottom: (0.45, 0.30, 0.55), sun: (0.95, 0.93, 0.85), land: (0.08, 0.10, 0.18)),
        Palette(skyTop: (0.55, 0.75, 0.90), skyBottom: (0.92, 0.95, 0.98), sun: (1.0, 1.0, 0.95), land: (0.82, 0.86, 0.92)),
        Palette(skyTop: (0.95, 0.45, 0.45), skyBottom: (0.99, 0.78, 0.55), sun: (1.0, 0.92, 0.70), land: (0.55, 0.30, 0.18)),
        Palette(skyTop: (0.30, 0.60, 0.75), skyBottom: (0.80, 0.92, 0.90), sun: (1.0, 0.98, 0.90), land: (0.10, 0.40, 0.45)),
        Palette(skyTop: (0.40, 0.50, 0.70), skyBottom: (0.95, 0.80, 0.70), sun: (1.0, 0.90, 0.75), land: (0.42, 0.50, 0.22)),
        Palette(skyTop: (0.05, 0.08, 0.15), skyBottom: (0.15, 0.25, 0.40), sun: (0.90, 0.92, 1.0), land: (0.03, 0.05, 0.08)),
    ]

    /// Writes `count` photos into `root`, in folders by year, with capture dates a few days apart, and
    /// some portraits. Only on the internal disk or a disk image, as every generator here.
    public static func generate(at root: URL, count: Int = 120, seed: UInt64 = 7) throws -> Manifest {
        try SyntheticLibrary.ensureSafeLocation(root)
        var generator = SeededGenerator(seed: seed)
        var manifest = Manifest()
        let start = Date(timeIntervalSince1970: 1_640_995_200)  // 2022-01-01
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        for index in 0..<count {
            let date = start.addingTimeInterval(Double(index) * 6.5 * 86_400 + Double(generator.next() % 36_000))
            let year = Calendar(identifier: .gregorian).component(.year, from: date)
            let folder = root.appending(path: String(year), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let portrait = generator.next() % 4 == 0
            let (width, height) = portrait ? (1200, 1600) : (generator.next() % 3 == 0 ? (1800, 1200) : (1600, 1200))
            guard
                let data = scene(
                    width: width, height: height, seed: generator.next(), captureDate: formatter.string(from: date))
            else { continue }
            try data.write(to: folder.appending(path: String(format: "IMG_%04d.JPG", 1000 + index * 7)))
            manifest.photos += 1
        }
        return manifest
    }

    /// One drawn landscape as a JPEG.
    public static func scene(width: Int, height: Int, seed: UInt64, captureDate: String? = nil) -> Data? {
        var generator = SeededGenerator(seed: seed)
        func unit() -> CGFloat { CGFloat(generator.next() % 10_000) / 10_000 }
        let palette = palettes[Int(generator.next() % UInt64(palettes.count))]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        func color(_ c: (CGFloat, CGFloat, CGFloat), _ shade: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: min(1, c.0 * shade), green: min(1, c.1 * shade), blue: min(1, c.2 * shade), alpha: 1)
        }

        let sky = CGGradient(
            colorsSpace: space, colors: [color(palette.skyTop), color(palette.skyBottom)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.3), options: [.drawsAfterEndLocation])

        // The sun, with a soft glow.
        let sun = CGPoint(x: w * (0.15 + unit() * 0.7), y: h * (0.55 + unit() * 0.3))
        let radius = min(w, h) * (0.05 + unit() * 0.05)
        let glow = CGGradient(
            colorsSpace: space,
            colors: [color(palette.sun), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
            locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: sun, startRadius: radius, endCenter: sun, endRadius: radius * 4, options: [])
        context.setFillColor(color(palette.sun))
        context.fillEllipse(in: CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2))

        // Hills, far to near, each darker and lower than the last.
        let layers = 3 + Int(generator.next() % 3)
        for layer in 0..<layers {
            let depth = CGFloat(layer) / CGFloat(layers)
            let base = h * (0.55 - depth * 0.4)
            let amplitude = h * (0.05 + unit() * 0.08)
            let frequency = 1.5 + unit() * 3
            let phase = unit() * .pi * 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            for step in 0...64 {
                let x = w * CGFloat(step) / 64
                let t = CGFloat(step) / 64 * frequency * .pi
                let y = base + amplitude * (sin(t + phase) + 0.4 * sin(t * 2.3 + phase * 1.7))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: w, y: 0))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color(palette.land, 1.6 - depth * 0.9))
            context.fillPath()
        }

        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        if let captureDate { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: captureDate] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
