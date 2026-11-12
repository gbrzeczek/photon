import CMpv
import Foundation
import Synchronization

/// What mpv reports, turned into Swift values on the event thread.
enum MpvEvent: Sendable {
    case fileLoaded
    /// `reason` is an `mpv_end_file_reason`, and `error` an mpv error code when it ended in error.
    case endFile(reason: Int32, error: Int32)
    case playbackRestart
    case videoReconfigured
    case property(name: String, value: MpvValue)
    /// A hook mpv waits on until `continueHook` is called with its ID.
    case hook(name: String, id: UInt64)
    case shutdown
}

enum MpvValue: Sendable, Equatable {
    case none
    case flag(Bool)
    case double(Double)
    case string(String)

    var double: Double? { if case .double(let value) = self { value } else { nil } }
    var flag: Bool? { if case .flag(let value) = self { value } else { nil } }
}

/// One mpv core, with the options every use in Photon shares.
///
/// mpv's calls can block on the core's lock while it opens or seeks, so nothing here may be called on
/// the main thread. Playback goes through its own serial queue, and frames for thumbnails through a
/// thread of their own.
final class MpvCore: @unchecked Sendable {
    let api: MpvLibrary
    let handle: OpaquePointer
    private let state = Mutex(State())
    private let eventsDone = DispatchSemaphore(value: 0)
    /// Keeps each stream's provider alive for as long as mpv may call it.
    private var streams: [MpvStreamRegistration] = []

    private struct State {
        var handler: (@Sendable (MpvEvent) -> Void)?
        var stopping = false
        var destroyed = false
        var started = false
    }

    /// The options that keep mpv to the one file it's given, and out of everything around it.
    ///
    /// mpv would otherwise open files by itself, past the volume's I/O scheduler: subtitles and audio
    /// beside the video, cover art, the other parts of an ordered-chapters Matroska file, references
    /// inside a playlist or EDL, and its own config and scripts.
    static let isolation: [(String, String)] = [
        // There are no scripts to load, and no ytdl hook, because this build has no Lua.
        ("config", "no"),
        ("terminal", "no"),
        ("input-default-bindings", "no"),
        ("input-vo-keyboard", "no"),
        ("input-media-keys", "no"),
        ("sub-auto", "no"),
        ("audio-file-auto", "no"),
        ("cover-art-auto", "no"),
        ("image-display-duration", "0"),
        ("access-references", "no"),
        ("ordered-chapters", "no"),
        ("load-unsafe-playlists", "no"),
        ("autoload-files", "no"),
        ("resume-playback", "no"),
        ("save-position-on-quit", "no"),
        ("watch-later-options", ""),
        ("osd-level", "0"),
        ("idle", "yes"),
        // Bounds the demuxer's read-ahead, which is all memory here.
        ("demuxer-max-bytes", "64MiB"),
        ("demuxer-max-back-bytes", "16MiB"),
        ("demuxer-readahead-secs", "10"),
    ]

    /// `PHOTON_MPV_LOG=<level>`, such as `v` or `debug`, prints mpv's log to standard error. For
    /// development only. File names never appear, because mpv only ever sees a `photon://` URL.
    static let logLevel: String? = {
        guard let level = ProcessInfo.processInfo.environment["PHOTON_MPV_LOG"], !level.isEmpty else { return nil }
        return level
    }()

    init(api: MpvLibrary, options: [(String, String)]) throws {
        guard let handle = api.create() else { throw MpvError(description: "mpv_create failed") }
        self.api = api
        self.handle = handle
        for (name, value) in Self.isolation + options {
            let code = api.setOptionString(handle, name, value)
            // An option this build doesn't know is left out rather than failing the playback, so a newer
            // or older mpv still plays. The ones that matter for the disk rules are checked by tests.
            if code < 0, code != MPV_ERROR_OPTION_NOT_FOUND.rawValue {
                api.terminateDestroy(handle)
                throw MpvError(description: "\(name)=\(value): \(api.describe(code))")
            }
        }
    }

    /// Serves `photon://` URLs from `provider`. Call before `start`.
    func register(_ provider: any MpvByteProvider) {
        let registration = MpvStreamRegistration(provider: provider)
        streams.append(registration)
        _ = api.streamCBAddRO(
            handle, MpvStreamRegistration.scheme, Unmanaged.passUnretained(registration).toOpaque(),
            MpvStreamRegistration.open)
    }

