import Foundation
import PhotonCore
import PhotonIndex

/// Reads QuickTime and MP4 metadata by walking the file's boxes.
///
/// AVFoundation isn't used here because it opens files itself, which would bypass the I/O scheduler
/// and its cancellation. This needs only the box headers and the `moov` box, however long the video is.
/// Other containers get their metadata from FFmpeg's libraries in Milestone 6.
enum VideoMetadataReader {
    private static let supportedFormats: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2"]
    private static let maxTopLevelBoxes = 4096
    private static let maxMovieBoxLength: Int64 = 128 << 20
    /// Seconds from the QuickTime epoch of 1904 to 1970.
    private static let epochOffset: Int64 = 2_082_844_800

    static func read(fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
        guard supportedFormats.contains(fileExtension) else { return nil }
        guard let movie = try findMovieBox(in: source) else { return nil }
        return parseMovie(BoxReader(movie))
    }

    private static func findMovieBox(in source: any ByteSource) throws -> Data? {
        var offset: Int64 = 0
        for _ in 0..<maxTopLevelBoxes {
            guard offset + 8 <= source.size else { return nil }
            let header = BoxReader(try source.read(offset: offset, length: 16))
            guard let box = header.nextBoxHeader(at: 0, available: source.size - offset) else { return nil }
            if box.type == "moov" {
                guard box.length <= maxMovieBoxLength else { return nil }
                let body = try source.read(
                    offset: offset + Int64(box.headerLength), length: Int(box.length) - box.headerLength)
                return body
            }
            offset += box.length
        }
        return nil
    }

    private static func parseMovie(_ movie: BoxReader) -> MediaMetadata? {
        var metadata = MediaMetadata()
        var fragmentDuration: UInt64?
        var timescale: UInt32 = 0
        var foundHeader = false

        for box in movie.boxes() {
            switch box.type {
            case "mvhd":
                guard let header = parseMovieHeader(movie.slice(box)) else { continue }
                foundHeader = true
                timescale = header.timescale
                if header.timescale > 0, header.duration > 0, header.duration != .max, header.duration != UInt32.max {
                    metadata.durationSeconds = Double(header.duration) / Double(header.timescale)
                }
                // Some encoders write zero in Unix time here, or Unix time itself, and both mean no real
                // date. Nothing recorded on video predates 1970 in practice, so those count as missing.
                if let seconds = Int64(exactly: header.created), seconds > epochOffset {
                    metadata.captureDate = CaptureDate(
                        wallClockMilliseconds: (seconds - epochOffset) * 1000, utcOffsetMinutes: 0)
                }
            case "trak":
                guard metadata.pixelWidth == nil else { continue }
                if let track = parseVideoTrack(movie.slice(box)) {
                    metadata.pixelWidth = track.width
                    metadata.pixelHeight = track.height
                    metadata.orientation = track.orientation
                }
            case "mvex":
                let extends = movie.slice(box)
                for child in extends.boxes() where child.type == "mehd" {
                    let body = extends.slice(child)
                    fragmentDuration = body.version == 1 ? body.uint64(at: 4) : body.uint32(at: 4).map(UInt64.init)
                }
            default:
                continue
            }
        }

        // Fragmented files keep their real duration in the movie extends box.
        if metadata.durationSeconds == nil, let fragmentDuration, fragmentDuration > 0, timescale > 0 {
            metadata.durationSeconds = Double(fragmentDuration) / Double(timescale)
        }
        return foundHeader ? metadata : nil
    }

    private static func parseMovieHeader(_ box: BoxReader) -> (created: UInt64, timescale: UInt32, duration: UInt64)? {
        if box.version == 1 {
            guard let created = box.uint64(at: 4), let timescale = box.uint32(at: 20),
                let duration = box.uint64(at: 24)
            else { return nil }
            return (created, timescale, duration)
        }
        guard let created = box.uint32(at: 4), let timescale = box.uint32(at: 12),
            let duration = box.uint32(at: 16)
        else { return nil }
        return (UInt64(created), timescale, UInt64(duration))
    }

