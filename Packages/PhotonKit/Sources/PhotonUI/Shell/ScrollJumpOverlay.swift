import AppKit

/// Over the grid and list: buttons that scroll to the top or bottom, which appear while scrolling a
/// long view, and a Back pill that returns to where the last jump left from. Clicks anywhere else pass
/// through to the content.
@MainActor
final class ScrollJumpOverlay: NSView {
    private let jumpGlass = NSGlassEffectView()
    private let topButton = NSButton()
    private let bottomButton = NSButton()
    private let backGlass = NSGlassEffectView()
    private let backButton = NSButton()

    var onJump: ((_ bottom: Bool) -> Void)?
    var onBack: (() -> Void)?
    /// Back timed out without a click.
    var onBackExpired: (() -> Void)?

    private var jumpVisible = false
    private var backVisible = false
    private var hideJumpTask: Task<Void, Never>?
    private var expireBackTask: Task<Void, Never>?

    /// A view must be this many screens tall before the buttons are worth showing.
    static let minimumScreens: CGFloat = 3
    static let jumpHideDelay: Duration = .seconds(1.5)
    static let backDuration: Duration = .seconds(6)
    private static let jumpSize = CGSize(width: 36, height: 72)
    private static let backSize = CGSize(width: 96, height: 32)

    override init(frame: NSRect) {
        super.init(frame: frame)
        jumpGlass.cornerRadius = Self.jumpSize.width / 2
        let jumpContent = NSView()
        jumpGlass.contentView = jumpContent
        configure(topButton, symbol: "chevron.up.to.line", label: "Scroll to Top", action: #selector(jumpTop))
        configure(bottomButton, symbol: "chevron.down.to.line", label: "Scroll to Bottom", action: #selector(jumpBottom))
        let stack = NSStackView(views: [topButton, bottomButton])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        jumpContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: jumpContent.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: jumpContent.centerYAnchor),
        ])
        jumpGlass.alphaValue = 0
        jumpGlass.isHidden = true
        jumpGlass.setAccessibilityElement(true)
        jumpGlass.setAccessibilityRole(.group)
        jumpGlass.setAccessibilityLabel("Scroll")
        addSubview(jumpGlass)

        backGlass.cornerRadius = Self.backSize.height / 2
        backButton.isBordered = false
        backButton.bezelStyle = .regularSquare
        backButton.title = "Back"
        backButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.imageHugsTitle = true
        backButton.contentTintColor = .labelColor
        backButton.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        backButton.refusesFirstResponder = true
        backButton.target = self
        backButton.action = #selector(back)
        backButton.setAccessibilityLabel("Back to Where You Were")
        backButton.toolTip = "Back to where you were"
        backButton.setAccessibilityIdentifier("photon.jump.back")
        backGlass.contentView = backButton
        backGlass.alphaValue = 0
        backGlass.isHidden = true
        addSubview(backGlass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        button.contentTintColor = .labelColor
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.toolTip = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// Only the controls take clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Clear of the scroller, and of the status bar below.
        let jump = Self.jumpSize
        jumpGlass.frame = CGRect(
            x: bounds.width - jump.width - 24, y: bounds.height - jump.height - 16, width: jump.width,
            height: jump.height)
        let back = Self.backSize
        backGlass.frame = CGRect(
            x: (bounds.width - back.width) / 2, y: bounds.height - back.height - 16, width: back.width,
            height: back.height)
    }

    // MARK: Jump buttons

    /// The content scrolled. `top` and `height` are the visible part, and `content` the whole height.
    func scrolled(top: CGFloat, height: CGFloat, content: CGFloat) {
        guard height > 0, content > height * Self.minimumScreens else {
            setJumpVisible(false)
            return
        }
        topButton.isEnabled = top > 1
        bottomButton.isEnabled = top + height < content - 1
        setJumpVisible(true)
        hideJumpTask?.cancel()
        hideJumpTask = Task { [weak self] in
            try? await Task.sleep(for: Self.jumpHideDelay)
            guard !Task.isCancelled else { return }
            self?.hideJumpUnlessPointed()
        }
    }

    private func hideJumpUnlessPointed() {
        if isPointer(over: jumpGlass) {
            // Checked again a moment later, so it goes once the pointer leaves.
            hideJumpTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.hideJumpUnlessPointed()
            }
            return
        }
        setJumpVisible(false)
    }

    func hideAll() {
        hideJumpTask?.cancel()
        setJumpVisible(false)
        setBackVisible(false)
    }

    private func setJumpVisible(_ visible: Bool) {
        guard visible != jumpVisible else { return }
        jumpVisible = visible
        fade(jumpGlass, visible: visible)
    }

    @objc private func jumpTop() { onJump?(false) }
    @objc private func jumpBottom() { onJump?(true) }

    // MARK: Back

    func showBack(_ visible: Bool) {
        expireBackTask?.cancel()
        setBackVisible(visible)
        guard visible else { return }
        expireBackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.backDuration)
            guard !Task.isCancelled else { return }
            self?.expireBack()
        }
    }

    private func expireBack() {
        if isPointer(over: backGlass) {
            expireBackTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.expireBack()
            }
            return
        }
        setBackVisible(false)
        onBackExpired?()
    }

    private func setBackVisible(_ visible: Bool) {
        guard visible != backVisible else { return }
        backVisible = visible
        fade(backGlass, visible: visible)
    }

    @objc private func back() { onBack?() }

    var isBackVisibleForTesting: Bool { backVisible }
    var isJumpVisibleForTesting: Bool { jumpVisible }

    // MARK: Helpers

    private func isPointer(over view: NSView) -> Bool {
        guard let window, !view.isHidden else { return false }
        return view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func fade(_ view: NSView, visible: Bool) {
        if visible { view.isHidden = false }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.2
            view.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak view] in
            MainActor.assumeIsolated {
                // Shown again meanwhile, its target is 1.
                if let view, view.alphaValue == 0 { view.isHidden = true }
            }
        }
    }
}
