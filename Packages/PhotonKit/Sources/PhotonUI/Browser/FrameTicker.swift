import AppKit
import QuartzCore

/// Calls back once per display frame, and only while there's work.
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private let tick: @MainActor (TimeInterval) -> Bool

    /// - Parameter tick: Returns whether more frames are needed.
    init(tick: @escaping @MainActor (TimeInterval) -> Bool) {
        self.tick = tick
    }

    /// Starts ticking on the display that shows `view`.
    func start(in view: NSView) {
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(fired))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    /// A new window means a display link of that window's.
    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func fired(_ link: CADisplayLink) {
        if !tick(link.targetTimestamp) { link.isPaused = true }
    }
}
