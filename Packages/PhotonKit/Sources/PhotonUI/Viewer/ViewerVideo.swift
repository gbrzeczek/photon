import AppKit
import PhotonCore
import PhotonVideo
import QuartzCore

/// The video in the viewer: its playback, its layer above the thumbnail, and the transport bar.
///
/// A playback only starts once the viewer has settled on a video, so a held arrow key never opens one.
/// The thumbnail stays underneath, and the player's layer only shows once it has a frame, so nothing
/// flashes black. Every read the player makes goes through the volume's I/O scheduler.
@MainActor
final class ViewerVideo {
    typealias SourceLookup = @Sendable (FileInstanceID) async -> VideoSource?

    private let engines: VideoEngines
    private let lookup: SourceLookup
    private weak var view: NSView?
    private weak var below: CALayer?
    let controls = VideoControlsView()
    let preview = ScrubPreviewView()

    private(set) var playback: (any VideoPlayback)?
    private(set) var asset: AssetID?
    private var startTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var frame: CGRect = .zero
    private var autoplays = false
    private var startsAt: Double?
    /// Where it was, so that a video whose drive came back carries on from there.
    private var lastTime: Double = 0
    private var wasPlayingBeforeScrub = false
    /// What a click changed, so that the second click of a double click can put it back.
    private var clickUndo: (time: Double, wasPlaying: Bool)?
    /// Mute, volume and speed carry from one video to the next, as mute does in QuickTime Player.
    private(set) var isMuted = false
    private(set) var volume: Float = 1
    /// What Space and the play button play at. J and L shuttle apart from it.
    private(set) var speed: Float = 1
    /// Why nothing is playing, for the status bar.
    private(set) var problem: String?
    private var controlsVisible = false
    /// Tells the viewer that the status or what's showing changed.
    var onChange: (() -> Void)?

    static let hideDelay: Duration = .seconds(2.5)
    private static let fastestRate: Float = 8
    /// The speed menu's choices, and what `[` and `]` step through.
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    init(engines: VideoEngines, lookup: @escaping SourceLookup, in view: NSView, above picture: CALayer) {
        self.engines = engines
        self.lookup = lookup
        self.view = view
        below = picture
        controls.alphaValue = 0
        controls.isHidden = true
        view.addSubview(controls)
        view.addSubview(preview)

        controls.onPlayPause = { [weak self] in self?.togglePlay() }
        controls.onMute = { [weak self] in self?.toggleMute() }
        controls.onVolume = { [weak self] level in self?.setVolume(level) }
        controls.onSkip = { [weak self] seconds in self?.seek(by: seconds) }
        controls.onSpeed = { [weak self] speed in self?.setSpeed(speed) }
        controls.onScrub = { [weak self] seconds, isFinal in self?.scrub(to: seconds, isFinal: isFinal) }
        controls.onHover = { [weak self] hover in self?.hover(hover) }
    }

    var status: VideoStatus? { playback?.status }
    var isPlaying: Bool { (playback?.rate ?? 0) != 0 }

    // MARK: Starting and stopping

    /// Opens the video for `asset`, unless it's already open and readable.
    func start(asset: AssetID, instance: FileInstanceID, aspect: CGFloat, autoplay: Bool) {
        if self.asset == asset, playback != nil || startTask != nil {
            guard playback?.status == .unavailable else { return }
            // The drive is back. Carry on from where it stopped, paused.
            let resume = lastTime
            stop()
            startsAt = resume
            open(asset: asset, instance: instance, aspect: aspect, autoplay: false)
            return
        }
        stop()
        open(asset: asset, instance: instance, aspect: aspect, autoplay: autoplay)
    }

    private func open(asset: AssetID, instance: FileInstanceID, aspect: CGFloat, autoplay: Bool) {
        self.asset = asset
        autoplays = autoplay
        preview.setAspect(aspect)
        let lookup = lookup
        startTask = Task { [weak self] in
            let source = await lookup(instance)
            guard !Task.isCancelled, let self, self.asset == asset else { return }
            self.startTask = nil
            guard let source else {
                // Offline. The status bar already names the volume, and the thumbnail stays.
                self.problem = nil
                self.onChange?()
                return
            }
            guard let engine = self.engines.engine(for: source.fileExtension) else {
                self.problem = "Can't play this format"
                self.onChange?()
                return
            }
            self.attach(engine.makePlayback(for: source))
        }
    }

