import Darwin
import Foundation
import QuartzCore

/// Frame pacing from the display link, and main-thread cost per frame up to the point where the
/// run loop goes idle, after the Core Animation commit. WindowServer and GPU time aren't visible
/// from here, so a clean result is necessary for smoothness, not proof of it.
struct Summary: Codable {
    var backend: String
    var layout: String
    var scenario: String
    var frames: Int
    var seconds: Double
    var fps: Double
    var nominalHz: Double
    var missedFrames: Int
    var longestGapMs: Double
    var mainP50Ms: Double
    var mainP95Ms: Double
    var mainP99Ms: Double
    var mainMaxMs: Double
    var thumbsApplied: Int
    var maxVisibleTiles: Int
    var footprintMB: Double
    var note: String?
}

final class FrameRecorder {
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var work: [Double] = []
    private var tickStart: UInt64 = 0
    private(set) var nominal: Double = 1.0 / 120

    func reset() {
        last = 0
        gaps.removeAll(keepingCapacity: true)
        work.removeAll(keepingCapacity: true)
        tickStart = 0
    }

    func tick(timestamp: CFTimeInterval, target: CFTimeInterval) {
        if last != 0 { gaps.append(timestamp - last) }
        last = timestamp
        if target > timestamp { nominal = target - timestamp }
        tickStart = DispatchTime.now().uptimeNanoseconds
    }

    /// Runs when the main run loop is about to sleep, so it includes the transaction commit.
    func idle() {
        guard tickStart != 0 else { return }
        work.append(Double(DispatchTime.now().uptimeNanoseconds - tickStart) / 1e9)
        tickStart = 0
    }

    func summarize(backend: String, layout: String, scenario: String, seconds: Double, thumbs: Int, maxVisible: Int, note: String?) -> Summary {
        let sorted = work.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
        let missed = gaps.filter { $0 > nominal * 1.5 }.count
        return Summary(
            backend: backend, layout: layout, scenario: scenario, frames: gaps.count, seconds: seconds,
            fps: Double(gaps.count) / max(gaps.reduce(0, +), 0.001), nominalHz: 1 / nominal, missedFrames: missed,
            longestGapMs: (gaps.max() ?? 0) * 1000, mainP50Ms: pct(0.5), mainP95Ms: pct(0.95), mainP99Ms: pct(0.99),
            mainMaxMs: (sorted.last ?? 0) * 1000, thumbsApplied: thumbs, maxVisibleTiles: maxVisible,
            footprintMB: footprintMB(), note: note)
    }
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : 0
}
