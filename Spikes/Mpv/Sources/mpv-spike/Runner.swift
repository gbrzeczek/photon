import AppKit
import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libmpv

private let statKeys = [
    "video-codec", "video-format", "hwdec", "hwdec-current", "estimated-vf-fps", "container-fps",
    "frame-drop-count", "decoder-frame-drop-count", "vo-delayed-frame-count", "mistimed-frame-count",
    "display-fps", "estimated-display-fps", "avsync", "width", "height", "current-vo",
    "video-params/pixelformat", "video-params/hw-pixelformat", "osd-dimensions/w", "osd-dimensions/h",
    "time-pos", "duration",
]

private struct LockInterrupt: Error {}

/// A main-thread timer. The largest gap between firings shows how long the UI thread stalled.
@MainActor final class StallMeter {
    private var last = CACurrentMediaTime()
    private(set) var worstMs = 0.0
    private var timer: Timer?
    func start() {
        timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func tick() {
        let now = CACurrentMediaTime()
        worstMs = max(worstMs, (now - last) * 1000)
        last = now
    }
    func take() -> Double {
        tick()
        defer { worstMs = 0 }
        return worstMs
    }
}

@MainActor final class Runner {
    let cfg: Config
    let gate: LockGate
    let outDir: URL
    let stalls = StallMeter()
    var window: NSWindow?
    private let baseSize = CGSize(width: 1280, height: 720)
    private let smallSize = CGSize(width: 800, height: 450)

