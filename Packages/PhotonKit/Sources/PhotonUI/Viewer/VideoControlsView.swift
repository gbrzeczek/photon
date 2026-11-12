import AppKit

/// The transport bar over a playing video: play and pause, skipping, the time, a scrubber, speed, volume
/// and full screen, on Liquid Glass. None of it takes focus, so the viewer keeps the keyboard, and every
/// control has a key.
@MainActor
final class VideoControlsView: NSView {
    private let glass = NSGlassEffectView()
    private let playButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let speedButton = NSButton()
    private let fullScreenButton = NSButton()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let remaining = NSTextField(labelWithString: "-0:00")
    let scrubber = ScrubberSlider()
    let volume = VolumeControl()

    var onPlayPause: (() -> Void)?
    /// Seconds to skip, negative for back.
    var onSkip: ((Double) -> Void)?
    var onSpeed: ((Float) -> Void)?
    var onMute: (() -> Void)?
    /// A volume chosen on the slider, from 0 to 1.
    var onVolume: ((Float) -> Void)?
    /// A position chosen on the scrubber, in seconds. `isFinal` when the button comes up.
    var onScrub: ((Double, _ isFinal: Bool) -> Void)?
    /// Where the pointer or the knob is over the scrubber, in seconds and in this view's coordinates.
    /// Nil when it has left.
    var onHover: ((Double, CGFloat)?) -> Void = { _ in }

    private var duration: Double = 0
    private var speed: Float = 1
    private var fullScreenObservers: [any NSObjectProtocol] = []
    static let height: CGFloat = 44
    /// How far the skip buttons go, the same as Shift-Left and Shift-Right.
    static let skipSeconds: Double = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = Self.height / 2
        let content = NSView()
        glass.contentView = content
        addSubview(glass)

        Self.configure(playButton, symbol: "play.fill", label: "Play", target: self)
        playButton.action = #selector(playPause)
        Self.configure(backButton, symbol: "gobackward.5", label: "Back 5 Seconds", target: self)
        backButton.action = #selector(skipBack)
        Self.configure(forwardButton, symbol: "goforward.5", label: "Forward 5 Seconds", target: self)
        forwardButton.action = #selector(skipForward)
        Self.configure(fullScreenButton, symbol: "arrow.up.left.and.arrow.down.right", label: "Enter Full Screen", target: self)
        fullScreenButton.action = #selector(toggleFullScreen)

        speedButton.isBordered = false
        speedButton.bezelStyle = .regularSquare
        speedButton.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        speedButton.contentTintColor = .labelColor
        speedButton.refusesFirstResponder = true
        speedButton.target = self
        speedButton.action = #selector(showSpeeds)
        speedButton.title = Self.format(rate: 1)
        speedButton.setAccessibilityLabel("Playback Speed")
        speedButton.toolTip = "Playback speed"
        speedButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

        volume.muteButton.target = self
        volume.muteButton.action = #selector(mute)
        volume.slider.target = self
        volume.slider.action = #selector(volumeChanged)

