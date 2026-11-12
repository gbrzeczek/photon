import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Launch-time switches for checking the app from outside, set through the environment:
/// `PHOTON_APPEARANCE` forces light or dark, and `PHOTON_SNAPSHOT` saves the window to a PNG after
/// `PHOTON_SNAPSHOT_DELAY` seconds. A process may capture its own window with no permission.
/// `PHOTON_WINDOW` fills a display, `main` or `builtin`, so that measurements compare like with like, or
/// is `left` for the left half of the main display, leaving room for a window to drop files on.
/// `PHOTON_VIEWER_ROW` opens the viewer on a row after `PHOTON_VIEWER_DELAY` seconds, for looking at it
/// without driving the app, `PHOTON_VIEWER_ZOOM` zooms in that many steps, and
/// `PHOTON_VIEWER_SCROLL` that many wheel notches. `PHOTON_INSPECTOR=<row>` selects that row and shows the
/// inspector, for looking at it the same way. `PHOTON_HOVER_ROW=<row>` rests the pointer on that tile
/// after 2 seconds, so that a video's preview plays in it. `PHOTON_VIDEO_PANEL=volume` or `speed` opens
/// that panel above a video's bar in the viewer, a second after it opens.
@MainActor
enum DevelopmentHooks {
    static func applyAppearance() {
        switch ProcessInfo.processInfo.environment["PHOTON_APPEARANCE"] {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func placeWindow(of view: NSView) {
        guard let choice = ProcessInfo.processInfo.environment["PHOTON_WINDOW"] else { return }
        DispatchQueue.main.async { [weak view] in
            let screen = NSScreen.screens.first { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return choice == "builtin" ? id.map { CGDisplayIsBuiltin($0) != 0 } == true : screen == NSScreen.main
            }
            guard let screen, let window = view?.window else { return }
            var frame = screen.visibleFrame
            if choice == "left" { frame.size.width /= 2 }
            window.setFrame(frame, display: true)
        }
    }

    static func scheduleViewer(model: BrowserModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let row = environment["PHOTON_VIEWER_ROW"].flatMap(Int.init) else { return }
        let delay = environment["PHOTON_VIEWER_DELAY"].flatMap(Double.init) ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            model.setViewMode(environment["PHOTON_VIEWER_LIST"] != nil ? .list : .tiles)
            model.select(row: row)
            model.openViewer()
            for step in 0..<(environment["PHOTON_VIEWER_ZOOM"].flatMap(Int.init) ?? 0) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 0.2 * Double(step)) {
                    model.stepZoom(larger: true)
                }
            }
            if let panel = environment["PHOTON_VIDEO_PANEL"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let video = model.viewer?.video else { return }
                    video.pointerMoved()
                    let button = panel == "speed" ? video.controls.speedButton : video.controls.muteButton
                    button.onHover?(true)
                }
            }
            for step in 0..<(environment["PHOTON_VIEWER_SCROLL"].flatMap(Int.init) ?? 0) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 0.05 * Double(step)) {
                    model.viewer?.scrollForMeasuring(factor: 1.3)
                }
            }
        }
    }

    static func scheduleInspector(model: BrowserModel) {
        guard let row = ProcessInfo.processInfo.environment["PHOTON_INSPECTOR"].flatMap(Int.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak model] in
            guard let model, row < model.itemCount else { return }
            model.select(row: row)
            if !model.isInspectorShown { model.toggleInspector() }
        }
    }

    static func scheduleHover(grid: TileGridView) {
        guard let row = ProcessInfo.processInfo.environment["PHOTON_HOVER_ROW"].flatMap(Int.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak grid] in grid?.hover(row: row) }
    }

    static func scheduleSnapshot(of view: NSView) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PHOTON_SNAPSHOT"] else { return }
        let delay = environment["PHOTON_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
            guard let window = view?.window else { return }
            save(window: window, to: URL(fileURLWithPath: path))
            // Above 1 means the display is showing extended range now, which no screenshot can show.
            let headroom = window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0
            print("EDR headroom in use: \(headroom), scale \(window.backingScaleFactor)")
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
