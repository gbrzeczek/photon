import CMpv
import CoreGraphics
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia

/// Waits on what an mpv core reports, from a thread that may block. Never the main thread.
final class MpvWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private(set) var loaded = false
    private(set) var ended: (reason: Int32, error: Int32)?
    private(set) var restarts = 0
    /// The ID of the `on_preloaded` hook mpv is waiting on, once it is.
    private(set) var preloaded: UInt64?
    private var signals = 0
    private var aborted = false

    func handle(_ event: MpvEvent) {
        condition.withLock {
            switch event {
            case .fileLoaded: loaded = true
            case .endFile(let reason, let error):
                // A stop for the next file isn't an ending, and Photon never plays a second file.
                if reason != Int32(MPV_END_FILE_REASON_STOP.rawValue) { ended = (reason, error) }
            case .playbackRestart: restarts += 1
            case .hook(let name, let id): if name == "on_preloaded" { preloaded = id }
            case .shutdown: aborted = true
            default: break
            }
            signals += 1
            condition.broadcast()
        }
    }

    /// For mpv's render update callback.
    func signal() {
        condition.withLock {
            signals += 1
            condition.broadcast()
        }
    }

    func abort() {
        condition.withLock {
            aborted = true
            condition.broadcast()
        }
    }

    var isAborted: Bool { condition.withLock { aborted } }

    /// Waits until `done` holds, the file ends, the waiter is aborted or `timeout` passes. `poll` runs
    /// after each wakeup, outside the lock, for work such as asking the render context what changed.
    /// Returns whether `done` held.
    func wait(timeout: TimeInterval, poll: () -> Void = {}, until done: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            poll()
            let (finished, stop, seen) = condition.withLock { (done(), aborted || ended != nil, signals) }
            if finished { return true }
            if stop { return false }
            let more = condition.withLock { () -> Bool in
                while signals == seen, !aborted {
                    if !condition.wait(until: deadline) { return false }
                }
                return true
            }
            if !more { return condition.withLock { done() } }
        }
    }
}

/// Still frames through mpv's software renderer, for thumbnails and scrub previews of the formats only
/// the fallback reads. Everything mpv reads comes from `provider`, through the volume's I/O scheduler.
///
/// Every call blocks, so it runs on `MpvFrameGrabber.queue`, never the main thread.
final class MpvFrameGrabber: @unchecked Sendable {
    /// Frames decode here. A thread each, because every call waits on mpv.
    static let queue = DispatchQueue(label: "app.photon.mpv.frames", qos: .utility, attributes: .concurrent)
    /// Long enough for a sleeping drive to wake. Past it, the read counts as the drive's fault, not the
    /// file's, so nothing is marked as failed because a drive was slow.
    static let timeout: TimeInterval = 30

    private let core: MpvCore
    private let waiter = MpvWaiter()
    private var render: OpaquePointer?
    private var frameSeen = false
    private var closed = false
    let provider: any MpvByteProvider

    init(api: MpvLibrary, provider: any MpvByteProvider, fileExtension: String) throws {
        self.provider = provider
        // No audio, no subtitles, software decoding of one frame at a time, and seeks to keyframes,
        // which decode one frame instead of a run of them.
        core = try MpvCore(
            api: api,
            options: [
                ("vo", "libmpv"), ("ao", "null"), ("aid", "no"), ("sid", "no"), ("pause", "yes"),
                ("hwdec", "no"), ("hr-seek", "no"), ("keep-open", "yes"), ("vd-lavc-threads", "2"),
                ("demuxer-readahead-secs", "0"), ("cache", "no"),
            ])
        core.register(provider)
        let waiter = waiter
        do {
            try core.start { event in waiter.handle(event) }
            render = try makeRenderContext(api: api)
        } catch {
            core.destroy()
            throw error
        }
        core.command(["loadfile", MpvStreamRegistration.url(fileExtension: fileExtension)])
    }

