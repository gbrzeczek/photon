import AVFoundation
import PhotonIndex
import QuartzCore

/// Plays what AVFoundation can open: MOV and MP4 with H.264, HEVC, ProRes, and AV1 where the Mac
/// decodes it.
public struct AVFoundationEngine: VideoEngine {
    public init() {}

    public func canPlay(fileExtension: String) -> Bool { VideoFormats.avFoundation.contains(fileExtension) }

    @MainActor public func makePlayback(for source: VideoSource) -> any VideoPlayback {
        AVFoundationPlayback(source: source)
    }
}

@MainActor
final class AVFoundationPlayback: VideoPlayback {
    private let loader: ScheduledResourceLoader
    private let asset: AVURLAsset
    private let item: AVPlayerItem
    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var isClosed = false
    private var endObserver: (any NSObjectProtocol)?
    var loops = false
    private lazy var previews: FramePreviewer = FramePreviewer(asset: asset)

    private(set) var status: VideoStatus = .loading
    private(set) var duration: Double = 0
    private(set) var canPlayBackward = false
    var onChange: (() -> Void)?

    init(source: VideoSource) {
        loader = ScheduledResourceLoader(source: source, priority: .visible)
        asset = loader.makeAsset()
        item = AVPlayerItem(asset: asset)
        // Keeps voices at their own pitch at other speeds.
        item.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: item)
        // Nothing here is a document the system should resume, and a video in a photo browser shouldn't
        // take over the Now Playing controls.
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.actionAtItemEnd = .pause
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull()]
        observe()
    }

    var layer: CALayer { playerLayer }
    var isShowingFrame: Bool { playerLayer.isReadyForDisplay }
    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }
    var rate: Float { player.rate }
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }
    var volume: Float {
        get { player.volume }
        set { player.volume = min(max(newValue, 0), 1) }
    }
    var fillsBounds: Bool {
        get { playerLayer.videoGravity == .resizeAspectFill }
        set { playerLayer.videoGravity = newValue ? .resizeAspectFill : .resizeAspect }
    }

    private func observe() {
        // KVO calls arrive on whatever thread changed the value, so each one hops to the main thread.
        observations.append(
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.itemStatusChanged() }
            })
        observations.append(
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.notify() }
            })
        observations.append(
            playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.notify() }
            })
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notify() }
        }
    }

    private func itemStatusChanged() {
        guard !isClosed else { return }
        switch item.status {
        case .readyToPlay:
            let seconds = item.duration.seconds
            duration = seconds.isFinite ? seconds : 0
            canPlayBackward = item.canPlayReverse
            status = .ready
        case .failed:
            status = loader.readError != nil ? .unavailable : .unsupported
        default:
            break
        }
        notify()
    }

    private func reachedEnd() {
        guard loops, !isClosed else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = 1
    }

    private func notify() {
        guard !isClosed else { return }
        if status == .ready, item.status == .failed {
            status = loader.readError != nil ? .unavailable : .unsupported
        }
        onChange?()
    }

    func play(rate: Float) {
        guard status == .ready else { return }
        if rate < 0, !canPlayBackward { return }
        // At the end, playing forward starts again from the beginning, as QuickTime Player does.
        if rate > 0, duration > 0, currentTime >= duration - 0.05 { player.seek(to: .zero) }
        player.rate = rate
    }

    func pause() { player.pause() }

    func seek(to seconds: Double, exact: Bool) {
        seek(to: seconds, exact: exact) { _ in }
    }

    func seek(to seconds: Double, exact: Bool, completion: @escaping (Bool) -> Void) {
        guard status == .ready else {
            completion(false)
            return
        }
        let time = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)
        let tolerance: CMTime = exact ? .zero : .positiveInfinity
        let done = UncheckedCompletion(completion: completion)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            Task { @MainActor in done.completion(finished) }
        }
        notify()
    }

    func step(frames: Int) {
        guard status == .ready else { return }
        player.pause()
        item.step(byCount: frames)
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
        observations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        timeObserver = nil
        player.pause()
        previews.cancel()
        player.replaceCurrentItem(with: nil)
        loader.cancelAll()
        playerLayer.player = nil
    }
}

/// Scrub previews. One frame decodes at a time, and only the latest request waits behind it, so a fast
/// drag never builds a queue.
@MainActor
final class FramePreviewer {
    private let asset: AVAsset
    private var generator: AVAssetImageGenerator?
    private var generatorSize = 0
    private var inFlight: Task<Void, Never>?
    private var waiting: (seconds: Double, size: Int, completion: (CGImage?, Double) -> Void)?

    init(asset: AVAsset) { self.asset = asset }

    func request(at seconds: Double, maxPixelSize: Int, completion: @escaping (CGImage?, Double) -> Void) {
        waiting = (seconds, maxPixelSize, completion)
        if inFlight == nil { startNext() }
    }

    private func startNext() {
        guard let next = waiting else {
            inFlight = nil
            return
        }
        waiting = nil
        if generator == nil || generatorSize != next.size {
            generator = VideoFrames.makeGenerator(asset, maxPixelSize: next.size, tolerance: 0.5)
            generatorSize = next.size
        }
        guard let generator else { return }
        let box = UncheckedGenerator(generator: generator)
        inFlight = Task { [weak self] in
            let time = CMTime(seconds: max(0, next.seconds), preferredTimescale: 600)
            let found = try? await box.generator.image(at: time)
            guard !Task.isCancelled else { return }
            let actual = found?.actualTime.seconds ?? next.seconds
            next.completion(found?.image, actual.isFinite ? actual : next.seconds)
            self?.startNext()
        }
    }

    func cancel() {
        waiting = nil
        inFlight?.cancel()
        inFlight = nil
        generator?.cancelAllCGImageGeneration()
    }
}

/// A main-thread completion, carried through AVFoundation's callback, which may arrive on any thread.
private struct UncheckedCompletion: @unchecked Sendable {
    let completion: (Bool) -> Void
}

/// `AVAssetImageGenerator` is documented as safe to use from any thread, but isn't marked as such.
struct UncheckedGenerator: @unchecked Sendable {
    let generator: AVAssetImageGenerator
}