        for label in [elapsed, remaining] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.setAccessibilityElement(false)
        }
        scrubber.minValue = 0
        scrubber.maxValue = 1
        scrubber.isContinuous = true
        scrubber.controlSize = .small
        scrubber.refusesFirstResponder = true
        scrubber.target = self
        scrubber.action = #selector(scrubbed)
        scrubber.setAccessibilityLabel("Playback position")
        scrubber.onHover = { [weak self] fraction in self?.hovered(fraction) }
        scrubber.onEnd = { [weak self] in self?.scrubEnded() }

        let stack = NSStackView(views: [
            backButton, playButton, forwardButton, elapsed, scrubber, remaining, speedButton, volume, fullScreenButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(10, after: forwardButton)
        stack.setCustomSpacing(10, after: remaining)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            elapsed.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            remaining.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrubber.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video controls")
        setAccessibilityIdentifier("photon.video.controls")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    override func layout() {
        super.layout()
        glass.frame = bounds
    }

    static func configure(_ button: NSButton, symbol: String, label: String, target: AnyObject) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.contentTintColor = .labelColor
        button.refusesFirstResponder = true
        button.target = target
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    /// `rate` is what's playing, and `speed` what Space plays at, which the button shows unless J or L
    /// chose another.
    func update(time: Double, duration: Double, rate: Float, speed: Float, isMuted: Bool, volume level: Float) {
        self.duration = duration
        self.speed = speed
        if !scrubber.isTracking { scrubber.doubleValue = duration > 0 ? time / duration : 0 }
        let shown = scrubber.isTracking ? scrubber.doubleValue * duration : time
        let elapsedText = TileArtwork.format(Int(shown.rounded(.down)))
        if elapsed.stringValue != elapsedText { elapsed.stringValue = elapsedText }
        let remainingText = "-" + TileArtwork.format(Int(max(0, duration - shown).rounded(.up)))
        if remaining.stringValue != remainingText { remaining.stringValue = remainingText }
        scrubber.setAccessibilityValue("\(elapsedText) of \(TileArtwork.format(Int(duration.rounded())))")

        let isPlaying = rate != 0
        if playButton.accessibilityLabel() != (isPlaying ? "Pause" : "Play") {
            let play = isPlaying ? "pause.fill" : "play.fill"
            playButton.image = NSImage(systemSymbolName: play, accessibilityDescription: isPlaying ? "Pause" : "Play")
            playButton.setAccessibilityLabel(isPlaying ? "Pause" : "Play")
            playButton.toolTip = isPlaying ? "Pause" : "Play"
        }
        let speedText = Self.format(rate: isPlaying ? rate : speed)
        if speedButton.title != speedText {
            speedButton.title = speedText
            speedButton.setAccessibilityValue(speedText)
        }
        self.volume.update(isMuted: isMuted, volume: level)
        updateFullScreen()
    }

    /// 1×, 0.5×, 1.25×, −2×.
    static func format(rate: Float) -> String {
        let magnitude = abs(rate)
        let number = magnitude == magnitude.rounded() ? String(Int(magnitude)) : String(format: "%g", magnitude)
        return (rate < 0 ? "−" : "") + number + "×"
    }

    /// Whether a scrub, a volume drag or a click is under way, so that the bar stays up.
    var isInUse: Bool { scrubber.isTracking || volume.isInUse }

    @objc private func playPause() { onPlayPause?() }
    @objc private func skipBack() { onSkip?(-Self.skipSeconds) }
    @objc private func skipForward() { onSkip?(Self.skipSeconds) }
    @objc private func mute() { onMute?() }
    @objc private func volumeChanged() { onVolume?(Float(volume.slider.doubleValue)) }

    @objc private func showSpeeds() {
        let menu = NSMenu()
        for choice in ViewerVideo.speeds {
            let item = NSMenuItem(title: Self.format(rate: choice), action: #selector(chooseSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice
            item.state = choice == speed ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: speedButton.bounds.height), in: speedButton)
    }

    @objc private func chooseSpeed(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Float else { return }
        onSpeed?(choice)
    }

    // MARK: Full screen

    @objc private func toggleFullScreen() { window?.toggleFullScreen(nil) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
        fullScreenObservers = []
        guard let window else { return }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            fullScreenObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateFullScreen() }
                })
        }
        updateFullScreen()
    }

    private func updateFullScreen() {
        let isFullScreen = window?.styleMask.contains(.fullScreen) == true
        let label = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
        guard fullScreenButton.accessibilityLabel() != label else { return }
        let symbol = isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        fullScreenButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        fullScreenButton.setAccessibilityLabel(label)
        fullScreenButton.toolTip = label
    }

    // MARK: Scrubbing

    /// During a drag, and for VoiceOver's increments, which arrive with no drag and are final at once.
    @objc private func scrubbed() {
        let isFinal = !scrubber.isTracking
        onScrub?(scrubber.doubleValue * duration, isFinal)
        if isFinal {
            onHover(nil)
        } else {
            hovered(scrubber.doubleValue)
        }
    }

    private func scrubEnded() {
        onScrub?(scrubber.doubleValue * duration, true)
        onHover(nil)
    }

    private func hovered(_ fraction: Double?) {
        guard let fraction, duration > 0 else {
            onHover(nil)
            return
        }
        let x = convert(NSPoint(x: scrubber.knobCenterX(fraction: fraction), y: 0), from: scrubber).x
        onHover((fraction * duration, x))
    }
}

