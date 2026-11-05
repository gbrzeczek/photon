import AppKit
import Foundation

/// Options shared by both paths. ao=null keeps clips silent on the user's machine.
/// MPV_SPIKE_AO=coreaudio exercises the real audio stack, muted.
func commonOptions(hwdec: String) -> [(String, String)] {
    let ao = ProcessInfo.processInfo.environment["MPV_SPIKE_AO"] ?? "null"
    var extra: [(String, String)] = []
    if let e = ProcessInfo.processInfo.environment["MPV_SPIKE_EXTRA"] {
        for kv in e.split(separator: ",") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { extra.append((p[0], p[1])) }
        }
    }
    // MPV_SPIKE_AO=default leaves ao unset, which is mpv's own probing order.
    if ao != "default" { extra.append(("ao", ao)) }
    return extra + [("hwdec", hwdec), ("volume", ao == "null" ? "100" : "0"), ("idle", "yes"), ("keep-open", "yes"),
     ("terminal", "no"), ("config", "no"), ("input-default-bindings", "no"),
     ("input-vo-keyboard", "no"), ("osc", "no"), ("load-scripts", "no"),
     ("ytdl", "no")]
}

@MainActor protocol Surface: AnyObject {
    var core: MpvCore { get }
    var hostView: HostView { get }
    var extra: [String: Any] { get }
    /// Reads back pixels at the surface level, if the path allows it.
    func captureRendered(to url: URL) async -> [String: Any]?
    func teardown() async
}

@MainActor final class HostView: NSView {
    var onResize: ((CGSize, CGFloat) -> Void)?
    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        onResize?(bounds.size, window?.backingScaleFactor ?? 2)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize?(bounds.size, window?.backingScaleFactor ?? 2)
    }
}

/// Holds playback back while the sibling session's frame-timing lock file exists.
struct LockGate {
    let path: String?
    var isLocked: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
