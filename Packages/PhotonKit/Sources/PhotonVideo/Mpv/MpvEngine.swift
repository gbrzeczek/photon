import CMpv
import CoreGraphics
import Foundation
import PhotonIndex
import QuartzCore
import Synchronization

/// Plays what AVFoundation can't open, through Photon's own LGPL build of libmpv and FFmpeg: Matroska,
/// WebM, AVI, WMV, FLV, MPEG program and transport streams, Ogg, DV and the rest.
public struct MpvEngine: VideoEngine {
    /// Every video extension the library indexes that AVFoundation doesn't open.
    public static let formats: Set<String> = [
        "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "mts", "m2ts", "vob", "ogv", "dv", "asf", "divx",
        "rm", "rmvb", "mxf",
    ]

    public init() {}

    /// Whether this build carries libmpv. Without it, the engine plays nothing.
    public static var isAvailable: Bool { MpvLibrary.shared != nil }

    public func canPlay(fileExtension: String) -> Bool {
        Self.isAvailable && Self.formats.contains(fileExtension.lowercased())
    }

    /// AVFoundation's formats too, for the codecs inside them that only FFmpeg decodes.
    public func canTryAfterOthers(fileExtension: String) -> Bool {
        Self.isAvailable && VideoFormats.avFoundation.contains(fileExtension.lowercased())
    }

    @MainActor public func makePlayback(for source: VideoSource) -> any VideoPlayback {
        MpvPlayback(source: source)
    }
}

/// One video, playing through mpv into an `MpvVideoLayer`.
///
/// Everything here runs on the main thread and returns at once. mpv itself is only called on `queue`,
/// and on the layer's draw queue, because its calls can block while it reads. Its events arrive on the
/// core's own thread and come to the main thread from there.
@MainActor
final class MpvPlayback: VideoPlayback {
    private let source: VideoSource
    private let provider: ScheduledByteProvider
    private let videoLayer = MpvVideoLayer()
    private let queue = DispatchQueue(label: "app.photon.mpv.playback", qos: .userInitiated)
    private var core: MpvCore?
    private var isClosed = false
    private var paused = true
    private var speed: Float = 1
    private var atEnd = false
    private var seekCompletion: ((Bool) -> Void)?
    private var seekGeneration = 0
    private var restartedGeneration = 0
    private lazy var previews = MpvFramePreviewer(source: source)
    /// The latest time from mpv, which reports it every frame. The main thread takes it at most every
    /// tenth of a second.
    private let latestTime = Mutex<(time: Double, posted: Bool)>((0, false))

    private(set) var status: VideoStatus = .loading
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    let canPlayBackward = false
    var onChange: (() -> Void)?

    var loops = false {
        didSet { set("loop-file", loops ? "inf" : "no") }
    }

    var isMuted = false {
        didSet { set("mute", isMuted ? "yes" : "no") }
    }

    var volume: Float = 1 {
        didSet {
            volume = min(max(volume, 0), 1)
            set("volume", String(format: "%.1f", volume * 100))
        }
    }

    var fillsBounds = false {
        didSet { set("panscan", fillsBounds ? "1.0" : "0.0") }
    }