    init(_ cfg: Config) {
        self.cfg = cfg
        gate = LockGate(path: cfg.lock)
        outDir = URL(fileURLWithPath: cfg.out)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    func emit(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let url = outDir.appendingPathComponent("results.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: d + Data("\n".utf8))
            try? h.close()
        }
        print(String(data: d, encoding: .utf8)!)
    }

    func makeSurface() throws -> any Surface {
        let log = outDir.appendingPathComponent("mpv-\(cfg.path).log")
        switch cfg.path {
        case "a": return try PathASurface(logURL: log, logLevel: cfg.logLevel, hwdec: cfg.hwdec, tagSRGB: cfg.tagSRGB)
        case "b": return try PathBSurface(logURL: log, logLevel: cfg.logLevel, hwdec: cfg.hwdec,
                                          sizeGuard: cfg.sizeGuard, mode: cfg.resizeMode)
        default: return try PathCSurface(logURL: log, logLevel: cfg.logLevel, hwdec: cfg.hwdec)
        }
    }

    func show(_ surface: any Surface) {
        let screen = pickScreen()
        let v = screen.visibleFrame
        let w = NSWindow(contentRect: CGRect(x: v.maxX - baseSize.width - 24, y: v.maxY - baseSize.height - 24,
                                             width: baseSize.width, height: baseSize.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.backgroundColor = .black
        w.contentView = surface.hostView
        surface.hostView.autoresizingMask = [.width, .height]
        surface.hostView.onResize?(surface.hostView.bounds.size, w.backingScaleFactor)
        w.orderFrontRegardless()
        window = w
    }

    /// NSScreen.main follows keyboard focus, so pin the display to keep runs comparable.
    func pickScreen() -> NSScreen {
        let wantBuiltin = cfg.screen == "builtin"
        return NSScreen.screens.first { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return (CGDisplayIsBuiltin(id) != 0) == wantBuiltin
        } ?? NSScreen.screens[0]
    }

    func screenInfo() -> [String: Any] {
        let s = pickScreen()
        return ["name": s.localizedName, "scale": s.backingScaleFactor, "maxFPS": s.maximumFramesPerSecond]
    }

    func clipURLs() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: cfg.clips),
                                                                includingPropertiesForKeys: nil)) ?? []
        return all.filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { cfg.only.isEmpty || cfg.only.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func run() async -> Int32 {
        stalls.start()
        print("screen capture preflight:", CGPreflightScreenCaptureAccess())
        do {
            switch cfg.mode {
            case "probe": return await probe()
            case "matrix": return try await matrix()
            case "churn": return try await churn()
            default: print("unknown mode"); return 2
            }
        } catch {
            print("FAILED:", error)
            emit(["path": cfg.path, "mode": cfg.mode, "fatal": "\(error)"])
            return 1
        }
    }

    /// No playback: opens a core and a surface and reports what the build supports.
    func probe() async -> Int32 {
        do {
            let s = try makeSurface()
            show(s)
            var r = await s.core.snapshot(["mpv-version", "ffmpeg-version", "libassuc-version", "current-vo", "hwdec-interop"])
            r["hwdec-codecs"] = s.core.get("hwdec-codecs")
            print(r, s.extra)
            print("avcodec license:", String(cString: avcodec_license()))
            print("avcodec configuration:", String(cString: avcodec_configuration()))
            let decoders = ["h264", "hevc", "av1", "libdav1d", "vp8", "vp9", "vp3", "theora", "vp6", "vp6f", "mpeg1video", "mpeg2video",
                            "mpeg4", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "wmv1", "wmv2", "wmv3", "vc1", "h263", "flv", "mjpeg",
                            "dvvideo", "cinepak", "dnxhd", "prores", "huffyuv", "ffv1", "indeo3", "indeo4", "indeo5", "msvideo1",
                            "qtrle", "rv30", "rv40", "svq1", "svq3", "aac", "mp3", "ac3", "eac3", "dca", "truehd", "flac", "opus",
                            "vorbis", "wmav1", "wmav2", "wmapro", "wmalossless", "alac", "pcm_s16le", "adpcm_ms"]
            print("decoders missing:", decoders.filter { avcodec_find_decoder_by_name($0) == nil })
            let demuxers = ["avi", "asf", "matroska", "mov", "mpegts", "mpeg", "mpegvideo", "flv", "ogg", "rm", "mxf", "nut", "dv", "wtv", "ivf", "m4v", "h264", "hevc", "gif", "image2"]
            print("demuxers missing:", demuxers.filter { av_find_input_format($0) == nil })
            await s.teardown()
            return 0
        } catch { print("FAILED:", error); return 1 }
    }

    private func pauseForLock(_ surface: any Surface) async {
        guard gate.isLocked else { return }
        print("lock present, holding")
        await surface.core.commandAsync(["stop"])
        window?.orderOut(nil)
        while gate.isLocked { try? await Task.sleep(for: .seconds(2)) }
        try? await Task.sleep(for: .seconds(2))
        window?.orderFrontRegardless()
        print("lock clear, resuming")
    }

    /// Sleeps, but gives up the moment the sibling's lock appears.
    private func hold(_ seconds: Double) async throws {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            if gate.isLocked { throw LockInterrupt() }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func resize(from: CGSize, to: CGSize, seconds: Double) async {
        guard let window else { return }
        let top = window.frame.maxY, right = window.frame.maxX
        let steps = max(1, Int(seconds * 60))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let w = (from.width + (to.width - from.width) * t).rounded()
            let h = (from.height + (to.height - from.height) * t).rounded()
            window.setFrame(CGRect(x: right - w, y: top - h, width: w, height: h), display: true)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func screencap(to url: URL) async -> Bool {
        guard let window else { return false }
        let id = window.windowNumber
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(id)", url.path]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        }.value
    }

    private func windowState(_ label: String) {
        guard let w = window else { return }
        print("window \(label): visible=\(w.isVisible) occluded=\(!w.occlusionState.contains(.visible)) number=\(w.windowNumber) frame=\(w.frame) screen=\(w.screen?.localizedName ?? "none")")
    }

    private func snap(_ s: any Surface) async -> [String: Any] {
        var out: [String: Any] = await s.core.snapshot(statKeys)
        out["footprintMB"] = Double(physFootprint()) / 1048576
        out["mainStallMs"] = stalls.take()
        return out
    }

    private func playClip(_ s: any Surface, _ clip: URL, _ tag: String) async throws -> [String: Any] {
        let core = s.core
        var rec: [String: Any] = ["path": cfg.path, "clip": clip.lastPathComponent, "hwdecMode": cfg.hwdec, "screen": screenInfo()]
        let endMark = core.count(MPV_EVENT_END_FILE)
        var mark = core.count(MPV_EVENT_PLAYBACK_RESTART)
        let start = CACurrentMediaTime()
        await core.commandAsync(["loadfile", clip.path, "replace"])
        guard let _ = await core.wait(for: MPV_EVENT_PLAYBACK_RESTART, after: mark, timeout: 12) else {
            rec["ok"] = false
            rec["error"] = "no playback-restart in 12 s"
            if core.count(MPV_EVENT_END_FILE) > endMark, let e = core.lastEndFile {
                rec["endFile"] = ["reason": e.reason, "error": e.error]
            }
            return rec
        }
        rec["loadMs"] = (CACurrentMediaTime() - start) * 1000
        _ = stalls.take()

        windowState("loaded")
        try await hold(cfg.play)
        windowState("played")
        rec["play"] = await snap(s)

        await resize(from: baseSize, to: smallSize, seconds: 0.75)
        try await hold(0.2)
        windowState("small")
        rec["smallOsd"] = await s.core.snapshot(["osd-dimensions/w", "osd-dimensions/h"])
        let small = outDir.appendingPathComponent("\(tag)-small-screen.png")
        rec["smallCapture"] = await screencap(to: small) ? small.lastPathComponent : "failed"
        await resize(from: smallSize, to: baseSize, seconds: 0.75)
        rec["resize"] = await snap(s)

        mark = core.count(MPV_EVENT_PLAYBACK_RESTART)
        await core.commandAsync(["seek", "50", "absolute-percent", "exact"])
        rec["seekExactMs"] = await core.wait(for: MPV_EVENT_PLAYBACK_RESTART, after: mark, timeout: 8) ?? -1
        rec["seekLandedAt"] = await core.snapshot(["time-pos"])["time-pos"] ?? ""
        try await hold(1.5)
        mark = core.count(MPV_EVENT_PLAYBACK_RESTART)
        await core.commandAsync(["seek", "-2", "relative", "keyframes"])
        rec["seekBackMs"] = await core.wait(for: MPV_EVENT_PLAYBACK_RESTART, after: mark, timeout: 8) ?? -1
        try await hold(0.5)
        rec["seek"] = await snap(s)

        core.set("pause", "yes")
        try await hold(0.3)
        rec["pausedAt"] = await core.snapshot(["time-pos"])["time-pos"] ?? ""
        let rendered = outDir.appendingPathComponent("\(tag)-rendered.png")
        rec["rendered"] = await s.captureRendered(to: rendered) ?? "not available on this path"
        let screen = outDir.appendingPathComponent("\(tag)-screen.png")
        rec["screenCapture"] = await screencap(to: screen) ? screen.lastPathComponent : "failed"
        core.set("pause", "no")
        rec["extra"] = s.extra
        rec["ok"] = true
        return rec
    }

    func matrix() async throws -> Int32 {
        let s = try makeSurface()
        show(s)
        print("surface:", s.extra)
        let clips = clipURLs()
        for clip in clips {
            var done = false
            while !done {
                await pauseForLock(s)
                do {
                    let tag = "\(cfg.path)-\(clip.lastPathComponent)"
                    emit(try await playClip(s, clip, tag))
                    done = true
                } catch is LockInterrupt {
                    print("interrupted by lock, will retry", clip.lastPathComponent)
                    window?.setFrame(CGRect(x: window!.frame.maxX - baseSize.width, y: window!.frame.maxY - baseSize.height,
                                            width: baseSize.width, height: baseSize.height), display: false)
                }
            }
        }
        await s.core.commandAsync(["stop"])
        emit(["path": cfg.path, "mode": "matrix-end", "footprintMB": Double(physFootprint()) / 1048576])
        window?.orderOut(nil)
        let t = CACurrentMediaTime()
        await s.teardown()
        emit(["path": cfg.path, "mode": "teardown", "teardownMs": (CACurrentMediaTime() - t) * 1000,
              "footprintMB": Double(physFootprint()) / 1048576])
        return 0
    }

    /// Repeated load/unload on one core, then full surface and core rebuilds.
    func churn() async throws -> Int32 {
        let clips = clipURLs()
        guard !clips.isEmpty else { print("no clips"); return 2 }
        var footprints: [Double] = []
        do {
            let s = try makeSurface()
            show(s)
            var failed = 0
            for i in 0..<cfg.loads {
                await pauseForLock(s)
                let mark = s.core.count(MPV_EVENT_PLAYBACK_RESTART)
                await s.core.commandAsync(["loadfile", clips[i % clips.count].path, "replace"])
                if await s.core.wait(for: MPV_EVENT_PLAYBACK_RESTART, after: mark, timeout: 8) == nil { failed += 1 }
                try? await Task.sleep(for: .milliseconds(250))
                if i % 5 == 4 { await s.core.commandAsync(["stop"]) }
                footprints.append(Double(physFootprint()) / 1048576)
            }
            await s.core.commandAsync(["stop"])
            window?.orderOut(nil)
            await s.teardown()
            emit(["path": cfg.path, "mode": "churn-loads", "loads": cfg.loads, "failed": failed, "footprintMB": footprints])
        }
        footprints = []
        var failed = 0
        for i in 0..<cfg.rebuilds {
            if gate.isLocked { while gate.isLocked { try? await Task.sleep(for: .seconds(2)) } }
            let s = try makeSurface()
            show(s)
            let mark = s.core.count(MPV_EVENT_PLAYBACK_RESTART)
            await s.core.commandAsync(["loadfile", clips[i % clips.count].path, "replace"])
            // Every third pass tears down mid-load, the case most likely to race.
            if i % 3 != 2 {
                if await s.core.wait(for: MPV_EVENT_PLAYBACK_RESTART, after: mark, timeout: 8) == nil { failed += 1 }
                try? await Task.sleep(for: .milliseconds(300))
            }
            window?.orderOut(nil)
            await s.teardown()
            window?.contentView = nil
            window?.close()
            window = nil
            // Let Core Animation and AppKit run so released objects really go away.
            try? await Task.sleep(for: .milliseconds(50))
            footprints.append(Double(physFootprint()) / 1048576)
        }
        emit(["path": cfg.path, "mode": "churn-rebuilds", "rebuilds": cfg.rebuilds, "failed": failed, "footprintMB": footprints])
        return 0
    }
}
