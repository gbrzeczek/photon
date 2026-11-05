import AppKit
import CoreGraphics
import ImageIO
import IOSurface
import UniformTypeIdentifiers

/// How decoded pixels reach CALayer.contents. Part of the experiment: main-thread commit cost differs.
enum ThumbFormat: String, Sendable { case device, srgb, surface }

/// Off-main JPEG decoding with cancellation. Newest requests run first, as a scrolling grid wants.
/// Results queue up and the main thread drains a bounded batch per frame.
final class ThumbDecoder: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [Int] = []
    private var wanted = Set<Int>()
    private var done: [(Int, AnyObject)] = []
    private let jpegs: [Data]
    private let format: ThumbFormat

    init(workers: Int, format: ThumbFormat) {
        self.format = format
        jpegs = (0..<48).map(Self.makeJPEG)
        for _ in 0..<workers {
            let thread = Thread { [unowned self] in self.work() }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func request(_ index: Int) {
        condition.lock()
        if wanted.insert(index).inserted {
            stack.append(index)
            condition.signal()
        }
        condition.unlock()
    }

    func cancel(_ index: Int) {
        condition.lock()
        wanted.remove(index)
        condition.unlock()
    }

    func drain(limit: Int) -> [(Int, AnyObject)] {
        condition.lock()
        defer { condition.unlock() }
        let batch = Array(done.prefix(limit))
        done.removeFirst(batch.count)
        return batch
    }

    private func work() {
        while true {
            condition.lock()
            while stack.isEmpty { condition.wait() }
            let index = stack.removeLast()
            let live = wanted.contains(index)
            condition.unlock()
            guard live else { continue }
            let image = autoreleasepool { Self.decode(jpegs[index % jpegs.count], format: format) }
            condition.lock()
            if wanted.remove(index) != nil, let image { done.append((index, image)) }
            condition.unlock()
        }
    }

    /// Forces full decoding here, so the main thread only ever assigns finished pixels.
    private static func decode(_ data: Data, format: ThumbFormat) -> AnyObject? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        switch format {
        case .device, .srgb:
            let space = format == .srgb ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
            context.draw(image, in: rect)
            return context.makeImage()
        case .surface:
            let surface = IOSurface(properties: [
                .width: image.width, .height: image.height, .bytesPerElement: 4,
                .pixelFormat: 0x4247_5241 as UInt32,  // 'BGRA'
            ])
            guard let surface else { return nil }
            surface.lock(options: [], seed: nil)
            defer { surface.unlock(options: [], seed: nil) }
            guard let context = CGContext(data: surface.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
            context.draw(image, in: rect)
            return surface
        }
    }

    private static func makeJPEG(_ seed: Int) -> Data {
        let size = 256
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            context.setFillColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: .random(in: 0...1, using: &rng), alpha: 0.7)
            context.fillEllipse(in: CGRect(x: .random(in: -60...256, using: &rng), y: .random(in: -60...256, using: &rng), width: .random(in: 20...160, using: &rng), height: .random(in: 20...160, using: &rng)))
        }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
