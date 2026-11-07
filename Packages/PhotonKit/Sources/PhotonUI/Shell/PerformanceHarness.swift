import AppKit
import Foundation

/// Scripted input for measuring the budgets in docs/PLAN.md. Only runs when `PHOTON_PERF_OUT` names a
/// file, and writes timings there, then quits. The numbers are in-app, and Spike 1 showed they miss
/// hitches, so they go alongside Instruments, not instead of it.
@MainActor
final class PerformanceHarness: NSObject {
    private struct Scenario {
        var name: String
        var frames: Int
        var step: (Int) -> Void
    }

    private let view: BrowserContainerView
    private let model: BrowserModel
    private let outputURL: URL
    private let scenarioNames: [String]
    private var scenarios: [Scenario] = []
    private var link: CADisplayLink?
    private var index = 0
    private var frame = 0
    private var previousTimestamp: CFTimeInterval = 0
    private var frameIntervals: [Double] = []
    private var mainTimes: [Double] = []
    private var report: [[String: Any]] = []
    private var launchMilliseconds: Double?
    private var openMilliseconds: Double?
    private var settleFrames = 0

    private static var current: PerformanceHarness?

    static func attachIfRequested(to view: BrowserContainerView, model: BrowserModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["PHOTON_PERF_OUT"], current == nil else { return }
        let names = (environment["PHOTON_PERF_SCENARIOS"] ?? "scroll,fastscroll,zoom,zoomsmall,arrows,arrowsfast")
            .split(separator: ",").map(String.init)
        let harness = PerformanceHarness(
            view: view, model: model, outputURL: URL(fileURLWithPath: output), scenarios: names)
        current = harness
        harness.begin()
    }

    private init(view: BrowserContainerView, model: BrowserModel, outputURL: URL, scenarios: [String]) {
        self.view = view
        self.model = model
        self.outputURL = outputURL
        scenarioNames = scenarios
    }

    private var openedAt = DispatchTime.now()

    private func begin() {
        var infoSize = MemoryLayout<kinfo_proc>.stride
        var info = kinfo_proc()
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&name, 4, &info, &infoSize, nil, 0)
        let started = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(started.tv_sec) + Double(started.tv_usec) / 1e6

        model.onResult = { [weak self] count in
            guard let self, self.launchMilliseconds == nil, count > 0 else { return }
            self.launchMilliseconds = (Date().timeIntervalSince1970 - startSeconds) * 1000
            self.model.onResult = nil
            self.processStart = startSeconds
            self.view.displayLink(target: self, selector: #selector(self.firstFrame)).add(to: .main, forMode: .common)
            // Lets the first frame reach the screen before anything is measured.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.measureOpen() }
        }
    }

    /// A second open of the same query, cold for the app and warm for the disk cache.
    private func measureOpen() {
        let start = DispatchTime.now()
        model.onResult = { [weak self] _ in
            guard let self else { return }
            self.openMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            self.model.onResult = nil
            self.startScenarios()
        }
        model.reload(keepPosition: false)
    }

