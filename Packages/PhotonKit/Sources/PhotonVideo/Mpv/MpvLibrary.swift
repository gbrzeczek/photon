import CMpv
import Darwin
import Foundation

/// libmpv, loaded at run time.
///
/// Photon never links libmpv, so the package builds and tests without it, and a build that doesn't
/// carry it has no fallback engine rather than failing to launch. The app carries Photon's own LGPL
/// build in its Frameworks folder, made by `scripts/mpv/build.sh`. Each library stays its own dylib,
/// so it can be replaced, as the LGPL asks.
final class MpvLibrary: @unchecked Sendable {
    typealias Handle = OpaquePointer
    typealias RenderContext = OpaquePointer

    let clientAPIVersion: UInt
    let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>?
    let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let create: @convention(c) () -> Handle?
    let initialize: @convention(c) (Handle?) -> Int32
    let terminateDestroy: @convention(c) (Handle?) -> Void
    let setOptionString: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let setPropertyString: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let getProperty: @convention(c) (Handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    let getPropertyString: @convention(c) (Handle?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    let command: @convention(c) (Handle?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    let observeProperty: @convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, mpv_format) -> Int32
    let waitEvent: @convention(c) (Handle?, Double) -> UnsafeMutablePointer<mpv_event>?
    let wakeup: @convention(c) (Handle?) -> Void
    let requestLogMessages: @convention(c) (Handle?, UnsafePointer<CChar>?) -> Int32
    let hookAdd: @convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32
    let hookContinue: @convention(c) (Handle?, UInt64) -> Int32
    let renderContextCreate:
        @convention(c) (
            UnsafeMutablePointer<RenderContext?>?, Handle?, UnsafeMutablePointer<mpv_render_param>?
        ) -> Int32
    let renderContextSetUpdateCallback:
        @convention(c) (RenderContext?, mpv_render_update_fn?, UnsafeMutableRawPointer?) -> Void
    let renderContextUpdate: @convention(c) (RenderContext?) -> UInt64
    let renderContextRender: @convention(c) (RenderContext?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    let renderContextReportSwap: @convention(c) (RenderContext?) -> Void
    let renderContextFree: @convention(c) (RenderContext?) -> Void
    let streamCBAddRO:
        @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, mpv_stream_cb_open_ro_fn?) -> Int32

    /// The build Photon carries, or nil when there isn't one, which leaves the fallback out.
    static let shared: MpvLibrary? = {
        for url in candidates() {
            if let library = MpvLibrary(url: url) { return library }
        }
        return nil
    }()

    /// The app's own Frameworks folder first. Tests and tools, which aren't an app, also look in the
    /// repository's `Vendor/mpv`, where `scripts/mpv/build.sh` puts its output, and at
    /// `PHOTON_MPV_LIBRARY`.
    static func candidates() -> [URL] {
        let name = "libmpv.2.dylib"
        var urls: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL {
            urls.append(frameworks.appending(path: name))
        }
        if Bundle.main.bundleURL.pathExtension != "app" {
            if let path = ProcessInfo.processInfo.environment["PHOTON_MPV_LIBRARY"], !path.isEmpty {
                urls.append(URL(filePath: path))
            }
            // Sources/PhotonVideo/Mpv/ is five folders below the repository's root.
            var root = URL(filePath: #filePath)
            for _ in 0..<6 { root.deleteLastPathComponent() }
            urls.append(root.appending(path: "Vendor/mpv/lib/\(name)"))
        }
        return urls
    }

    private init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
            let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL)
        else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let version = symbol("mpv_client_api_version", as: (@convention(c) () -> UInt).self),
            // The ABI this code was written against: client API 2, with stream_cb's cancel_fn and the
            // software renderer, which arrived during 2.x.
            version() >> 16 == 2, version() >= MpvLibrary.minimumAPI,
            let errorString = symbol("mpv_error_string", as: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self),
            let free = symbol("mpv_free", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
            let create = symbol("mpv_create", as: (@convention(c) () -> Handle?).self),
            let initialize = symbol("mpv_initialize", as: (@convention(c) (Handle?) -> Int32).self),
            let terminateDestroy = symbol("mpv_terminate_destroy", as: (@convention(c) (Handle?) -> Void).self),
            let setOptionString = symbol(
                "mpv_set_option_string",
                as: (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self),
            let setPropertyString = symbol(
                "mpv_set_property_string",
                as: (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self),
            let getProperty = symbol(
                "mpv_get_property",
                as: (@convention(c) (Handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32)
                    .self),
            let getPropertyString = symbol(
                "mpv_get_property_string",
                as: (@convention(c) (Handle?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?).self),
            let command = symbol(
                "mpv_command", as: (@convention(c) (Handle?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32).self),
            let observeProperty = symbol(
                "mpv_observe_property",
                as: (@convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, mpv_format) -> Int32).self),
            let waitEvent = symbol(
                "mpv_wait_event", as: (@convention(c) (Handle?, Double) -> UnsafeMutablePointer<mpv_event>?).self),
            let wakeup = symbol("mpv_wakeup", as: (@convention(c) (Handle?) -> Void).self),
            let requestLogMessages = symbol(
                "mpv_request_log_messages", as: (@convention(c) (Handle?, UnsafePointer<CChar>?) -> Int32).self),
            let hookAdd = symbol(
                "mpv_hook_add", as: (@convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32).self),
            let hookContinue = symbol("mpv_hook_continue", as: (@convention(c) (Handle?, UInt64) -> Int32).self),
            let renderContextCreate = symbol(
                "mpv_render_context_create",
                as: (@convention(c) (
                    UnsafeMutablePointer<RenderContext?>?, Handle?, UnsafeMutablePointer<mpv_render_param>?
                ) -> Int32).self),
            let renderContextSetUpdateCallback = symbol(
                "mpv_render_context_set_update_callback",
                as: (@convention(c) (RenderContext?, mpv_render_update_fn?, UnsafeMutableRawPointer?) -> Void).self),
            let renderContextUpdate = symbol(
                "mpv_render_context_update", as: (@convention(c) (RenderContext?) -> UInt64).self),
            let renderContextRender = symbol(
                "mpv_render_context_render",
                as: (@convention(c) (RenderContext?, UnsafeMutablePointer<mpv_render_param>?) -> Int32).self),
            let renderContextReportSwap = symbol(
                "mpv_render_context_report_swap", as: (@convention(c) (RenderContext?) -> Void).self),
            let renderContextFree = symbol(
                "mpv_render_context_free", as: (@convention(c) (RenderContext?) -> Void).self),
            let streamCBAddRO = symbol(
                "mpv_stream_cb_add_ro",
                as: (@convention(c) (
                    Handle?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, mpv_stream_cb_open_ro_fn?
                ) -> Int32).self)
        else {
            dlclose(handle)
            return nil
        }
        clientAPIVersion = version()
        self.errorString = errorString
        self.free = free
        self.create = create
        self.initialize = initialize
        self.terminateDestroy = terminateDestroy
        self.setOptionString = setOptionString
        self.setPropertyString = setPropertyString
        self.getProperty = getProperty
        self.getPropertyString = getPropertyString
        self.command = command
        self.observeProperty = observeProperty
        self.waitEvent = waitEvent
        self.wakeup = wakeup
        self.requestLogMessages = requestLogMessages
        self.hookAdd = hookAdd
        self.hookContinue = hookContinue
        self.renderContextCreate = renderContextCreate
        self.renderContextSetUpdateCallback = renderContextSetUpdateCallback
        self.renderContextUpdate = renderContextUpdate
        self.renderContextRender = renderContextRender
        self.renderContextReportSwap = renderContextReportSwap
        self.renderContextFree = renderContextFree
        self.streamCBAddRO = streamCBAddRO
        // The library stays loaded for the life of the process. mpv's threads may outlive any one core.
    }

    /// Client API 2.5, from mpv 0.41.
    static let minimumAPI: UInt = (2 << 16) | 5

    func describe(_ code: Int32) -> String {
        guard let text = errorString(code) else { return "mpv error \(code)" }
        return String(cString: text)
    }
}

struct MpvError: Error, CustomStringConvertible {
    let description: String
}
