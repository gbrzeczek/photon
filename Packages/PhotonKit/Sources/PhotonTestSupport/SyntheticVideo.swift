import AVFoundation
import CoreVideo
import Foundation

/// Real, playable videos made with AVFoundation, for the format test set. Each frame is a solid color
/// that changes over time, with a bar whose position gives the frame number, so a test can tell where
/// a frame came from.
public enum SyntheticVideo {
    public struct Format: Sendable, Hashable, CustomStringConvertible {
        public var codec: AVVideoCodecType
        public var fileType: AVFileType
        public var fileExtension: String

        public var description: String { "\(codec.rawValue).\(fileExtension)" }

        public static let h264MP4 = Format(codec: .h264, fileType: .mp4, fileExtension: "mp4")
        public static let h264MOV = Format(codec: .h264, fileType: .mov, fileExtension: "mov")
        public static let hevcMOV = Format(codec: .hevc, fileType: .mov, fileExtension: "mov")
        public static let hevcMP4 = Format(codec: .hevc, fileType: .mp4, fileExtension: "mp4")
        public static let h264M4V = Format(codec: .h264, fileType: .m4v, fileExtension: "m4v")
        public static let proRes422MOV = Format(codec: .proRes422, fileType: .mov, fileExtension: "mov")
        public static let jpegMOV = Format(codec: .jpeg, fileType: .mov, fileExtension: "mov")

        /// Everything AVFoundation writes here, which is what the AVFoundation engine must play.
        public static let avFoundationSet: [Format] = [h264MP4, h264MOV, hevcMOV, hevcMP4, h264M4V, proRes422MOV, jpegMOV]
    }

    public struct Options: Sendable, Hashable {
        public var width = 320
        public var height = 180
        public var framesPerSecond: Int32 = 30
        public var seconds = 2.0
        /// Clockwise quarter turns stored as the track's transform, as a phone held upright writes.
        public var quarterTurns = 0
        public init() {}
    }

    public enum WriteError: Error { case setup(String), failed(String) }

    /// The color of frame `index`, as 0–255 red, green and blue. Frame 0 is pure red.
    public static func color(frame index: Int, of count: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let t = count > 1 ? Double(index) / Double(count - 1) : 0
        return (UInt8(255 * (1 - t)), UInt8(64), UInt8(255 * t))
    }

    /// Writes a clip to `url`, copied from the one encoded for these settings in this process.
    ///
    /// Encoding talks to VideoToolbox's encoder service, which has hung on CI's virtual Macs and never
    /// answered. Tests ask for the same few clips many times, and in parallel, so each distinct clip is
    /// encoded once, one at a time, which makes that far less likely.
    public static func write(to url: URL, format: Format, options: Options = Options()) async throws {
        let clip = try await encoded.clip(format: format, options: options)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: clip, to: url)
    }

    private static let encoded = EncodedClips()

    /// Clips encoded in this process, by format and options, in a folder of their own.
    private actor EncodedClips {
        private struct Key: Hashable {
            var format: Format
            var options: Options
        }

        private var clips: [Key: Task<URL, any Error>] = [:]
        /// The last encode asked for. Each waits for the one before, so only one runs at a time.
        private var last: Task<Void, Never>?
        private let directory = FileManager.default.temporaryDirectory
            .appending(path: "photon-synthetic-video-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)

        func clip(format: Format, options: Options) async throws -> URL {
            let key = Key(format: format, options: options)
            if let existing = clips[key] { return try await existing.value }
            let previous = last
            let url = directory.appending(path: "\(clips.count).\(format.fileExtension)")
            let directory = directory
            let task = Task<URL, any Error> {
                await previous?.value
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await SyntheticVideo.encode(to: url, format: format, options: options)
                return url
            }
            clips[key] = task
            last = Task { _ = try? await task.value }
            do {
                return try await task.value
            } catch {
                // A later test can try again.
                if clips[key] == task { clips[key] = nil }
                throw error
            }
        }
    }

    private static func encode(to url: URL, format: Format, options: Options) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: format.fileType)
        let settings: [String: Any] = [
            AVVideoCodecKey: format.codec, AVVideoWidthKey: options.width, AVVideoHeightKey: options.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if options.quarterTurns % 4 != 0 {
            input.transform = CGAffineTransform(rotationAngle: CGFloat(options.quarterTurns) * .pi / 2)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: options.width, kCVPixelBufferHeightKey as String: options.height,
            ])
        guard writer.canAdd(input) else { throw WriteError.setup("can't add input for \(format)") }
        writer.add(input)
        guard writer.startWriting() else { throw WriteError.setup(writer.error.map { "\($0)" } ?? "\(format)") }
        writer.startSession(atSourceTime: .zero)

        let count = Int((options.seconds * Double(options.framesPerSecond)).rounded())
        for index in 0..<count {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw WriteError.setup("no pixel buffer pool") }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw WriteError.setup("no pixel buffer") }
            fill(buffer, frame: index, of: count)
            let time = CMTime(value: CMTimeValue(index), timescale: options.framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw WriteError.failed(writer.error.map { "\($0)" } ?? "append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw WriteError.failed(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")
        }
    }

    private static func fill(_ buffer: CVPixelBuffer, frame index: Int, of count: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let color = color(frame: index, of: count)
        let barX = count > 1 ? (width - 8) * index / (count - 1) : 0
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixel = row + x * 4
                let isBar = x >= barX && x < barX + 8 && y < height / 6
                pixel[0] = isBar ? 255 : color.blue
                pixel[1] = isBar ? 255 : color.green
                pixel[2] = isBar ? 255 : color.red
                pixel[3] = 255
            }
        }
    }
}