    private func attach(_ playback: any VideoPlayback) {
        self.playback = playback
        playback.isMuted = isMuted
        playback.volume = volume
        let layer = playback.layer
        layer.isHidden = true
        layer.frame = frame
        if let below, let parent = below.superlayer {
            parent.insertSublayer(layer, above: below)
        }
        playback.onChange = { [weak self] in self?.playbackChanged() }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        hideTask?.cancel()
        if let playback {
            if playback.status == .ready { lastTime = playback.currentTime }
            playback.close()
            playback.layer.removeFromSuperlayer()
        }
        playback = nil
        asset = nil
        problem = nil
        startsAt = nil
        autoplays = false
        clickUndo = nil
        preview.hide()
        setControlsVisible(false, animated: false)
    }

    private func playbackChanged() {
        guard let playback else { return }
        switch playback.status {
        case .loading:
            break
        case .ready:
            problem = nil
            if let startsAt {
                self.startsAt = nil
                playback.seek(to: startsAt, exact: true)
            }
            if autoplays {
                autoplays = false
                playback.play(rate: speed)
            }
            lastTime = playback.currentTime
            if !controlsVisible, !playback.layer.isHidden || playback.isShowingFrame { revealControls() }
        case .unavailable:
            problem = nil
        case .unsupported:
            problem = "Can't play this video"
        }
        let showsLayer = playback.status == .ready && playback.isShowingFrame
        if playback.layer.isHidden == showsLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playback.layer.isHidden = !showsLayer
            CATransaction.commit()
        }
        if playback.status != .ready { setControlsVisible(false, animated: true) }
        controls.update(
            time: playback.currentTime, duration: playback.duration, rate: playback.rate, speed: speed,
            isMuted: playback.isMuted, volume: volume)
        onChange?()
    }

    // MARK: Placing

    /// Where the picture is. The player keeps the video's aspect inside it.
    func place(frame: CGRect) {
        self.frame = frame
        guard let layer = playback?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        CATransaction.commit()
    }

    func layoutControls(in bounds: CGRect) {
        let width = min(bounds.width - 40, 760)
        controls.frame = CGRect(
            x: (bounds.width - width) / 2, y: bounds.height - VideoControlsView.height - 20, width: max(0, width),
            height: VideoControlsView.height)
    }

    // MARK: Commands

    /// Space and the play button. At the end, it starts again.
    func togglePlay() {
        guard let playback, playback.status == .ready else { return }
        if playback.rate != 0 {
            playback.pause()
            setControlsVisible(true, animated: true)
        } else {
            playback.play(rate: speed)
            scheduleHide()
        }
    }

    /// A click on the video. It acts at once, rather than waiting out the double-click interval, and
    /// remembers enough for `undoClick` to put it back.
    func click() {
        guard let playback, playback.status == .ready else { return }
        clickUndo = (playback.currentTime, playback.rate != 0)
        togglePlay()
    }

    /// The second click of a double click: back to playing or paused, at the exact time of the first,
    /// so a double click leaves no trace but the moment it played or paused.
    func undoClick() {
        guard let undo = clickUndo, let playback, playback.status == .ready else { return }
        clickUndo = nil
        if undo.wasPlaying {
            playback.play(rate: speed)
            scheduleHide()
        } else {
            playback.pause()
            setControlsVisible(true, animated: true)
        }
        playback.seek(to: undo.time, exact: true)
    }

    /// The speed menu, and `=`. Applies at once to a video playing forward.
    func setSpeed(_ speed: Float) {
        self.speed = speed
        if let playback, playback.status == .ready, playback.rate > 0 { playback.play(rate: speed) }
        playbackChanged()
        revealControls()
    }

    /// `[` and `]`: the next speed down or up the menu's list.
    func stepSpeed(faster: Bool) {
        let speeds = Self.speeds
        let next = faster ? speeds.first { $0 > speed } : speeds.last { $0 < speed }
        guard let next else { return }
        setSpeed(next)
    }

    /// J and L. Each press in the same direction doubles the speed, up to 8×, as in editing apps.
    func shuttle(forward: Bool) {
        guard let playback, playback.status == .ready else { return }
        let rate = playback.rate
        if forward {
            playback.play(rate: rate > 0 ? min(rate * 2, Self.fastestRate) : 1)
        } else {
            guard playback.canPlayBackward else { return }
            playback.play(rate: rate < 0 ? max(rate * 2, -Self.fastestRate) : -1)
        }
        revealControls()
    }

    /// K.
    func pause() {
        playback?.pause()
        setControlsVisible(playback?.status == .ready, animated: true)
    }

    /// Shift-Left and Shift-Right.
    func seek(by seconds: Double) {
        guard let playback, playback.status == .ready else { return }
        playback.seek(to: playback.currentTime + seconds, exact: true)
        revealControls()
    }

    /// Option-Left and Option-Right.
    func step(frames: Int) {
        guard let playback, playback.status == .ready else { return }
        playback.step(frames: frames)
        setControlsVisible(true, animated: true)
    }

    /// M and the speaker. Unmuting a volume dragged to nothing brings it back to full.
    func toggleMute() {
        isMuted.toggle()
        if !isMuted, volume == 0 { volume = 1 }
        playback?.isMuted = isMuted
        playback?.volume = volume
        playbackChanged()
        revealControls()
    }

    /// The volume slider. Dragging to nothing mutes, and up from there unmutes.
    func setVolume(_ level: Float) {
        volume = min(max(level, 0), 1)
        isMuted = volume == 0
        playback?.volume = volume
        playback?.isMuted = isMuted
        playbackChanged()
        revealControls()
    }

    // MARK: Scrubbing

    private func scrub(to seconds: Double, isFinal: Bool) {
        guard let playback, playback.status == .ready else { return }
        if !isFinal, playback.rate != 0 {
            wasPlayingBeforeScrub = true
            playback.pause()
        }
        // Keyframes while dragging, so it keeps up. The exact frame when the button comes up.
        playback.seek(to: seconds, exact: isFinal)
        if isFinal {
            if wasPlayingBeforeScrub { playback.play(rate: speed) }
            wasPlayingBeforeScrub = false
            scheduleHide()
        }
    }

    private func hover(_ hover: (seconds: Double, x: CGFloat)?) {
        guard let hover, let playback, playback.status == .ready, let view else {
            preview.hide()
            return
        }
        let size = preview.size
        let x = controls.frame.minX + hover.x
        let bounds = view.bounds
        let origin = CGPoint(
            x: min(max(x - size.width / 2, 8), bounds.width - size.width - 8),
            y: controls.frame.minY - size.height - 10)
        preview.frame = CGRect(origin: origin, size: size)
        preview.show(image: nil, seconds: hover.seconds)
        let scale = view.window?.backingScaleFactor ?? 2
        playback.previewFrame(at: hover.seconds, maxPixelSize: Int(ScrubPreviewView.width * scale)) {
            [weak self] image, seconds in
            guard let self, !self.preview.isHidden else { return }
            self.preview.show(image: image, seconds: seconds)
        }
    }

    // MARK: The bar

    /// The pointer moved over the viewer.
    func pointerMoved() {
        guard playback?.status == .ready else { return }
        revealControls()
    }

    private func revealControls() {
        setControlsVisible(true, animated: true)
        scheduleHide()
    }

    /// The bar goes after a moment while playing, and stays while paused or in use.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled, let self else { return }
            guard self.isPlaying, !self.controls.isInUse, !self.isPointerOverControls else { return }
            self.setControlsVisible(false, animated: true)
            self.preview.hide()
        }
    }

    private var isPointerOverControls: Bool {
        guard let window = controls.window else { return false }
        let point = controls.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controls.bounds.contains(point)
    }

    private func setControlsVisible(_ visible: Bool, animated: Bool) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        if visible { controls.isHidden = false }
        guard animated else {
            controls.alphaValue = visible ? 1 : 0
            controls.isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            controls.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.controlsVisible else { return }
                self.controls.isHidden = true
            }
        }
    }

    var areControlsVisibleForTesting: Bool { controlsVisible }
}
