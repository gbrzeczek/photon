import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Launch-time switches for checking the app from outside, set through the environment:
/// `PHOTON_APPEARANCE` forces light or dark, and `PHOTON_SNAPSHOT` saves the window to a PNG after
/// `PHOTON_SNAPSHOT_DELAY` seconds. A process may capture its own window with no permission.
@MainActor
enum DevelopmentHooks {
    static func applyAppearance() {
        switch ProcessInfo.processInfo.environment["PHOTON_APPEARANCE"] {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func scheduleSnapshot(of view: NSView) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PHOTON_SNAPSHOT"] else { return }
        let delay = environment["PHOTON_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
            guard let window = view?.window else { return }
            save(window: window, to: URL(fileURLWithPath: path))
            if environment["PHOTON_SNAPSHOT_QUIT"] != nil { NSApplication.shared.terminate(nil) }
        }
    }

    private typealias WindowCapture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Looked up at run time, because the SDK has dropped the declaration for ScreenCaptureKit, and
    /// that needs a permission this doesn't.
    private static func save(window: NSWindow, to url: URL) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: WindowCapture.self)
        guard
            let image = capture(.null, 8 /* including window */, UInt32(window.windowNumber), 1 /* ignore framing */)?
                .takeRetainedValue(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
