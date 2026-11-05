import Darwin
import Foundation
import Libmpv

struct MpvError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String, _ code: Int32? = nil) {
        if let code { description = "\(what): \(String(cString: mpv_error_string(code))) (\(code))" }
        else { description = what }
    }
}

/// Thin wrapper over one mpv core. Every call can block on the core lock, so
/// callers on the main actor go through the async variants.
final class MpvCore: @unchecked Sendable {
    let handle: OpaquePointer
    private let lock = NSLock()
    private var counts: [UInt32: Int] = [:]
    private var endFiles: [(reason: Int32, error: Int32)] = []
    private var stopping = false
    private let eventsDone = DispatchSemaphore(value: 0)
    private var logHandle: FileHandle?
    private var destroyed = false

    init(options: [(String, String)], wid: Int64?, logURL: URL?, logLevel: String) throws {
        guard let h = mpv_create() else { throw MpvError("mpv_create returned nil") }
        handle = h
        if let wid {
            var w = wid
            let rc = mpv_set_option(h, "wid", MPV_FORMAT_INT64, &w)
            if rc < 0 { throw MpvError("set wid", rc) }
        }
        for (k, v) in options {
            let rc = mpv_set_option_string(h, k, v)
            if rc < 0 { throw MpvError("set \(k)=\(v)", rc) }
        }
        if let logURL {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            logHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? logHandle?.seekToEnd()
            mpv_request_log_messages(h, logLevel)
        }
        let rc = mpv_initialize(h)
        if rc < 0 { throw MpvError("mpv_initialize", rc) }
        Thread.detachNewThread { [self] in eventLoop() }
    }

    private func eventLoop() {
        while true {
            guard let ev = mpv_wait_event(handle, 0.25)?.pointee else { continue }
            if ev.event_id == MPV_EVENT_NONE {
                if lock.withLock({ stopping }) { break }
                continue
            }
            if ev.event_id == MPV_EVENT_LOG_MESSAGE, let d = ev.data {
                let m = d.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                let line = "[\(String(cString: m.prefix))] \(String(cString: m.level)): \(String(cString: m.text))"
                try? logHandle?.write(contentsOf: Data(line.utf8))
                continue
            }
            lock.withLock {
                counts[ev.event_id.rawValue, default: 0] += 1
                if ev.event_id == MPV_EVENT_END_FILE, let d = ev.data {
                    let e = d.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    endFiles.append((Int32(e.reason.rawValue), e.error))
                }
            }
            if ev.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        eventsDone.signal()
    }

    func count(_ id: mpv_event_id) -> Int { lock.withLock { counts[id.rawValue] ?? 0 } }
    var lastEndFile: (reason: Int32, error: Int32)? { lock.withLock { endFiles.last } }

    /// Waits for the event count to pass `mark`. Returns elapsed ms, or nil on timeout.
    func wait(for id: mpv_event_id, after mark: Int, timeout: Double) async -> Double? {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            if count(id) > mark {
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }
            if Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 > timeout { return nil }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        var c: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        c.append(nil)
        defer { for p in c { free(UnsafeMutablePointer(mutating: p)) } }
        return mpv_command(handle, &c)
    }

    @discardableResult
    func commandAsync(_ args: [String]) async -> Int32 {
        await Task.detached { [self] in command(args) }.value
    }

    func get(_ name: String) -> String? {
        guard let p = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(p) }
        return String(cString: p)
    }

    func set(_ name: String, _ value: String) { _ = mpv_set_property_string(handle, name, value) }

    func snapshot(_ names: [String]) async -> [String: String] {
        await Task.detached { [self] in
            var out: [String: String] = [:]
            for n in names { if let v = get(n) { out[n] = v } }
            return out
        }.value
    }

    /// Stops the event thread, then destroys the core. Render context must already be freed.
    func destroy() async {
        guard !destroyed else { return }
        destroyed = true
        await Task.detached { [self] in shutdown() }.value
    }

    private func shutdown() {
        lock.withLock { stopping = true }
        mpv_wakeup(handle)
        eventsDone.wait()
        mpv_terminate_destroy(handle)
        try? logHandle?.close()
    }
}

func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}