    private static func parseVideoTrack(_ track: BoxReader) -> (width: Int, height: Int, orientation: Int)? {
        var isVideo = false
        var header: (width: Int, height: Int, orientation: Int)?
        for box in track.boxes() {
            switch box.type {
            case "tkhd":
                header = parseTrackHeader(track.slice(box))
            case "mdia":
                let media = track.slice(box)
                for child in media.boxes() where child.type == "hdlr" {
                    isVideo = media.slice(child).fourCharacterCode(at: 8) == "vide"
                }
            default:
                continue
            }
        }
        return isVideo ? header : nil
    }

    private static func parseTrackHeader(_ box: BoxReader) -> (width: Int, height: Int, orientation: Int)? {
        // After the versioned fields: 8 reserved, then layer, group, volume and 2 reserved, then the matrix.
        let matrixOffset = box.version == 1 ? 52 : 40
        guard let a = box.int32(at: matrixOffset), let b = box.int32(at: matrixOffset + 4),
            let c = box.int32(at: matrixOffset + 12), let d = box.int32(at: matrixOffset + 16),
            let width = box.uint32(at: matrixOffset + 36), let height = box.uint32(at: matrixOffset + 40)
        else { return nil }
        // Both are 16.16 fixed point.
        let (pixelWidth, pixelHeight) = (Int(width >> 16), Int(height >> 16))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return (pixelWidth, pixelHeight, orientation(a: a, b: b, c: c, d: d))
    }

    /// Maps a rotation matrix to the EXIF orientation that describes it.
    private static func orientation(a: Int32, b: Int32, c: Int32, d: Int32) -> Int {
        switch (a.signum(), b.signum(), c.signum(), d.signum()) {
        case (0, 1, -1, 0): 6
        case (-1, 0, 0, -1): 3
        case (0, -1, 1, 0): 8
        default: 1
        }
    }
}

/// Bounds-checked big-endian access to box contents. Every field is optional, because files can be
/// truncated or corrupt, and that must never trap.
struct BoxReader {
    struct Box {
        var type: String
        var offset: Int
        var length: Int64
        var headerLength: Int
    }

    private let bytes: Data

    init(_ data: Data) { bytes = data.startIndex == 0 ? data : Data(data) }

    /// The version byte of a full box.
    var version: UInt8? { bytes.first }

    func slice(_ box: Box) -> BoxReader {
        let start = box.offset + box.headerLength
        let end = min(Int64(bytes.count), Int64(box.offset) + box.length)
        guard start < end else { return BoxReader(Data()) }
        return BoxReader(bytes.subdata(in: start..<Int(end)))
    }

    func boxes() -> [Box] {
        var found: [Box] = []
        var offset = 0
        while offset + 8 <= bytes.count, found.count < 1024,
            let box = nextBoxHeader(at: offset, available: Int64(bytes.count - offset))
        {
            found.append(box)
            offset += Int(box.length)
        }
        return found
    }

    /// Reads a box header at `offset`. `available` is how many bytes remain in the enclosing container.
    func nextBoxHeader(at offset: Int, available: Int64) -> Box? {
        guard let size = uint32(at: offset), let type = fourCharacterCode(at: offset + 4) else { return nil }
        var length = Int64(size)
        var headerLength = 8
        if size == 1 {
            guard let large = uint64(at: offset + 8), let value = Int64(exactly: large) else { return nil }
            length = value
            headerLength = 16
        } else if size == 0 {
            // Runs to the end of the container.
            length = available
        }
        guard length >= Int64(headerLength), length <= available else { return nil }
        return Box(type: type, offset: offset, length: length, headerLength: headerLength)
    }

    func fourCharacterCode(at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func int32(at offset: Int) -> Int32? { uint32(at: offset).map(Int32.init(bitPattern:)) }

    func uint64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        return bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