    init(source: VideoSource) {
        self.source = source
        provider = ScheduledByteProvider(source: source, priority: .visible)
        videoLayer.onFirstFrame = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.notify() } }
        }
        let provider = provider
        let layer = DrawingLayer(videoLayer)
        let fileExtension = source.fileExtension
        queue.async { [weak self] in
            let result = Result { try Self.open(provider: provider, fileExtension: fileExtension) }
            let core = CoreResult(result: result)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.opened(core.result) ?? Self.discard(core.result, layer: layer) }
            }
        }
    }

    var layer: CALayer { videoLayer }
    var isShowingFrame: Bool { videoLayer.hasFrame }
    var rate: Float { status == .ready && !paused ? speed : 0 }

    // MARK: Opening

    /// Runs on `queue`. The render context has to exist before the file loads, or mpv decodes no video.
    private nonisolated static func open(
        provider: ScheduledByteProvider, fileExtension: String
    ) throws -> MpvCore {
        guard let api = MpvLibrary.shared else { throw MpvError(description: "No libmpv in this build") }
        let core = try MpvCore(
            api: api,
            options: [
                ("vo", "libmpv"),
                // CoreAudio's output failed on planar audio in Spike 2.
                ("ao", "avfoundation"),
                ("hwdec", "auto-safe"),
                ("keep-open", "yes"),
                ("pause", "yes"),
                ("background", "color"),
                ("background-color", "#00000000"),
                ("sub-visibility", "yes"),
                ("audio-pitch-correction", "yes"),
                // Some demuxers, MPEG-TS's among them, land after the time asked for, and an exact seek
                // can't go back from there. Starting half a second early costs a few frames.
                ("hr-seek-demuxer-offset", "0.5"),
            ])
        core.register(provider)
        return core
    }

    private func opened(_ result: Result<MpvCore, any Error>) {
        guard case .success(let core) = result, !isClosed else {
            if case .success(let core) = result { Self.destroy(core, layer: DrawingLayer(videoLayer), queue: queue) }
            status = .unsupported
            notify()
            return
        }
        self.core = core
        let layer = DrawingLayer(videoLayer)
        let fileExtension = source.fileExtension
        let state = (muted: isMuted, volume: volume, loops: loops, fills: fillsBounds)
        queue.async { [weak self] in
            do {
                try core.start { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
                }
                try layer.layer.attach(core: core)
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.status = .unsupported
                        self?.notify()
                    }
                }
                return
            }
            core.observe("pause", format: MPV_FORMAT_FLAG)
            core.observe("speed", format: MPV_FORMAT_DOUBLE)
            core.observe("duration", format: MPV_FORMAT_DOUBLE)
            core.observe("eof-reached", format: MPV_FORMAT_FLAG)
            self?.observeTime(core)
            core.set("mute", state.muted ? "yes" : "no")
            core.set("volume", String(format: "%.1f", state.volume * 100))
            core.set("loop-file", state.loops ? "inf" : "no")
            core.set("panscan", state.fills ? "1.0" : "0.0")
            core.command(["loadfile", MpvStreamRegistration.url(fileExtension: fileExtension)])
        }
    }

    private nonisolated func observeTime(_ core: MpvCore) {
        core.observe("time-pos", format: MPV_FORMAT_DOUBLE)
    }

    private static func discard(_ result: Result<MpvCore, any Error>, layer: DrawingLayer) {
        if case .success(let core) = result {
            DispatchQueue.global(qos: .utility).async {
                layer.layer.detach()
                core.destroy()
            }
        }
    }

    // MARK: Events

    private func handle(_ event: MpvEvent) {
        guard !isClosed, let core else { return }
        switch event {
        case .fileLoaded:
            // A missing decoder with an audio track plays audio only and raises no error, so the codec
            // is what says whether the video can be shown.
            queue.async { [weak self] in
                let codec = core.string("video-codec") ?? ""
                let duration = core.double("duration") ?? 0
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.loaded(codec: codec, duration: duration) }
                }
            }
        case .endFile(let reason, _):
            if reason == Int32(MPV_END_FILE_REASON_ERROR.rawValue) || status == .loading {
                status = provider.readError != nil ? .unavailable : .unsupported
                finishSeek(false)
                notify()
            }
        case .playbackRestart:
            // mpv restarts playback only once its video output has the first frame.
            if status == .ready || status == .loading { videoLayer.frameIsShown() }
            if restartedGeneration < seekGeneration {
                restartedGeneration = seekGeneration
                finishSeek(true)
            }
            notify()
        case .property(let name, let value):
            switch name {
            case "pause": paused = value.flag ?? paused
            case "speed": if let speed = value.double { self.speed = Float(speed) }
            case "duration": if let duration = value.double, duration.isFinite { self.duration = duration }
            case "eof-reached": atEnd = value.flag ?? false
            case "time-pos":
                if let time = value.double, time.isFinite { currentTime = time }
            default: break
            }
            if name == "time-pos" {
                throttledNotify()
            } else {
                notify()
            }
        case .videoReconfigured:
            videoLayer.scheduleDraw()
        case .hook, .shutdown:
            break
        }
    }

    private func loaded(codec: String, duration: Double) {
        guard !isClosed, status == .loading else { return }
        if codec.isEmpty {
            status = .unsupported
        } else {
            if duration.isFinite, duration > 0 { self.duration = duration }
            status = .ready
            videoLayer.matchScale()
        }
        notify()
    }

    private var timeNotifyPending = false

    private func throttledNotify() {
        guard !timeNotifyPending else { return }
        timeNotifyPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.timeNotifyPending = false
                self?.notify()
            }
        }
    }

    private func notify() {
        guard !isClosed else { return }
        onChange?()
    }

    // MARK: Control

    private func set(_ name: String, _ value: String) {
        guard let core, !isClosed else { return }
        queue.async { core.set(name, value) }
    }

    private func command(_ arguments: [String]) {
        guard let core, !isClosed else { return }
        queue.async { core.command(arguments) }
    }

    func play(rate: Float) {
        guard status == .ready, rate > 0 else { return }
        // At the end, playing forward starts again from the beginning, as QuickTime Player does.
        if atEnd || (duration > 0 && currentTime >= duration - 0.05) {
            command(["seek", "0", "absolute+exact"])
            currentTime = 0
            atEnd = false
        }
        speed = rate
        paused = false
        set("speed", String(format: "%.4f", rate))
        set("pause", "no")
        notify()
    }

    func pause() {
        guard status == .ready else { return }
        paused = true
        set("pause", "yes")
        notify()
    }

    func seek(to seconds: Double, exact: Bool) {
        seek(to: seconds, exact: exact) { _ in }
    }

    func seek(to seconds: Double, exact: Bool, completion: @escaping (Bool) -> Void) {
        guard status == .ready, let core else {
            completion(false)
            return
        }
        finishSeek(false)
        seekGeneration += 1
        seekCompletion = completion
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        atEnd = false
        let generation = seekGeneration
        queue.async { [weak self] in
            let code = core.command([
                "seek", String(format: "%.4f", target), exact ? "absolute+exact" : "absolute+keyframes",
            ])
            guard code < 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.seekGeneration == generation else { return }
                    self.finishSeek(false)
                }
            }
        }
        notify()
    }

    private func finishSeek(_ landed: Bool) {
        guard let completion = seekCompletion else { return }
        seekCompletion = nil
        completion(landed)
    }

    func step(frames: Int) {
        guard status == .ready, frames != 0 else { return }
        paused = true
        set("pause", "yes")
        let name = frames > 0 ? "frame-step" : "frame-back-step"
        for _ in 0..<min(abs(frames), 30) { command([name]) }
        notify()
    }

    func previewFrame(at seconds: Double, maxPixelSize: Int, completion: @escaping (CGImage?, Double) -> Void) {
        guard status == .ready else { return }
        previews.request(at: seconds, maxPixelSize: maxPixelSize, completion: completion)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        onChange = nil
        finishSeek(false)
        previews.cancel()
        provider.cancel()
        videoLayer.onFirstFrame = nil
        if let core { Self.destroy(core, layer: DrawingLayer(videoLayer), queue: queue) }
        core = nil
    }

    /// mpv's order: the render context first, with its GL context current, then the core. The layer
    /// keeps its GL context until it goes, because Core Animation may still display it.
    private static func destroy(_ core: MpvCore, layer: DrawingLayer, queue: DispatchQueue) {
        queue.async {
            core.set("pause", "yes")
            layer.layer.detach()
            core.destroy()
        }
    }
}