    private func makeRenderContext(api: MpvLibrary) throws -> OpaquePointer {
        var context: OpaquePointer?
        let code: Int32 = MPV_RENDER_API_TYPE_SW.withCString { type in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: type)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return api.renderContextCreate(&context, core.handle, &params)
        }
        guard code >= 0, let context else {
            throw MpvError(description: "mpv_render_context_create(sw): \(api.describe(code))")
        }
        api.renderContextSetUpdateCallback(
            context,
            { waiter in
                guard let waiter else { return }
                Unmanaged<MpvWaiter>.fromOpaque(waiter).takeUnretainedValue().signal()
            }, Unmanaged.passUnretained(waiter).toOpaque())
        return context
    }

    struct Opened {
        var duration: Double
    }

    /// Waits for the file to open. Nil when mpv can't decode its video: it plays the audio of a file
    /// whose video decoder is missing and raises no error, so an empty `video-codec` means failed.
    func open() -> Opened? {
        guard waiter.wait(timeout: Self.timeout, until: { waiter.loaded }) else { return nil }
        guard let codec = core.string("video-codec"), !codec.isEmpty, let render else { return nil }
        // The load shows its own first frame, paused. Waiting for it here keeps its restart and its
        // frame from being taken for a later seek's.
        let api = core.api
        frameSeen = false
        guard
            waiter.wait(
                timeout: Self.timeout,
                poll: {
                    if api.renderContextUpdate(render) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                        frameSeen = true
                    }
                },
                until: { waiter.restarts > 0 && frameSeen })
        else { return nil }
        return Opened(duration: core.double("duration") ?? 0)
    }

    /// The frame at the keyframe nearest `seconds`, upright and at most `maxPixelSize` on its long edge.
    func frame(at seconds: Double, maxPixelSize: Int) -> CGImage? {
        frameAndTime(at: seconds, maxPixelSize: maxPixelSize)?.image
    }

    /// The same, with the time of the frame it found.
    func frameAndTime(at seconds: Double, maxPixelSize: Int) -> (image: CGImage, time: Double)? {
        guard let render, !waiter.isAborted else { return nil }
        let api = core.api
        let mark = waiter.restarts
        frameSeen = false
        core.command(["seek", String(format: "%.3f", max(0, seconds)), "absolute+keyframes"])
        let ready = waiter.wait(
            timeout: Self.timeout,
            poll: {
                if api.renderContextUpdate(render) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                    frameSeen = true
                }
            },
            until: { waiter.restarts > mark && frameSeen })
        guard ready, let size = displaySize(maxPixelSize: maxPixelSize),
            let image = draw(render, width: size.width, height: size.height)
        else { return nil }
        return (image, core.double("time-pos") ?? seconds)
    }

    /// The picture's size as shown, after the pixel aspect and rotation, fitted to `maxPixelSize`.
    private func displaySize(maxPixelSize: Int) -> (width: Int, height: Int)? {
        guard var width = core.int("video-out-params/dw"), var height = core.int("video-out-params/dh"),
            width > 0, height > 0
        else { return nil }
        let rotation = core.int("video-out-params/rotate") ?? 0
        if rotation == 90 || rotation == 270 { swap(&width, &height) }
        let scale = min(1, Double(maxPixelSize) / Double(max(width, height)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    private func draw(_ render: OpaquePointer, width: Int, height: Int) -> CGImage? {
        // Both the stride and the pointer at multiples of 64, which keeps mpv on its fast path.
        let stride = (width * 4 + 63) & ~63
        let count = stride * height
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
        var size: [Int32] = [Int32(width), Int32(height)]
        var bytesPerRow = stride
        let code: Int32 = "rgb0".withCString { format in
            size.withUnsafeMutableBufferPointer { sizePointer in
                withUnsafeMutablePointer(to: &bytesPerRow) { stridePointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizePointer.baseAddress),
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return core.api.renderContextRender(render, &params)
                }
            }
        }
        guard code >= 0 else {
            pixels.deallocate()
            return nil
        }
        let data = Data(bytesNoCopy: pixels, count: count, deallocator: .custom { pointer, _ in pointer.deallocate() })
        guard let provider = CGDataProvider(data: data as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Makes a wait under way give up, from any thread.
    func abort() {
        provider.cancel()
        waiter.abort()
    }

    /// Frees the render context, then the core. Blocks until mpv has stopped.
    func close() {
        guard !closed else { return }
        closed = true
        provider.cancel()
        waiter.abort()
        if let render {
            core.api.renderContextSetUpdateCallback(render, nil, nil)
            core.api.renderContextFree(render)
            self.render = nil
        }
        core.destroy()
    }

    deinit { close() }
}

/// Video frames for stored thumbnails, from mpv, for the formats AVFoundation can't open.
public struct MpvThumbnailer: VideoThumbnailing {
    public init() {}

    /// Whether this build carries Photon's libmpv.
    public static var isAvailable: Bool { MpvLibrary.shared != nil }

    public func canThumbnail(fileExtension: String) -> Bool {
        Self.isAvailable && MpvEngine.formats.contains(fileExtension.lowercased())
    }

    public func poster(
        of instance: FileInstance, scheduler: VolumeIOScheduler, priority: IOPriority, maxPixelSize: Int
    ) async throws -> CGImage? {
        guard let api = MpvLibrary.shared else { return nil }
        let source = VideoSource(instance, scheduler: scheduler)
        let provider = ScheduledByteProvider(source: source, priority: priority)
        let image = try await Self.run(provider: provider) { () throws -> CGImage? in
            let grabber = try MpvFrameGrabber(api: api, provider: provider, fileExtension: source.fileExtension)
            defer { grabber.close() }
            guard let opened = grabber.open() else { return nil }
            return grabber.frame(at: VideoPoster.time(duration: opened.duration), maxPixelSize: maxPixelSize)
        }
        try Task.checkCancellation()
        // A read that failed for the drive's sake says nothing about the file.
        if image == nil, let error = provider.readError { throw error }
        return image
    }

    /// Runs blocking mpv work on the frames queue, and cancels its reads when the task is cancelled.
    static func run<T: Sendable>(
        provider: any MpvByteProvider, _ work: @escaping @Sendable () throws -> T?
    ) async throws -> T? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                MpvFrameGrabber.queue.async {
                    continuation.resume(with: Result { try? work() })
                }
            }
        } onCancel: {
            provider.cancel()
        }
    }
}

