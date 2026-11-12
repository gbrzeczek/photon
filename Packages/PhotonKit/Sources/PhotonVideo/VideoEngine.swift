import CoreGraphics
import QuartzCore

/// Where a playback stands.
public enum VideoStatus: Equatable, Sendable {
    case loading
    case ready
    /// The file couldn't be read: the volume went, failed, or the file changed. Worth trying again
    /// once the volume is back.
    case unavailable
    /// The file was read, and this engine can't play it.
    case unsupported
}

/// One video, playing in a layer. Everything here runs on the main thread and returns at once: loading,
/// seeking and decoding happen elsewhere, and `onChange` says when something moved.
@MainActor
public protocol VideoPlayback: AnyObject {
    /// Shows the picture. Placed by the caller, and it keeps the video's aspect inside its bounds.
    var layer: CALayer { get }
    var status: VideoStatus { get }
    /// Whether a frame is ready, so that the layer can replace a thumbnail without a black flash.
    var isShowingFrame: Bool { get }
    /// Seconds, or zero until it's known.
    var duration: Double { get }
    var currentTime: Double { get }
    /// Zero when paused, negative when playing backward.
    var rate: Float { get }
    var isMuted: Bool { get set }
    var canPlayBackward: Bool { get }
    /// Fills the layer's bounds, cropping, as a square tile does. Otherwise the whole picture fits.
    var fillsBounds: Bool { get set }
    /// Starts again from the beginning at the end, instead of pausing there.
    var loops: Bool { get set }
    /// Called on the main thread when status, rate or time change. Time changes come about ten times
    /// a second while playing, not every frame.
    var onChange: (() -> Void)? { get set }

    func play(rate: Float)
    func pause()
    /// `exact` decodes to the very frame. Otherwise the nearest keyframe, which is what a scrub wants.
    func seek(to seconds: Double, exact: Bool)
    /// The same, calling `completion` on the main thread once the seek has landed, or with false when
    /// another seek replaced it. The frame there may not be showing yet, so check `isShowingFrame` and
    /// the time before revealing the layer.
    func seek(to seconds: Double, exact: Bool, completion: @escaping (Bool) -> Void)
    func step(frames: Int)
    /// A frame for a scrub preview, near `seconds`, at most `maxPixelSize` on its long edge. Only the
    /// latest request is answered. A request made while one is decoding replaces any waiting.
    func previewFrame(at seconds: Double, maxPixelSize: Int, completion: @escaping (CGImage?, Double) -> Void)
    /// Stops reading and releases the player. Nothing is called after this.
    func close()
}

/// Where a video's poster frame is: about a second in, since the very first frame is often black, from
/// a fade in or a lens cap, or halfway through a shorter clip. Thumbnails and hover previews share it.
public enum VideoPoster {
    public static func time(duration: Double) -> Double {
        duration.isFinite && duration > 0 ? min(1, duration / 2) : 0
    }
}

/// Something that plays videos. AVFoundation comes first, and a fallback takes what it can't open.
public protocol VideoEngine: Sendable {
    func canPlay(fileExtension: String) -> Bool
    @MainActor func makePlayback(for source: VideoSource) -> any VideoPlayback
}

/// The engines in order of preference.
public struct VideoEngines: Sendable {
    public var engines: [any VideoEngine]

    public init(_ engines: [any VideoEngine]) { self.engines = engines }

    /// What this build plays.
    public static var standard: VideoEngines { VideoEngines([AVFoundationEngine()]) }

    public func engine(for fileExtension: String) -> (any VideoEngine)? {
        let lowered = fileExtension.lowercased()
        return engines.first { $0.canPlay(fileExtension: lowered) }
    }
}
