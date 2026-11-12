import CMpv
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import Synchronization

/// Bytes for mpv, which asks for them on its own threads and waits for the answer.
///
/// mpv gets a `photon://` URL, never a path, and every byte it reads comes through here by way of
/// libmpv's `stream_cb` API. FFmpeg is built with no protocols at all, so neither can open a file by
/// itself.
protocol MpvByteProvider: AnyObject, Sendable {
    var size: Int64 { get }
    /// Copies up to `count` bytes from `offset` into `buffer`, blocking until they're read. Returns the
    /// number copied, zero at the end, or nil when reading failed or was cancelled.
    func read(offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int?
    /// Makes the read under way, and every read after it, fail at once.
    func cancel()
}

/// One registration of the `photon` protocol with a core, and the C callbacks mpv calls.
final class MpvStreamRegistration {
    static let scheme = "photon"
    let provider: any MpvByteProvider

    init(provider: any MpvByteProvider) { self.provider = provider }

    /// One open stream, with its own position. mpv may open the URL more than once while probing.
    final class Cookie {
        let provider: any MpvByteProvider
        var position: Int64 = 0
        init(provider: any MpvByteProvider) { self.provider = provider }
    }

    /// A URL that carries nothing of the file's location. The extension helps FFmpeg's probing.
    static func url(fileExtension: String) -> String {
        "\(scheme)://video.\(fileExtension.isEmpty ? "bin" : fileExtension)"
    }

    static let open: mpv_stream_cb_open_ro_fn = { userData, _, info in
        guard let userData, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
        let registration = Unmanaged<MpvStreamRegistration>.fromOpaque(userData).takeUnretainedValue()
        let cookie = Cookie(provider: registration.provider)
        info.pointee.cookie = Unmanaged.passRetained(cookie).toOpaque()
        info.pointee.read_fn = { cookie, buffer, count in
            guard let cookie, let buffer else { return -1 }
            let stream = Unmanaged<Cookie>.fromOpaque(cookie).takeUnretainedValue()
            guard let read = stream.provider.read(offset: stream.position, into: buffer, count: Int(count)) else {
                return -1
            }
            stream.position += Int64(read)
            return Int64(read)
        }
        info.pointee.seek_fn = { cookie, offset in
            guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
            let stream = Unmanaged<Cookie>.fromOpaque(cookie).takeUnretainedValue()
            guard offset >= 0, offset <= stream.provider.size else { return Int64(MPV_ERROR_GENERIC.rawValue) }
            stream.position = offset
            return offset
        }
        info.pointee.size_fn = { cookie in
            guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
            return Unmanaged<Cookie>.fromOpaque(cookie).takeUnretainedValue().provider.size
        }
        info.pointee.close_fn = { cookie in
            guard let cookie else { return }
            Unmanaged<Cookie>.fromOpaque(cookie).release()
        }
        info.pointee.cancel_fn = { cookie in
            guard let cookie else { return }
            Unmanaged<Cookie>.fromOpaque(cookie).takeUnretainedValue().provider.cancel()
        }
        return 0
    }
}

/// Reads a library file through its volume's I/O scheduler, for playback and frames.
///
/// Each miss is one job: open the file, check it's the one the library has, read a block, check again,
/// close. No handle stays open between reads, so `willUnmount` finds nothing to close but a read under
/// way, and suspending the scheduler fails that read at once. Two blocks are kept, which covers mpv's
/// small reads and a demuxer stepping back a little.
final class ScheduledByteProvider: MpvByteProvider, @unchecked Sendable {
    static let blockSize = 1 << 20

    let source: VideoSource
    let priority: IOPriority
    private let lock = NSLock()
    private var blocks: [(offset: Int64, data: Data)] = []
    private var cancelled = false
    private var inFlight: Task<Data, any Error>?
    private var firstError: (any Error)?

    init(source: VideoSource, priority: IOPriority) {
        self.source = source
        self.priority = priority
    }