/// AVFoundation first, then mpv, for stored thumbnails. mpv also takes what AVFoundation opened but
/// couldn't decode, such as a MOV holding a codec only FFmpeg knows.
public struct StandardVideoThumbnailer: VideoThumbnailing {
    private let primary = AVFoundationThumbnailer()
    private let fallback = MpvThumbnailer()

    public init() {}

    public func canThumbnail(fileExtension: String) -> Bool {
        primary.canThumbnail(fileExtension: fileExtension) || fallback.canThumbnail(fileExtension: fileExtension)
    }

    public func poster(
        of instance: FileInstance, scheduler: VolumeIOScheduler, priority: IOPriority, maxPixelSize: Int
    ) async throws -> CGImage? {
        let fileExtension = instance.path.fileExtension
        if primary.canThumbnail(fileExtension: fileExtension) {
            if let image = try await primary.poster(
                of: instance, scheduler: scheduler, priority: priority, maxPixelSize: maxPixelSize)
            {
                return image
            }
            guard MpvThumbnailer.isAvailable else { return nil }
        }
        return try await fallback.poster(
            of: instance, scheduler: scheduler, priority: priority, maxPixelSize: maxPixelSize)
    }
}

/// Metadata for every container: Photon's own QuickTime parser first, then FFmpeg's demuxers through
/// mpv for the rest, reading from the indexer's open file, so through the scheduler.
public struct StandardMetadataReader: MetadataExtracting {
    private let base = MediaMetadataReader()

    public init() {}