/// Scrub previews for mpv's formats, from a second core with the software renderer, reading through
/// the scheduler at the viewer's priority. One frame decodes at a time, and only the latest request
/// waits behind it, so a fast drag never builds a queue.
@MainActor
final class MpvFramePreviewer {
    private let source: VideoSource
    private let worker: Worker
    private var inFlight = false
    private var waiting: (seconds: Double, size: Int, completion: (CGImage?, Double) -> Void)?
    private var cancelled = false

    /// Holds the grabber, which is only touched on the worker's own serial queue.
    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "app.photon.mpv.previews", qos: .userInitiated)
        let provider: ScheduledByteProvider
        var grabber: MpvFrameGrabber?
        var failed = false
        init(provider: ScheduledByteProvider) { self.provider = provider }
    }

    init(source: VideoSource) {
        self.source = source
        worker = Worker(provider: ScheduledByteProvider(source: source, priority: .visible))
    }

    func request(at seconds: Double, maxPixelSize: Int, completion: @escaping (CGImage?, Double) -> Void) {
        guard !cancelled else { return }
        waiting = (seconds, maxPixelSize, completion)
        if !inFlight { startNext() }
    }

    private var current: ((CGImage?, Double) -> Void)?

    private func startNext() {
        guard let next = waiting, !cancelled else {
            inFlight = false
            return
        }
        waiting = nil
        inFlight = true
        current = next.completion
        let worker = worker
        let source = source
        let (seconds, size) = (next.seconds, next.size)
        worker.queue.async { [weak self] in
            let found = Self.grab(worker: worker, source: source, seconds: seconds, size: size)
            let box = UncheckedImage(image: found?.image, time: found?.time ?? seconds)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.cancelled else { return }
                    let completion = self.current
                    self.current = nil
                    completion?(box.image, box.time)
                    self.startNext()
                }
            }
        }
    }

    private nonisolated static func grab(
        worker: Worker, source: VideoSource, seconds: Double, size: Int
    ) -> (image: CGImage, time: Double)? {
        if worker.grabber == nil, !worker.failed, let api = MpvLibrary.shared {
            if let grabber = try? MpvFrameGrabber(
                api: api, provider: worker.provider, fileExtension: source.fileExtension),
                grabber.open() != nil
            {
                worker.grabber = grabber
            } else {
                worker.failed = true
            }
        }
        return worker.grabber?.frameAndTime(at: seconds, maxPixelSize: size)
    }

    func cancel() {
        cancelled = true
        waiting = nil
        let worker = worker
        worker.provider.cancel()
        worker.queue.async {
            worker.grabber?.close()
            worker.grabber = nil
        }
    }
}

/// A decoded frame, handed from the frames queue to the main thread and never touched again there.
private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage?
    let time: Double
}

/// The video layer, handed to mpv's queues. Core Animation layers aren't Sendable, but this one's mpv
/// work is all on its own draw queue, behind its own lock, which is what makes passing it safe.
struct DrawingLayer: @unchecked Sendable {
    let layer: MpvVideoLayer
    init(_ layer: MpvVideoLayer) { self.layer = layer }
}

/// A core made on the playback queue, on its way to the main thread. Only one side holds it at a time.
private struct CoreResult: @unchecked Sendable {
    let result: Result<MpvCore, any Error>
}