    var size: Int64 { source.size }

    /// Why reading stopped, when it was for the drive's sake or because the file changed. A playback or
    /// frame that fails after this failed because of the drive, not the file.
    var readError: (any Error)? { lock.withLock { firstError } }

    func cancel() {
        let task = lock.withLock { () -> Task<Data, any Error>? in
            cancelled = true
            return inFlight
        }
        task?.cancel()
    }

    func read(offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int? {
        guard count > 0 else { return 0 }
        guard offset < source.size else { return 0 }
        if let copied = copyCached(offset: offset, into: buffer, count: count) { return copied }

        let start = offset - offset % Int64(Self.blockSize)
        let length = Int(min(Int64(Self.blockSize), source.size - start))
        guard let data = fetch(start: start, length: length) else { return nil }
        lock.withLock {
            blocks.append((start, data))
            if blocks.count > 2 { blocks.removeFirst() }
        }
        return copyCached(offset: offset, into: buffer, count: count) ?? 0
    }

    private func copyCached(offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int? {
        lock.withLock {
            guard
                let block = blocks.last(where: { offset >= $0.offset && offset < $0.offset + Int64($0.data.count) })
            else { return nil }
            let start = Int(offset - block.offset)
            let copied = min(count, block.data.count - start)
            block.data.withUnsafeBytes { bytes in
                buffer.copyMemory(from: bytes.baseAddress! + start, byteCount: copied)
            }
            return copied
        }
    }

    /// Blocks mpv's thread, which is never the main thread, until the scheduler has read the block.
    private func fetch(start: Int64, length: Int) -> Data? {
        let source = source
        let priority = priority
        let done = DispatchSemaphore(value: 0)
        let result = Mutex<Result<Data, any Error>?>(nil)
        let task: Task<Data, any Error>? = lock.withLock {
            guard !cancelled else { return nil }
            let task = Task.detached(priority: priority >= .backgroundMetadata ? .utility : .userInitiated) {
                try await source.scheduler.withFile(source.path, priority: priority) { file in
                    guard file.size == source.size, file.modifiedTime == source.modifiedTime else {
                        throw VideoReadError.fileChanged
                    }
                    let data = try file.read(offset: start, length: length)
                    guard try file.isUnchanged() else { throw VideoReadError.fileChanged }
                    return data
                }
            }
            inFlight = task
            return task
        }
        guard let task else { return nil }
        Task.detached {
            let outcome = await task.result
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        lock.withLock { if inFlight == task { inFlight = nil } }
        switch result.withLock({ $0 }) {
        case .success(let data):
            return data
        case .failure(let error):
            if error is VolumeIOError || error as? VideoReadError == .fileChanged {
                lock.withLock { if firstError == nil { firstError = error } }
            }
            return nil
        case nil:
            return nil
        }
    }
}

/// Reads from a `ByteSource` that a scheduler job already holds open, for metadata during indexing.
///
/// The job's thread waits while mpv reads, so the source is only ever used by one thread at a time.
/// What the source throws is kept, so the caller can throw it again: a removed drive must never look
/// like a file with no metadata.
final class ByteSourceProvider: MpvByteProvider, @unchecked Sendable {
    private let source: any ByteSource
    private let lock = NSLock()
    private var cancelled = false
    private var error: (any Error)?

    init(_ source: any ByteSource) { self.source = source }

    var size: Int64 { source.size }
    var readError: (any Error)? { lock.withLock { error } }

    func cancel() { lock.withLock { cancelled = true } }

    func read(offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int? {
        guard !lock.withLock({ cancelled }) else { return nil }
        do {
            let data = try source.read(offset: offset, length: min(count, 1 << 20))
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { buffer.copyMemory(from: base, byteCount: data.count) }
            }
            return data.count
        } catch {
            lock.withLock { if self.error == nil { self.error = error } }
            return nil
        }
    }
}