/// The speaker, which mutes on a click, and a volume slider that opens beside it while the pointer is
/// over either, as in QuickTime Player.
@MainActor
final class VolumeControl: NSView {
    let muteButton = NSButton()
    let slider = TrackingSlider()
    private var sliderWidth: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var collapseTask: Task<Void, Never>?
    private(set) var isExpanded = false
    private var shownSymbol = "speaker.wave.3.fill"
    static let expandedWidth: CGFloat = 72

    override init(frame: NSRect) {
        super.init(frame: frame)
        VideoControlsView.configure(muteButton, symbol: "speaker.wave.3.fill", label: "Mute", target: self)
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        slider.setAccessibilityLabel("Volume")
        slider.alphaValue = 0
        slider.isHidden = true
        slider.onEnd = { [weak self] in self?.collapseLater() }

        let stack = NSStackView(views: [muteButton, slider])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        sliderWidth = slider.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            sliderWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    var isInUse: Bool { slider.isTracking }

    func update(isMuted: Bool, volume: Float) {
        let level = isMuted ? 0 : volume
        if !slider.isTracking, slider.doubleValue != Double(level) { slider.doubleValue = Double(level) }
        let symbol = switch level {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
        let label = level == 0 ? "Unmute" : "Mute"
        if shownSymbol != symbol {
            shownSymbol = symbol
            muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            muteButton.setAccessibilityLabel(label)
            muteButton.toolTip = label
        }
        slider.setAccessibilityValue("\(Int((level * 100).rounded())) percent")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setExpanded(true) }
    override func mouseExited(with event: NSEvent) { collapseLater() }

    /// After a moment, so that passing between the speaker and the slider doesn't close it.
    private func collapseLater() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, !self.slider.isTracking, !self.isPointerInside else { return }
            self.setExpanded(false)
        }
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func setExpanded(_ expanded: Bool) {
        collapseTask?.cancel()
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if expanded { slider.isHidden = false }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.18
            context.allowsImplicitAnimation = true
            sliderWidth.animator().constant = expanded ? Self.expandedWidth : 0
            slider.animator().alphaValue = expanded ? 1 : 0
            superview?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExpanded else { return }
                self.slider.isHidden = true
            }
        }
    }
}

/// A slider that says when it's being dragged.
@MainActor
class TrackingSlider: NSSlider {
    /// The button came up after a click or a drag.
    var onEnd: (() -> Void)?
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        // NSSlider tracks until the button comes up, and returns then.
        super.mouseDown(with: event)
        isTracking = false
        onEnd?()
    }
}

/// A slider that also says where the pointer is over it, for scrub previews.
@MainActor
final class ScrubberSlider: TrackingSlider {
    var onHover: ((Double?) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isTracking else { return }
        onHover?(fraction(at: convert(event.locationInWindow, from: nil).x))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isTracking else { return }
        onHover?(nil)
    }

    /// The part of the width the knob's center can reach.
    private var travel: (start: CGFloat, length: CGFloat) {
        let inset = (cell as? NSSliderCell)?.knobThickness ?? 12
        return (inset / 2, max(1, bounds.width - inset))
    }

    func fraction(at x: CGFloat) -> Double {
        let travel = travel
        return Double(min(max((x - travel.start) / travel.length, 0), 1))
    }

    func knobCenterX(fraction: Double) -> CGFloat {
        let travel = travel
        return travel.start + CGFloat(fraction) * travel.length
    }
}

/// A frame from where the pointer is on the scrubber, with its time, above the bar.
@MainActor
final class ScrubPreviewView: NSView {
    private let picture = CALayer()
    private let label = NSTextField(labelWithString: "")
    static let width: CGFloat = 160
    private var aspect: CGFloat = 16 / 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        picture.contentsGravity = .resizeAspectFill
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.alignment = .center
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        addSubview(label)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var size: CGSize { CGSize(width: Self.width, height: (Self.width / aspect).rounded()) }

    /// Sets the aspect from the video's own, so the frame isn't cropped.
    func setAspect(_ aspect: CGFloat) {
        guard aspect > 0 else { return }
        self.aspect = min(max(aspect, 0.5), 2.4)
    }

    func show(image: CGImage?, seconds: Double) {
        if let image { picture.contents = image }
        label.stringValue = TileArtwork.format(Int(seconds.rounded(.down)))
        isHidden = false
    }

    func hide() {
        isHidden = true
        picture.contents = nil
    }

    override func layout() {
        super.layout()
        picture.frame = bounds
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
