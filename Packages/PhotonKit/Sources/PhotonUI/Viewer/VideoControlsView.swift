import AppKit

/// The transport bar over a playing video: play and pause, the time, a scrubber and mute, on Liquid
/// Glass. None of it takes focus, so the viewer keeps the keyboard, and every control has a key.
@MainActor
final class VideoControlsView: NSView {
    private let glass = NSGlassEffectView()
    private let playButton = NSButton()
    private let muteButton = NSButton()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let remaining = NSTextField(labelWithString: "-0:00")
    let scrubber = ScrubberSlider()

    var onPlayPause: (() -> Void)?
    var onMute: (() -> Void)?
    /// A position chosen on the scrubber, in seconds. `isFinal` when the button comes up.
    var onScrub: ((Double, _ isFinal: Bool) -> Void)?
    /// Where the pointer or the knob is over the scrubber, in seconds and in this view's coordinates.
    /// Nil when it has left.
    var onHover: ((Double, CGFloat)?) -> Void = { _ in }

    private var duration: Double = 0
    static let height: CGFloat = 44

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = Self.height / 2
        let content = NSView()
        glass.contentView = content
        addSubview(glass)

        configure(playButton, symbol: "play.fill", label: "Play")
        playButton.action = #selector(playPause)
        configure(muteButton, symbol: "speaker.wave.2.fill", label: "Mute")
        muteButton.action = #selector(mute)
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

        let stack = NSStackView(views: [playButton, elapsed, scrubber, remaining, muteButton])
        stack.orientation = .horizontal
        stack.spacing = 8
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

    private func configure(_ button: NSButton, symbol: String, label: String) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.contentTintColor = .labelColor
        button.refusesFirstResponder = true
        button.target = self
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    func update(time: Double, duration: Double, isPlaying: Bool, isMuted: Bool) {
        self.duration = duration
        if !scrubber.isTracking { scrubber.doubleValue = duration > 0 ? time / duration : 0 }
        let shown = scrubber.isTracking ? scrubber.doubleValue * duration : time
        let elapsedText = TileArtwork.format(Int(shown.rounded(.down)))
        if elapsed.stringValue != elapsedText { elapsed.stringValue = elapsedText }
        let remainingText = "-" + TileArtwork.format(Int(max(0, duration - shown).rounded(.up)))
        if remaining.stringValue != remainingText { remaining.stringValue = remainingText }
        scrubber.setAccessibilityValue("\(elapsedText) of \(TileArtwork.format(Int(duration.rounded())))")

        let play = isPlaying ? "pause.fill" : "play.fill"
        if playButton.accessibilityLabel() != (isPlaying ? "Pause" : "Play") {
            playButton.image = NSImage(systemSymbolName: play, accessibilityDescription: isPlaying ? "Pause" : "Play")
            playButton.setAccessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        let speaker = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        if muteButton.accessibilityLabel() != (isMuted ? "Unmute" : "Mute") {
            muteButton.image = NSImage(systemSymbolName: speaker, accessibilityDescription: isMuted ? "Unmute" : "Mute")
            muteButton.setAccessibilityLabel(isMuted ? "Unmute" : "Mute")
        }
    }

    /// Whether a scrub or a click is under way, so that the bar stays up.
    var isInUse: Bool { scrubber.isTracking }

    @objc private func playPause() { onPlayPause?() }
    @objc private func mute() { onMute?() }

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

/// A slider that also says where the pointer is over it, for scrub previews.
@MainActor
final class ScrubberSlider: NSSlider {
    var onHover: ((Double?) -> Void)?
    /// The button came up after a click or a drag.
    var onEnd: (() -> Void)?
    private(set) var isTracking = false
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

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        // NSSlider tracks until the button comes up, and returns then.
        super.mouseDown(with: event)
        isTracking = false
        onEnd?()
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