    public func metadata(kind: MediaKind, fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
        if let metadata = try base.metadata(kind: kind, fileExtension: fileExtension, from: source) {
            return metadata
        }
        let lowered = fileExtension.lowercased()
        guard kind == .video, MpvEngine.formats.contains(lowered), let api = MpvLibrary.shared else { return nil }
        let provider = ByteSourceProvider(source)
        let metadata = MpvMetadata.read(api: api, provider: provider, fileExtension: lowered)
        if let error = provider.readError { throw error }
        return metadata
    }
}

enum MpvMetadata {
    /// Opens the file and reads what the demuxer found, from mpv's `on_preloaded` hook, which runs after
    /// the file is open and before any track is selected, so nothing decodes.
    static func read(api: MpvLibrary, provider: any MpvByteProvider, fileExtension: String) -> MediaMetadata? {
        let waiter = MpvWaiter()
        guard
            let core = try? MpvCore(
                api: api,
                options: [
                    // No track is ever selected, so once the hook continues the file ends, with nothing
                    // decoded.
                    ("vo", "null"), ("ao", "null"), ("vid", "no"), ("aid", "no"), ("sid", "no"), ("pause", "yes"),
                    ("demuxer-readahead-secs", "0"), ("cache", "no"),
                    // FFmpeg's demuxers for every container, because mpv's own Matroska demuxer leaves
                    // out the date the file was made.
                    ("demuxer", "lavf"),
                ])
        else { return nil }
        defer { core.destroy() }
        core.register(provider)
        core.addHook("on_preloaded")
        guard (try? core.start(handler: { waiter.handle($0) })) != nil else { return nil }
        core.command(["loadfile", MpvStreamRegistration.url(fileExtension: fileExtension)])
        guard waiter.wait(timeout: MpvFrameGrabber.timeout, until: { waiter.preloaded != nil }),
            let hook = waiter.preloaded
        else { return nil }
        // mpv waits in the hook until it's continued. A command here would wait on mpv in turn, so
        // only properties are read until then.
        defer { core.continueHook(hook) }

        var metadata = MediaMetadata()
        if let duration = core.double("duration"), duration.isFinite, duration > 0 {
            metadata.durationSeconds = duration
        }
        let tracks = core.int("track-list/count") ?? 0
        for index in 0..<tracks where core.string("track-list/\(index)/type") == "video" {
            // Cover art in Matroska is a video track too, of one picture.
            if core.string("track-list/\(index)/image") == "yes" { continue }
            guard let width = core.int("track-list/\(index)/demux-w"),
                let height = core.int("track-list/\(index)/demux-h"), width > 0, height > 0
            else { continue }
            let aspect = core.double("track-list/\(index)/demux-par") ?? 1
            metadata.pixelWidth = Int((Double(width) * (aspect > 0 ? aspect : 1)).rounded())
            metadata.pixelHeight = Int(height)
            metadata.orientation = orientation(degrees: core.int("track-list/\(index)/demux-rotation") ?? 0)
            break
        }
        if let created = core.string("metadata/by-key/creation_time"),
            let date = captureDate(created)
        {
            metadata.captureDate = date
        }
        return metadata == MediaMetadata() ? nil : metadata
    }

    /// mpv's rotation is clockwise, in degrees.
    static func orientation(degrees: Int64) -> Int {
        switch (degrees % 360 + 360) % 360 {
        case 90: 6
        case 180: 3
        case 270: 8
        default: 1
        }
    }

    /// FFmpeg gives dates as ISO 8601 in UTC, such as `2024-05-01T12:30:00.000000Z`. Like the QuickTime
    /// parser, a date before 1971 counts as missing, because encoders write zero for no date.
    static func captureDate(_ text: String) -> CaptureDate? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: text)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: text)
        }
        if date == nil {
            // Matroska's DATE_UTC is often written with a space and no zone.
            formatter.formatOptions = [.withFullDate, .withSpaceBetweenDateAndTime, .withTime, .withColonSeparatorInTime]
            date = formatter.date(from: text)
        }
        guard let date, date.timeIntervalSince1970 > 365 * 86_400 else { return nil }
        return CaptureDate(wallClockMilliseconds: Int64(date.timeIntervalSince1970 * 1000), utcOffsetMinutes: 0)
    }
}
