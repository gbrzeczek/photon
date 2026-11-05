import AVFoundation
import CoreVideo
import Foundation
import PhotonCore
import PhotonIndex
import PhotonTestSupport
import Testing

@testable import PhotonMedia

@Suite("Video metadata from QuickTime and MP4 boxes")
struct VideoMetadataTests {
    private let reader = MediaMetadataReader()

    private func read(_ data: Data, extension fileExtension: String = "mp4") throws -> MediaMetadata? {
        try reader.metadata(kind: .video, fileExtension: fileExtension, from: DataByteSource(data))
    }

    @Test("Reads dimensions, duration and date, with the movie box at either end",
        arguments: [false, true])
    func readsBoxes(moovAtEnd: Bool) throws {
        var options = SyntheticMedia.MovieOptions()
        options.width = 3840
        options.height = 2160
        options.timescale = 1000
        options.durationUnits = 12_500
        options.moovAtEnd = moovAtEnd
        let metadata = try #require(try read(SyntheticMedia.movie(options)))

        #expect(metadata.pixelWidth == 3840)
        #expect(metadata.pixelHeight == 2160)
        #expect(metadata.durationSeconds == 12.5)
        #expect(metadata.orientation == 1)
        // 3,600,000,000 seconds after 1904, as UTC.
        #expect(metadata.captureDate == CaptureDate(wallClockMilliseconds: 1_517_155_200_000, utcOffsetMinutes: 0))
    }

    @Test("64-bit header fields, as long recordings use")
    func largeHeaders() throws {
        var options = SyntheticMedia.MovieOptions()
        options.largeHeaders = true
        options.timescale = 90_000
        options.durationUnits = 90_000 * 6 * 3600
        let metadata = try #require(try read(SyntheticMedia.movie(options)))
        #expect(metadata.durationSeconds == 21_600)
        #expect(metadata.pixelWidth == 1920)
    }

    @Test("Rotation becomes an EXIF orientation", arguments: [(0, 1), (90, 6), (180, 3), (270, 8)])
    func rotation(degrees: Int, orientation: Int) throws {
        var options = SyntheticMedia.MovieOptions()
        options.rotation = degrees
        #expect(try read(SyntheticMedia.movie(options))?.orientation == orientation)
    }

    @Test("A date of zero means none")
    func zeroDate() throws {
        var options = SyntheticMedia.MovieOptions()
        options.created = 0
        let metadata = try #require(try read(SyntheticMedia.movie(options)))
        #expect(metadata.captureDate == nil)
    }

    @Test("A long video needs only its box headers and movie box")
    func readsLittle() throws {
        var options = SyntheticMedia.MovieOptions()
        options.moovAtEnd = true
        options.mediaBytes = 32 << 20
        let data = SyntheticMedia.movie(options)
        let source = CountingSource(data)

        _ = try reader.metadata(kind: .video, fileExtension: "mp4", from: source)

        #expect(source.bytesRead < 4096)
        #expect(source.reads.count <= 4)
    }

    @Test("Containers that aren't QuickTime or MP4 wait for Milestone 6, and read nothing",
        arguments: ["mkv", "webm", "avi", "wmv", "mpg"])
    func otherContainers(fileExtension: String) throws {
        let source = CountingSource(Data(count: 1000))
        #expect(try reader.metadata(kind: .video, fileExtension: fileExtension, from: source) == nil)
        #expect(source.reads.isEmpty)
    }

    @Test("A file that isn't a movie gives no metadata")
    func notAMovie() throws {
        #expect(try read(Data()) == nil)
        #expect(try read(Data(count: 7)) == nil)
        #expect(try read(Data(repeating: 0x41, count: 4096)) == nil)
    }

    @Test("A box claiming zero or impossible lengths can't loop or trap")
    func badBoxes() throws {
        let zero = Data([0, 0, 0, 7]) + Data("free".utf8) + Data(count: 64)
        #expect(try read(zero) == nil)
        let tooLong = Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data("moov".utf8)
        #expect(try read(tooLong) == nil)
        let huge = Data([0, 0, 0, 1]) + Data("moov".utf8) + Data(repeating: 0xFF, count: 8)
        #expect(try read(huge) == nil)
    }

    @Test("A box of size zero runs to the end of the file")
    func sizeZeroBox() throws {
        let movie = SyntheticMedia.movie()
        var patched = movie
        // ftyp is 24 bytes in this generator, and the movie box follows it.
        let moovOffset = 24
        let reader = BoxReader(movie)
        let box = try #require(reader.nextBoxHeader(at: moovOffset, available: Int64(movie.count - moovOffset)))
        #expect(box.type == "moov")
        patched.removeSubrange((moovOffset + Int(box.length))...)
        patched.replaceSubrange(moovOffset..<(moovOffset + 4), with: Data(count: 4))
        #expect(try read(patched)?.pixelWidth == 1920)
    }

    @Test("Truncated and corrupted movies never crash")
    func fuzz() throws {
        var generator = SeededGenerator(seed: 11)
        let movie = SyntheticMedia.movie()
        for length in stride(from: 0, to: 700, by: 3) { _ = try read(movie.prefix(length)) }
        for _ in 0..<2000 {
            var copy = movie
            for _ in 0..<8 {
                copy[Int.random(in: 0..<600, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try read(copy)
        }
    }

    @Test("The first video track is used, and sound tracks are ignored")
    func audioTracks() throws {
        // A sound-only file has a header but no picture.
        var data = SyntheticMedia.movie()
        let handler = Data("vide".utf8)
        if let range = data.range(of: handler) { data.replaceSubrange(range, with: Data("soun".utf8)) }
        let metadata = try #require(try read(data))
        #expect(metadata.pixelWidth == nil)
        #expect(metadata.durationSeconds == 10)
    }

    @Test("Agrees with AVFoundation on a real encoded movie")
    func matchesAVFoundation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "movie.mp4")
        try await MovieWriter.write(to: url, width: 320, height: 240, frames: 30, framesPerSecond: 30)

        let metadata = try #require(try read(Data(contentsOf: url)))

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)

        #expect(metadata.pixelWidth == Int(size.width))
        #expect(metadata.pixelHeight == Int(size.height))
        #expect(abs((metadata.durationSeconds ?? 0) - duration) < 0.05)
    }
}

/// Encodes a short real movie, to compare the parser with AVFoundation.
enum MovieWriter {
    struct Failure: Error { let reason: String }

    static func write(to url: URL, width: Int, height: Int, frames: Int, framesPerSecond: Int32) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure(reason: "\(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure(reason: "no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure(reason: "no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 7 % 255), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure(reason: "\(String(describing: writer.error))") }
    }
}
