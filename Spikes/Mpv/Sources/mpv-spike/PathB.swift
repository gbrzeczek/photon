import AppKit
import Libmpv
import QuartzCore

/// mpv's own Cocoa VO carries this guard: MoltenVK may set a 1x1 drawableSize to force a present.
/// The hit count tells us whether the guard is doing anything.
final class MoltenLayer: CAMetalLayer, @unchecked Sendable {
    nonisolated(unsafe) var guardHits = 0
    nonisolated(unsafe) var guardEnabled = true
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if guardEnabled, newValue.width <= 1 || newValue.height <= 1 {
                guardHits += 1
                return
            }
            super.drawableSize = newValue
        }
    }
}

/// How a mid-play size change reaches mpv. MPVKit's moltenvk context only reads drawableSize in
/// reconfig, and its control hook is VO_NOTIMPL, so plain resizing leaves mpv at the old size.
enum ResizeMode: String, Sendable { case none, nudge, transform }

/// Path B: wid = CAMetalLayer pointer, vo=gpu-next, gpu-api=vulkan, gpu-context=moltenvk.
@MainActor final class PathBSurface: Surface {
    let core: MpvCore
    let hostView = HostView()
    private let root = CALayer()
    private let metalLayer = MoltenLayer()
    private let mode: ResizeMode
    private var baseSize: CGSize?
    private var flip = false

    init(logURL: URL?, logLevel: String, hwdec: String, sizeGuard: Bool, mode: ResizeMode) throws {
        self.mode = mode
        metalLayer.guardEnabled = sizeGuard
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        root.backgroundColor = NSColor.black.cgColor
        root.addSublayer(metalLayer)
        hostView.layer = root
        hostView.wantsLayer = true
        let wid = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        core = try MpvCore(
            options: commonOptions(hwdec: hwdec) + [
                ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ],
            wid: wid, logURL: logURL, logLevel: logLevel)
        hostView.onResize = { [weak self] size, scale in self?.resized(size, scale) }
    }

    private func resized(_ size: CGSize, _ scale: CGFloat) {
        guard size.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        metalLayer.contentsScale = scale
        if mode == .transform {
            // mpv keeps its fixed size, and Core Animation scales the result.
            if let base = baseSize {
                metalLayer.setAffineTransform(CGAffineTransform(scaleX: size.width / base.width, y: size.height / base.height))
            } else {
                baseSize = size
                metalLayer.anchorPoint = .zero
                metalLayer.bounds = CGRect(origin: .zero, size: size)
                metalLayer.position = .zero
                metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
            }
            return
        }
        metalLayer.frame = CGRect(origin: .zero, size: size)
        metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        if mode == .nudge {
            // Forces a VO reconfig, the only time this context rereads drawableSize.
            flip.toggle()
            // 1.7770 and 1.7787 differ by one display pixel at 1080p. Smaller values round to the same size.
            let value = flip ? "1.7787" : "1.7770"
            let core = self.core
            Task.detached { core.set("video-aspect-override", value) }
        }
    }

    var extra: [String: Any] {
        ["guardHits": metalLayer.guardHits, "drawableSize": "\(metalLayer.drawableSize)",
         "pixelFormat": metalLayer.pixelFormat.rawValue, "framebufferOnly": metalLayer.framebufferOnly,
         "resizeMode": mode.rawValue]
    }

    func captureRendered(to url: URL) async -> [String: Any]? { nil }

    func teardown() async {
        await core.destroy()
    }
}

/// Path C: upstream's Cocoa Vulkan context. mpv makes its own sub-view inside the NSView passed as wid.
@MainActor final class PathCSurface: Surface {
    let core: MpvCore
    let hostView = HostView()

    init(logURL: URL?, logLevel: String, hwdec: String) throws {
        hostView.wantsLayer = true
        let wid = Int64(Int(bitPattern: Unmanaged.passUnretained(hostView).toOpaque()))
        core = try MpvCore(
            options: commonOptions(hwdec: hwdec) + [
                ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "macvk"),
            ],
            wid: wid, logURL: logURL, logLevel: logLevel)
    }

    var extra: [String: Any] { ["subviews": hostView.subviews.count, "appWindows": NSApp.windows.count] }
    func captureRendered(to url: URL) async -> [String: Any]? { nil }
    func teardown() async { await core.destroy() }
}