    private func startScenarios() {
        // A saved session can open in the list, and these need to start from a grid that's showing.
        model.setViewMode(.tiles)
        let grid = view.grid
        let list = view.list
        let viewportWidth = grid.bounds.width
        let center = CGPoint(x: viewportWidth / 2, y: grid.bounds.height / 2)
        for name in scenarioNames {
            switch name {
            case "scroll":
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    grid.scroll(toTop: CGFloat(frame) * 4000 / 120)
                })
            case "fastscroll":
                scenarios.append(Scenario(name: name, frames: 240) { frame in
                    grid.scroll(toTop: 5000 + CGFloat(frame) * 120_000 / 120)
                })
            case "zoom":
                scenarios.append(Scenario(name: name, frames: 600) { frame in
                    let phase = sin(Double(frame) / 600 * 2 * .pi * 2)
                    let size = 232 + 168 * CGFloat(phase)
                    grid.zoomForMeasuring(to: size, anchor: center)
                    self.model.setTileSizeFromGesture(size)
                })
            case "zoomsmall":
                scenarios.append(Scenario(name: name, frames: 600) { frame in
                    let phase = sin(Double(frame) / 600 * 2 * .pi * 2)
                    let size = 96 + 32 * CGFloat(phase)
                    grid.zoomForMeasuring(to: size, anchor: center)
                    self.model.setTileSizeFromGesture(size)
                })
            case "gridscroll":
                // Notches in bursts, in and out, as a wheel sends them.
                scenarios.append(Scenario(name: name, frames: 600) { frame in
                    if frame % 12 == 0, frame % 300 < 150 {
                        grid.scrollZoomForMeasuring(factor: frame < 300 ? 1.15 : 1 / 1.15, at: center)
                    }
                })
            case "arrows", "arrowsfast":
                let perFrame = name == "arrows" ? 0.25 : 2
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    self.pressArrows(frame: frame, perFrame: perFrame)
                })
            case "shiftarrows":
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    self.pressArrows(frame: frame, perFrame: 0.25, extending: true)
                })
            case "listshiftarrows":
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    if frame == 0 { self.model.setViewMode(.list) }
                    self.pressArrows(frame: frame, perFrame: 0.25, extending: true)
                })
            case "listarrows", "listarrowsfast":
                let perFrame = name == "listarrows" ? 0.25 : 2
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    if frame == 0 { self.model.setViewMode(.list) }
                    self.pressArrows(frame: frame, perFrame: perFrame)
                })
            case "vieweropen":
                // Open and close the same photo, once a second, while the flights run in Core Animation.
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    switch frame % 120 {
                    case 0: self.model.openViewer()
                    case 60: self.model.closeViewer()
                    default: break
                    }
                })
            case "viewerarrows", "viewerarrowsfast":
                let perFrame = name == "viewerarrows" ? 0.25 : 2
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    if frame == 0 { self.model.openViewer() }
                    self.arrowCredit += perFrame
                    while self.arrowCredit >= 1 {
                        self.arrowCredit -= 1
                        // A held key starts with one press, and repeats after it.
                        self.model.stepViewer(by: 1, isRepeat: frame > 0)
                    }
                    if frame == 479 { self.model.closeViewer(animated: false) }
                })
            case "viewerstep", "viewerjump":
                // One photo at a time, resting long enough to load. A step finds its neighbor ready,
                // and a jump of 50 finds nothing ready, so the pair brackets what the eye sees.
                let distance = name == "viewerstep" ? 1 : 50
                scenarios.append(Scenario(name: name, frames: 1440) { frame in
                    if frame == 0 {
                        self.sharpTimes = []
                        self.view.viewer.sharpObserver = { self.sharpTimes.append($0) }
                        self.model.openViewer()
                    }
                    if frame > 0, frame.isMultiple(of: 60) { self.model.stepViewer(by: distance, isRepeat: false) }
                    if frame == 1439 { self.model.closeViewer(animated: false) }
                })
            case "viewerzoom":
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    if frame == 0 { self.model.openViewer() }
                    let phase = sin(Double(frame) / 480 * 2 * .pi * 2)
                    self.view.viewer.setZoomForMeasuring(CGFloat(2.5 + 1.5 * phase))
                    self.view.viewer.stepForMeasuring(pixelsPan: frame % 240 < 120 ? 6 : -6)
                    if frame == 479 { self.model.closeViewer(animated: false) }
                })
            case "viewerscroll":
                // Notches in bursts, in and out, as a wheel sends them.
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    if frame == 0 { self.model.openViewer() }
                    if frame >= 30, frame % 12 == 0 {
                        self.view.viewer.scrollForMeasuring(factor: frame % 240 < 120 ? 1.3 : 1 / 1.3)
                    }
                    if frame == 479 { self.model.closeViewer(animated: false) }
                })
            case "listviewer":
                scenarios.append(Scenario(name: name, frames: 240) { frame in
                    if frame == 0 { self.model.setViewMode(.list) }
                    if frame == 30 { self.model.openViewer() }
                    if frame == 150 { self.model.closeViewer() }
                })
            case "copyall":
                // Copies everything, and keeps the frames going while it lands.
                scenarios.append(Scenario(name: name, frames: 600) { frame in
                    if frame == 30 {
                        self.model.selectAll()
                        let start = CACurrentMediaTime()
                        self.model.copy()
                        let task = self.model.copyTask
                        Task { @MainActor in
                            await task?.value
                            self.sharpTimes.append((CACurrentMediaTime() - start) * 1000)
                        }
                    }
                    if frame == 590 { self.model.selectNone() }
                })
            case "listswitch":
                scenarios.append(Scenario(name: name, frames: 60) { frame in
                    if frame == 0 { self.model.setViewMode(.list) }
                })
            case "listscroll":
                scenarios.append(Scenario(name: name, frames: 480) { frame in
                    if frame == 0 { self.model.setViewMode(.list) }
                    list.table.scroll(CGPoint(x: 0, y: CGFloat(frame) * 4000 / 120))
                })
            default:
                break
            }
        }
        if ProcessInfo.processInfo.environment["PHOTON_PERF_TIMER"] != nil {
            // With the display asleep nothing drives a display link. This measures main-thread cost
            // only, so it says nothing about frame rate.
            Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step(now: CACurrentMediaTime(), duration: 1.0 / 120) }
            }
            return
        }
        link = view.displayLink(target: self, selector: #selector(fired))
        link?.add(to: .main, forMode: .common)
    }

    private var arrowCredit = 0.0
    private var sharpTimes: [Double] = []

    private func pressArrows(frame: Int, perFrame: Double, extending: Bool = false) {
        arrowCredit += perFrame
        while arrowCredit >= 1 {
            arrowCredit -= 1
            model.move(frame.isMultiple(of: 240) ? .down : .right, extending: extending)
        }
    }

    private var processStart = 0.0
    private var firstFrameMilliseconds: Double?

    /// The commit with the first tiles has gone out by the frame after they're installed.
    @objc private func firstFrame(_ link: CADisplayLink) {
        link.invalidate()
        firstFrameMilliseconds = (Date().timeIntervalSince1970 - processStart) * 1000
    }

    @objc private func fired(_ link: CADisplayLink) {
        step(now: link.timestamp, duration: link.duration)
    }

    private func step(now: CFTimeInterval, duration: CFTimeInterval) {
        guard index < scenarios.count else {
            finish()
            return
        }
        let scenario = scenarios[index]
        if frame > 0 { frameIntervals.append((now - previousTimestamp) * 1000) }
        previousTimestamp = now

        let start = DispatchTime.now().uptimeNanoseconds
        scenario.step(frame)
        _ = view.grid.tick()
        mainTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        frame += 1
        if frame >= scenario.frames {
            record(scenario.name, duration: duration)
            index += 1
            frame = 0
            frameIntervals.removeAll()
            mainTimes.removeAll()
        }
    }

    private func record(_ name: String, duration: CFTimeInterval) {
        let sorted = mainTimes.sorted()
        func percentile(_ value: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * value))]
        }
        let budget = duration * 1000 * 1.5
        let sharp = sharpTimes.sorted()
        sharpTimes = []
        view.viewer.sharpObserver = nil
        report.append([
            "sharpMs": sharp.isEmpty
                ? [:] : ["count": sharp.count, "p50": sharp[sharp.count / 2], "max": sharp[sharp.count - 1]],
            "scenario": name,
            "frames": frameIntervals.count,
            "fps": frameIntervals.isEmpty ? 0 : 1000 / (frameIntervals.reduce(0, +) / Double(frameIntervals.count)),
            "missed": frameIntervals.filter { $0 > budget }.count,
            "mainP50": percentile(0.5),
            "mainP95": percentile(0.95),
            "mainP99": percentile(0.99),
            "mainMax": sorted.last ?? 0,
        ])
    }

    private func finish() {
        link?.invalidate()
        link = nil
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let output: [String: Any] = [
            "items": model.itemCount,
            "launchToResultMs": launchMilliseconds ?? -1,
            "launchToFirstFrameMs": firstFrameMilliseconds ?? -1,
            "openMs": openMilliseconds ?? -1,
            "footprintMB": Double(info.phys_footprint) / 1_048_576,
            "windowPoints": [view.bounds.width, view.bounds.height],
            "backingScale": view.window?.backingScaleFactor ?? 0,
            "maximumFPS": view.window?.screen?.maximumFramesPerSecond ?? 0,
            "edrNow": view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0,
            "edrPotential": view.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0,
            "scenarios": report,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outputURL)
        }
        NSApplication.shared.terminate(nil)
    }
}
