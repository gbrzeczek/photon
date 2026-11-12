import AppKit

/// A button that says when the pointer comes onto it and leaves.
@MainActor
final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A narrow glass panel that opens above a button in the transport bar, so the bar itself never moves.
/// It stays while the pointer is over it or its button, and closes a moment after it leaves both.
@MainActor
final class BarPopup: NSView {
    private let glass = NSGlassEffectView()
    let size: CGSize
    /// The button it opens above.
    weak var anchor: NSView?
    /// Something in it is being dragged, so it stays.
    var isInUse: () -> Bool = { false }
    /// It closed, by itself or by a choice.
    var onClose: (() -> Void)?
    private(set) var isOpen = false
    private var closeTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?

    static let gap: CGFloat = 8
    static let closeDelay: Duration = .milliseconds(350)

    init(content: NSView, size: CGSize) {
        self.size = size
        super.init(frame: CGRect(origin: .zero, size: size))
        glass.cornerRadius = min(size.width / 2, 18)
        glass.contentView = content
        addSubview(glass)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    override func layout() {
        super.layout()
        glass.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { closeTask?.cancel() }
    override func mouseExited(with event: NSEvent) { closeSoon() }

    /// Opens centered above `anchor`, kept inside the superview, with `barTop` the bar's top edge in
    /// the superview's flipped coordinates.
    func open(barTop: CGFloat) {
        closeTask?.cancel()
        guard let anchor, let superview else { return }
        let anchorFrame = anchor.convert(anchor.bounds, to: superview)
        let x = min(max(anchorFrame.midX - size.width / 2, 8), superview.bounds.width - size.width - 8)
        frame = CGRect(x: x, y: barTop - size.height - Self.gap, width: size.width, height: size.height)
        guard !isOpen else { return }
        isOpen = true
        isHidden = false
        fade(to: 1)
    }

    /// After a moment, unless the pointer has come onto it or its button, or something is dragged.
    func closeSoon() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled, let self else { return }
            if self.isInUse() || self.isPointerInside {
                // Checked again, so it closes once the pointer leaves after a drag.
                self.closeSoon()
                return
            }
            self.close()
        }
    }

    func close() {
        closeTask?.cancel()
        guard isOpen else { return }
        isOpen = false
        fade(to: 0)
        onClose?()
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        let point = window.mouseLocationOutsideOfEventStream
        if bounds.contains(convert(point, from: nil)) { return true }
        guard let anchor else { return false }
        return anchor.bounds.contains(anchor.convert(point, from: nil))
    }

    private func fade(to alpha: CGFloat) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.15
            animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.isHidden = true
            }
        }
    }
}

/// The volume, as a vertical slider: up is louder.
@MainActor
final class VolumePanel: NSView {
    let slider = TrackingSlider()
    /// The slider moved, to a level from 0 to 1.
    var onChange: ((Float) -> Void)?
    static let size = CGSize(width: 36, height: 132)

    override init(frame: NSRect) {
        super.init(frame: frame)
        slider.isVertical = true
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel("Volume")
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        NSLayoutConstraint.activate([
            slider.centerXAnchor.constraint(equalTo: centerXAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    @objc private func moved() { onChange?(Float(slider.doubleValue)) }

    func update(level: Float) {
        if !slider.isTracking, slider.doubleValue != Double(level) { slider.doubleValue = Double(level) }
        slider.setAccessibilityValue("\(Int((level * 100).rounded())) percent")
    }
}

/// The speed, as a vertical slider like the volume's, that snaps to the speeds Space can play at,
/// with the speed it's on written above it.
@MainActor
final class SpeedPanel: NSView {
    let slider = TrackingSlider()
    private let value = NSTextField(labelWithString: "1×")
    /// The slider landed on a speed.
    var onChange: ((Float) -> Void)?
    private var shown: Float = 1
    static let size = CGSize(width: 44, height: 160)
    private static let speeds = ViewerVideo.speeds

    override init(frame: NSRect) {
        super.init(frame: frame)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        value.alignment = .center
        value.setAccessibilityElement(false)
        value.translatesAutoresizingMaskIntoConstraints = false
        addSubview(value)

        slider.isVertical = true
        slider.minValue = 0
        slider.maxValue = Double(Self.speeds.count - 1)
        slider.numberOfTickMarks = Self.speeds.count
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .trailing
        slider.isContinuous = true
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel("Playback Speed")
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        NSLayoutConstraint.activate([
            value.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            value.centerXAnchor.constraint(equalTo: centerXAnchor),
            slider.centerXAnchor.constraint(equalTo: centerXAnchor),
            slider.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 6),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        update(speed: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    private var speedAtSlider: Float {
        Self.speeds[min(max(Int(slider.doubleValue.rounded()), 0), Self.speeds.count - 1)]
    }

    @objc private func moved() {
        let speed = speedAtSlider
        show(speed)
        // Applied as the knob crosses each step, not only when it's let go.
        guard speed != shown else { return }
        shown = speed
        onChange?(speed)
    }

    func update(speed: Float) {
        shown = speed
        if !slider.isTracking, let index = Self.speeds.firstIndex(of: speed) { slider.doubleValue = Double(index) }
        show(slider.isTracking ? speedAtSlider : speed)
    }

    private func show(_ speed: Float) {
        let text = VideoControlsView.format(rate: speed)
        if value.stringValue != text { value.stringValue = text }
        slider.setAccessibilityValue(text)
    }

    func setForTesting(index: Int) {
        slider.doubleValue = Double(index)
        moved()
    }
}
