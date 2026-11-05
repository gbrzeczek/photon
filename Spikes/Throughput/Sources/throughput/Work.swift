import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reads = 0
    private(set) var bytes: Int64 = 0
    private(set) var failures = 0
    private(set) var sizes: [Int] = []
    func note(size: Int) { lock.withLock { sizes.append(size) } }
    func add(reads r: Int, bytes b: Int64) { lock.withLock { reads += r; bytes += b } }
    func fail() { lock.withLock { failures += 1 } }
    private(set) var failedTypes: [String: Int] = [:]
    func fail(type: String) { lock.withLock { failures += 1; failedTypes[type, default: 0] += 1 } }
}

/// Ordinary uncached reads, never mapped, as AGENTS.md requires on removable media.
struct Reader {
    let fd: Int32
    let size: Int64
    let counters: Counters

    init?(_ path: String, counters: Counters) {
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); return nil }
        size = st.st_size
        self.counters = counters
    }

    func read(offset: Int64, length: Int) -> Data? {
        var data = Data(count: length)
        let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset)) }
        guard got >= 0 else { return nil }
        counters.add(reads: 1, bytes: Int64(got))
        data.count = got
        return data
    }

    func finish() { close(fd) }
}

let chunk = 64 * 1024

/// The identity hash from docs/PLAN.md: file size plus head, middle and tail chunks.
func sampledHash(_ reader: Reader) -> Bool {
    var hash = SHA256()
    withUnsafeBytes(of: reader.size) { hash.update(bufferPointer: $0) }
    let offsets: [Int64] = reader.size <= Int64(chunk * 3)
        ? [0]
        : [0, reader.size / 2 - Int64(chunk) / 2, reader.size - Int64(chunk)]
    let length = reader.size <= Int64(chunk * 3) ? Int(reader.size) : chunk
    for offset in offsets {
        guard let data = reader.read(offset: offset, length: length) else { return false }
        hash.update(data: data)
    }
    _ = hash.finalize()
    return true
}

/// EXIF sits near the start of a JPEG, so a prefix read is the cheap path for metadata.
func metadata(_ reader: Reader, prefix: Int) -> Bool {
    guard let data = reader.read(offset: 0, length: min(prefix, Int(reader.size))) else { return false }
    let source = CGImageSourceCreateIncremental(nil)
    CGImageSourceUpdateData(source, data as CFData, data.count >= Int(reader.size))
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
}

/// Thumbnail from whatever preview is embedded, reading only a prefix of the file.
func embeddedThumbnail(_ reader: Reader, prefix: Int, maxPixels: Int) -> Bool {
    guard let data = reader.read(offset: 0, length: min(prefix, Int(reader.size))) else { return false }
    let source = CGImageSourceCreateIncremental(nil)
    CGImageSourceUpdateData(source, data as CFData, data.count >= Int(reader.size))
    let options: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
    reader.counters.note(size: max(image.width, image.height))
    return true
}

/// The slow path: read everything, then scale the full image down.
func fullThumbnail(_ reader: Reader, maxPixels: Int) -> Bool {
    guard reader.size < 400 << 20, let data = reader.read(offset: 0, length: Int(reader.size)),
        let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return false }
    let options: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
}
