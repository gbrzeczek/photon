import AppKit

// grid-spike --backend collection|layer --layout square|justified --count 200000 --out results.jsonl
//            [--scenarios scroll,fastscroll,zoom,zoomsmall,arrows,arrowstress] [--shot path.png]

func option(_ name: String, _ fallback: String) -> String {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

/// One scripted run: a step per frame for a fixed time.
struct Scenario {
    var name: String
    var seconds: Double
    var skipDecoding = false
    var setup: @MainActor (GridState) -> Void = { _ in }
    var step: @MainActor (GridState, Double, Double) -> Void  // state, elapsed, frame delta
}

@MainActor final class Driver: NSObject {
    let state: GridState
    let backend: GridBackend
    let window: NSWindow
    let recorder = FrameRecorder()
    let backendName: String
    let scenarios: [Scenario]
    let outPath: String
    var scenarioIndex = -1
    var started: CFTimeInterval = 0
    var previous: CFTimeInterval = 0
    var thumbsAtStart = 0
    var maxVisible = 0
    var maxDrift = (x: CGFloat(0), y: CGFloat(0))
    var link: CADisplayLink?
    var keysSent = 0

    init(state: GridState, backend: GridBackend, window: NSWindow, name: String, scenarios: [Scenario], out: String) {
        self.state = state
        self.backend = backend
        self.window = window
        backendName = name
        self.scenarios = scenarios
        outPath = out
    }

    func start() {
        let view = window.contentView!
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [recorder] _, _ in
            recorder.idle()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        next(at: 0)
    }

    func next(at time: CFTimeInterval) {
        if scenarioIndex >= 0 { finishScenario(at: time) }
        scenarioIndex += 1
        guard scenarioIndex < scenarios.count else { exit(0) }
        let scenario = scenarios[scenarioIndex]
        state.skipDecoding = scenario.skipDecoding
        scenario.setup(state)
        recorder.reset()
        started = 0
        thumbsAtStart = state.delivered
        maxVisible = 0
        maxDrift = (0, 0)
        keysSent = 0
    }

    func finishScenario(at time: CFTimeInterval) {
        let scenario = scenarios[scenarioIndex]
        var note: String?
        if scenario.name.hasPrefix("zoom") {
            note = String(format: "anchor drift max x %.1f y %.3f pt, justified pass %.3f ms", maxDrift.x, maxDrift.y, state.geometry.lastPassSeconds * 1000)
        }
        if scenario.name.hasPrefix("arrow") { note = "keys \(keysSent), current \(state.current)" }
        let summary = recorder.summarize(
            backend: backendName, layout: state.geometry.mode.rawValue, scenario: scenario.name,
            seconds: time - started, thumbs: state.delivered - thumbsAtStart, maxVisible: maxVisible, note: note)
        emit(summary)
        let shot = option("shot", "")
        if option("a11y", "no") == "yes" {
            let host = (backend as? LayerGrid)?.host as NSView? ?? (backend as? CollectionGrid)?.collection
            let t = Date()
            let children = host?.accessibilityChildren() ?? []
            print("a11y: role \(host?.accessibilityRole()?.rawValue ?? "nil"), \(children.count) children in \(String(format: "%.2f", Date().timeIntervalSince(t) * 1000)) ms, first: \((children.first as? NSAccessibilityElement)?.accessibilityLabel() ?? String(describing: children.first))")
        }
        if !shot.isEmpty { saveShot("\(shot)-\(backendName)-\(state.geometry.mode.rawValue)-\(scenario.name).png") }
    }

    func emit(_ summary: Summary) {
        let line = String(format: "%-10@ %-9@ %-11@ %6.1f fps of %.0f  missed %-4d gap %6.1f ms  main p50 %5.2f p95 %5.2f p99 %5.2f max %6.2f ms  tiles %-4d thumbs %-5d %5.0f MB %@",
            summary.backend as NSString, summary.layout as NSString, summary.scenario as NSString, summary.fps, summary.nominalHz, summary.missedFrames, summary.longestGapMs,
            summary.mainP50Ms, summary.mainP95Ms, summary.mainP99Ms, summary.mainMaxMs, summary.maxVisibleTiles, summary.thumbsApplied, summary.footprintMB, (summary.note ?? "") as NSString)
        print(line)
        if let data = try? JSONEncoder().encode(summary), let handle = FileHandle(forWritingAtPath: outPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data("\n".utf8))
            handle.closeFile()
        }
    }

    func saveShot(_ path: String) {
        guard let view = window.contentView, let root = view.layer else { return }
        let scale = 1
        let w = Int(view.bounds.width) * scale, h = Int(view.bounds.height) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        root.render(in: ctx)
        guard let image = ctx.makeImage(), let rep = Optional(NSBitmapImageRep(cgImage: image)), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    @objc func tick(_ link: CADisplayLink) {
        if started == 0 {
            started = link.timestamp
            previous = link.timestamp
        }
        recorder.tick(timestamp: link.timestamp, target: link.targetTimestamp)
        let scenario = scenarios[scenarioIndex]
        let elapsed = link.timestamp - started
        if elapsed >= scenario.seconds {
            next(at: link.timestamp)
            return
        }
        scenario.step(state, elapsed, link.timestamp - previous)
        previous = link.timestamp
        state.drainDecoded()
        maxVisible = max(maxVisible, backend.visibleTileCount)
    }

    /// The same path a held key takes: an NSEvent through the window to the first responder.
    func sendKey(_ code: UInt16) {
        keysSent += 1
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: true, keyCode: code)!
        window.sendEvent(event)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let count = Int(option("count", "200000"))!
let backendName = option("backend", "layer")
let layoutName = option("layout", "square")
let out = option("out", "/dev/stdout")
if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }

let setupStart = Date()
let formatName = option("format", "device")
let state = GridState(count: count, mode: Geometry.Mode(rawValue: layoutName)!, format: ThumbFormat(rawValue: formatName)!)
let modelSeconds = Date().timeIntervalSince(setupStart)

let screen = NSScreen.main!.visibleFrame
let window = NSWindow(contentRect: CGRect(x: screen.minX, y: screen.minY, width: min(1500, screen.width), height: min(950, screen.height)), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.level = .floating
window.contentView = NSView()
window.contentView!.wantsLayer = true
window.backgroundColor = .windowBackgroundColor

let backend: GridBackend = backendName == "collection" ? CollectionGrid(state: state) : LayerGrid(state: state)
state.backend = backend
if let grid = backend as? CollectionGrid, option("tight", "no") == "yes" { grid.collection.tightPrepare = true }
let content = window.contentView!
backend.scrollView.frame = content.bounds
backend.scrollView.autoresizingMask = [.width, .height]
content.addSubview(backend.scrollView)

let loadStart = Date()
state.geometry.update(width: content.bounds.width - 16, tile: 160)
backend.reload()
window.makeKeyAndOrderFront(nil)
app.activate()
window.makeFirstResponder(backend.keyView)
content.layoutSubtreeIfNeeded()
print(String(format: "setup: model %.0f ms, first layout %.0f ms, %.0f MB, screen %@ max %d Hz",
    modelSeconds * 1000, Date().timeIntervalSince(loadStart) * 1000, footprintMB(), NSScreen.main!.localizedName, NSScreen.main!.maximumFramesPerSecond))

// Start mid-library, so nothing benefits from being near the top.
let middle = state.geometry.frame(of: count / 2).minY

var scenarios: [Scenario] = [
    Scenario(name: "scroll", seconds: 5, setup: { $0.geometry.update(width: $0.geometry.width, tile: 160); $0.backend?.relayout(); $0.scroll(to: middle) }) { s, _, dt in
        s.scroll(to: s.offset + 4000 * dt)
    },
    Scenario(name: "fastscroll", seconds: 4, skipDecoding: true) { s, _, dt in
        s.scroll(to: s.offset + 120_000 * dt)
    },
    Scenario(name: "zoom", seconds: 6, setup: { $0.scroll(to: middle / 2) }) { s, t, _ in
        let size = 232 + 168 * sin(t * 2 * .pi / 3)
        let d = s.zoom(to: size, anchoredAt: CGPoint(x: 700, y: 400))
        driver.maxDrift = (max(driver.maxDrift.x, abs(d.x)), max(driver.maxDrift.y, abs(d.y)))
    },
    // Layout alone: no decoding queued and no backlog, the fairest view of each backend's zoom.
    Scenario(name: "zoombare", seconds: 6, skipDecoding: true, setup: { $0.scroll(to: middle / 2) }) { s, t, _ in
        let size = 232 + 168 * sin(t * 2 * .pi / 3)
        s.zoom(to: size, anchoredAt: CGPoint(x: 700, y: 400))
    },
    Scenario(name: "zoombaresmall", seconds: 5, skipDecoding: true) { s, t, _ in
        let size = 96 + 32 * sin(t * 2 * .pi / 2)
        s.zoom(to: size, anchoredAt: CGPoint(x: 700, y: 400))
    },
    Scenario(name: "zoomsmall", seconds: 5) { s, t, _ in
        let size = 96 + 32 * sin(t * 2 * .pi / 2)
        let d = s.zoom(to: size, anchoredAt: CGPoint(x: 700, y: 400))
        driver.maxDrift = (max(driver.maxDrift.x, abs(d.x)), max(driver.maxDrift.y, abs(d.y)))
    },
    Scenario(name: "arrows", seconds: 5, setup: { s in
        s.geometry.update(width: s.geometry.width, tile: 160); s.backend?.relayout()
        s.scroll(to: middle / 3)
        let old = s.current
        s.current = s.geometry.index(at: CGPoint(x: 10, y: s.offset + 200))
        s.backend?.currentChanged(from: old, to: s.current)
    }) { _, t, _ in
        // macOS's fastest key repeat setting is about 30 per second.
        while Double(driver.keysSent) < t * 30 { driver.sendKey(125) }
    },
    Scenario(name: "arrowstress", seconds: 3) { _, t, _ in
        // Far beyond a real key repeat, to find the point where it stops keeping up.
        while Double(driver.keysSent) < t * 240 { driver.sendKey(driver.keysSent % 2 == 0 ? 125 : 124) }
    },
]
let wanted = option("scenarios", "").split(separator: ",").map(String.init)
if !wanted.isEmpty { scenarios = scenarios.filter { wanted.contains($0.name) } }

let driver = Driver(state: state, backend: backend, window: window, name: backendName, scenarios: scenarios, out: out)
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { driver.start() }

// A safety net, so that a stalled display link can't leave a floating window on screen.
DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
    print("timed out")
    exit(4)
}
app.run()