    /// Initializes the core and starts its event thread. `handler` is called on that thread.
    func start(handler: @escaping @Sendable (MpvEvent) -> Void) throws {
        state.withLock { $0.handler = handler }
        if let level = Self.logLevel { _ = api.requestLogMessages(handle, level) }
        let code = api.initialize(handle)
        guard code >= 0 else { throw MpvError(description: "mpv_initialize: \(api.describe(code))") }
        state.withLock { $0.started = true }
        let thread = Thread { [self] in eventLoop() }
        thread.name = "app.photon.mpv.events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Asks mpv to stop at `name` and wait for `continueHook`. Call before `start`'s file loads.
    func addHook(_ name: String) {
        _ = api.hookAdd(handle, 0, name, 0)
    }

    func continueHook(_ id: UInt64) {
        _ = api.hookContinue(handle, id)
    }

    func observe(_ name: String, format: mpv_format) {
        _ = api.observeProperty(handle, 0, name, format)
    }

    @discardableResult
    func command(_ arguments: [String]) -> Int32 {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        defer { for pointer in pointers { Foundation.free(UnsafeMutablePointer(mutating: pointer)) } }
        return pointers.withUnsafeMutableBufferPointer { api.command(handle, $0.baseAddress) }
    }

    @discardableResult
    func set(_ name: String, _ value: String) -> Int32 {
        api.setPropertyString(handle, name, value)
    }

    func string(_ name: String) -> String? {
        guard let pointer = api.getPropertyString(handle, name) else { return nil }
        defer { api.free(pointer) }
        return String(cString: pointer)
    }

    func double(_ name: String) -> Double? {
        var value = 0.0
        return api.getProperty(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func int(_ name: String) -> Int64? {
        var value: Int64 = 0
        return api.getProperty(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func eventLoop() {
        defer { eventsDone.signal() }
        while true {
            // A bounded wait, checked against `stopping` each time. `mpv_wakeup` alone didn't always
            // end an unbounded one, which left `destroy` waiting forever.
            guard let pointer = api.waitEvent(handle, 0.25) else { continue }
            let event = pointer.pointee
            if event.event_id == MPV_EVENT_LOG_MESSAGE, let data = event.data {
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                FileHandle.standardError.write(
                    Data("[mpv \(String(cString: message.prefix))] \(String(cString: message.text))".utf8))
                continue
            }
            if event.event_id == MPV_EVENT_NONE {
                if state.withLock({ $0.stopping }) { return }
                continue
            }
            guard let converted = Self.convert(event) else { continue }
            let handler = state.withLock { $0.handler }
            handler?(converted)
            if case .shutdown = converted { return }
        }
    }

    private static func convert(_ event: mpv_event) -> MpvEvent? {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED: return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART: return .playbackRestart
        case MPV_EVENT_VIDEO_RECONFIG: return .videoReconfigured
        case MPV_EVENT_SHUTDOWN: return .shutdown
        case MPV_EVENT_HOOK:
            guard let data = event.data else { return nil }
            let hook = data.assumingMemoryBound(to: mpv_event_hook.self).pointee
            return .hook(name: String(cString: hook.name), id: hook.id)
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return .endFile(reason: 0, error: 0) }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            return .endFile(reason: Int32(end.reason.rawValue), error: end.error)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return nil }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            let value: MpvValue
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                value = property.data.map { .double($0.assumingMemoryBound(to: Double.self).pointee) } ?? .none
            case MPV_FORMAT_FLAG:
                value = property.data.map { .flag($0.assumingMemoryBound(to: Int32.self).pointee != 0) } ?? .none
            case MPV_FORMAT_STRING:
                value =
                    property.data.flatMap { $0.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee }
                    .map { .string(String(cString: $0)) } ?? .none
            default:
                value = .none
            }
            return .property(name: name, value: value)
        default:
            return nil
        }
    }

    /// Stops the event thread and destroys the core. Any render context must already be freed. Blocks
    /// until mpv has stopped, so it never runs on the main thread.
    func destroy() {
        let (started, alreadyDestroyed) = state.withLock { state -> (Bool, Bool) in
            defer {
                state.destroyed = true
                state.stopping = true
                state.handler = nil
            }
            return (state.started, state.destroyed)
        }
        guard !alreadyDestroyed else { return }
        for stream in streams { stream.provider.cancel() }
        if started {
            api.wakeup(handle)
            eventsDone.wait()
        }
        api.terminateDestroy(handle)
        streams.removeAll()
    }
}
