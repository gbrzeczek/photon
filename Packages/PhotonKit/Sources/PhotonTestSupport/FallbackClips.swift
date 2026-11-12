import Foundation

/// The fallback's format test set: synthetic clips in containers and codecs that only mpv plays,
/// written by `scripts/mpv/make-test-clips.sh` from FFmpeg's test pattern. They're committed, because
/// CI has no FFmpeg to make them.
public enum FallbackClip: String, CaseIterable, Sendable, CustomStringConvertible {
    case h264MKV = "h264.mkv"
    case vp9WebM = "vp9.webm"
    /// In one of AVFoundation's own containers, with a codec it doesn't decode.
    case vp9MP4 = "vp9.mp4"
    case vp8WebM = "vp8.webm"
    case av1MKV = "av1.mkv"
    case mpeg4AVI = "mpeg4.avi"
    case divx3AVI = "divx3.avi"
    case wmv2WMV = "wmv2.wmv"
    case flv1FLV = "flv1.flv"
    case mpeg2MPG = "mpeg2.mpg"
    case h264MTS = "h264.mts"
    case theoraOGV = "theora.ogv"
    case ntscDV = "ntsc.dv"
    case dnxhrMXF = "dnxhr.mxf"
    /// Sound and no picture. mpv plays the sound and raises no error.
    case audioOnlyMKV = "audio-only.mkv"

    public var description: String { rawValue }
    public var fileName: String { rawValue }
    public var fileExtension: String { (rawValue as NSString).pathExtension }

    /// Every clip with a picture.
    public static var playable: [FallbackClip] { allCases.filter { $0 != .audioOnlyMKV } }

    public var url: URL {
        Bundle.module.url(forResource: rawValue, withExtension: nil, subdirectory: "FallbackClips")
            ?? Bundle.module.bundleURL.appending(path: "FallbackClips/\(rawValue)")
    }

    /// How long the clip is.
    public var seconds: Double {
        switch self {
        case .ntscDV: 0.5
        case .dnxhrMXF: 1
        default: 2
        }
    }

    /// The picture's size as shown. DV's pixels aren't square, so it shows at 4:3.
    public var displaySize: (width: Int, height: Int) {
        switch self {
        case .ntscDV: (640, 480)
        case .dnxhrMXF: (640, 360)
        case .audioOnlyMKV: (0, 0)
        default: (320, 240)
        }
    }

    /// Copies the clip into `folder`, under its own name unless given another.
    @discardableResult
    public func copy(to folder: URL, as name: String? = nil) throws -> URL {
        let destination = folder.appending(path: name ?? rawValue)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
