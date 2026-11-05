import Darwin
import Foundation
import PhotonCore
import Synchronization

/// Priorities from docs/PLAN.md, most urgent first.
public enum IOPriority: Int, Sendable, CaseIterable, Comparable {
    case visible = 0
    case ahead
    case userHash
    case backgroundMetadata
    case backgroundWork

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum VolumeIOError: Error, Equatable, Sendable {
    /// The volume is unmounting or gone. This is a normal state, not a failure of the file.
    case volumeUnavailable
    case notFound
    case system(operation: String, code: Int32)
}

/// Counts for one scheduler. Tests use these to prove what a rescan touched.
public struct IOStatistics: Hashable, Sendable {
    public var filesOpened = 0
    public var directoriesListed = 0
    public var bytesRead: Int64 = 0
    public var openHandles = 0
    public init() {}

    func since(_ start: IOStatistics) -> IOStatistics {
        var delta = self
        delta.filesOpened -= start.filesOpened
        delta.directoriesListed -= start.directoriesListed
        delta.bytesRead -= start.bytesRead
        return delta
    }
}

/// What a file looks like right now, from `lstat`.
public struct FileStatus: Hashable, Sendable {
    public var size: Int64
    public var modifiedTime: FileTimestamp
}

/// Every read of a volume goes through its scheduler, which runs at most `concurrency` jobs at once.
///
/// Jobs run on the scheduler's own GCD queue and make blocking calls there. They must never run on
/// Swift's cooperative pool, because a sleeping drive can hold a read for seconds. A job owns its file
/// handle only while it runs, so `suspend()` leaves nothing open once in-flight jobs return. The
/// longest wait is one chunk's `pread`.
public final class VolumeIOScheduler: Sendable {
    /// One `pread` at most. Cancellation is checked between chunks, so this bounds how late it lands.
    static let chunkSize = 1 << 20

    public let mountPoint: String
    public let concurrency: Int
    private let queue: DispatchQueue
    private let state = Mutex(State())
    /// Called with each opened relative path, on the I/O thread. For tests.
    private let observer: (@Sendable (String) -> Void)?
    /// Whether the volume is still mounted. Called on the I/O thread, because it can block.
    private let isAvailable: @Sendable () -> Bool

    /// - Parameter isAvailable: Checks that the mount still exists. An unmounted volume makes every
    ///   path look deleted, so anything that looks missing or empty has to be checked against this.
    public init(
        mountPoint: String, concurrency: Int = 4, isAvailable: @escaping @Sendable () -> Bool = { true },
        observer: (@Sendable (String) -> Void)? = nil
    ) {
        self.mountPoint = mountPoint
        self.concurrency = concurrency
        self.isAvailable = isAvailable
        self.observer = observer
        // Plain concurrent queue. `pump` is what enforces the limit.
        queue = DispatchQueue(label: "app.photon.io", qos: .utility, attributes: .concurrent)
    }

    public var statistics: IOStatistics { state.withLock { $0.statistics } }
    public var isSuspended: Bool { state.withLock { $0.suspended } }

    // MARK: Jobs

    /// Opens a file and runs `body` with it on an I/O thread. The file closes when `body` returns.
    public func withFile<T: Sendable>(
        _ path: RelativePath, priority: IOPriority, _ body: @escaping @Sendable (OpenFile) throws -> T
    ) async throws -> T {
        try await run(priority: priority) { token in
            self.observer?(path.string)
            let file = try OpenFile(path: self.absolute(path.string), token: token, scheduler: self)
            defer { file.close() }
            return try body(file)
        }
    }

    /// Lists a directory, given relative to the volume root.
    public func listDirectory(_ directory: String, priority: IOPriority) async throws -> [DirectoryEntry] {
        try await run(priority: priority) { token in
            self.observer?(directory + "/")
            self.update { $0.directoriesListed += 1 }
            let entries = try DirectoryLister.list(self.absolute(directory), token: token)
            // An empty listing from a dying mount must not read as a folder with nothing in it.
            guard self.isAvailable() else { throw VolumeIOError.volumeUnavailable }
            return entries
        }
    }

    /// `lstat` for one file. Returns nil when it doesn't exist.
    public func status(of path: RelativePath, priority: IOPriority) async throws -> FileStatus? {
        try await run(priority: priority) { token in
            try token.check()
            var info = stat()
            if lstat(self.absolute(path.string), &info) != 0 {
                let code = errno
                if code == ENOENT || code == ENOTDIR {
                    guard self.isAvailable() else { throw VolumeIOError.volumeUnavailable }
                    return nil
                }
                throw VolumeIOError.system(operation: "lstat", code: code)
            }
            return FileStatus(
                size: info.st_size,
                modifiedTime: FileTimestamp(
                    seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec))
        }
    }

    func absolute(_ relative: String) -> String {
        relative.isEmpty ? mountPoint : mountPoint + "/" + relative
    }

    func update(_ change: (inout IOStatistics) -> Void) {
        state.withLock { change(&$0.statistics) }
    }

    private func run<T: Sendable>(
        priority: IOPriority, _ body: @escaping @Sendable (IOToken) throws -> T
    ) async throws -> T {
        let token = IOToken()
        let id = state.withLock { $0.allocateID(token) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    Job(
                        id: id, priority: priority, token: token,
                        run: {
                            let result = Result { try body(token) }.mapError { self.classify($0) }
                            self.finish(id)
                            continuation.resume(with: result)
                        },
                        fail: { continuation.resume(throwing: $0) }))
            }
        } onCancel: {
            cancel(id, token: token)
        }
    }

    /// Any error on a volume that has gone is about the volume, not the file or folder it names.
    private func classify(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        return isAvailable() ? error : VolumeIOError.volumeUnavailable
    }

    private func enqueue(_ job: Job) {
        let refusal: (any Error)? = state.withLock { state in
            if job.token.isCancelled {
                state.forget(job.id)
                return job.token.error
            }
            if state.suspended {
                state.forget(job.id)
                return VolumeIOError.volumeUnavailable
            }
            state.add(job)
            return nil
        }
        if let refusal {
            job.fail(refusal)
        } else {
            pump()
        }
    }

    private func pump() {
        let ready: [Job] = state.withLock { state in
            var jobs: [Job] = []
            while state.running.count < concurrency, let job = state.takeNext() {
                state.running[job.id] = job.token
                jobs.append(job)
            }
            return jobs
        }
        for job in ready {
            let qos: DispatchQoS = job.priority <= .userHash ? .userInitiated : .utility
            queue.async(qos: qos, flags: .enforceQoS, execute: job.run)
        }
    }

    private func finish(_ id: UInt64) {
        state.withLock { state in
            state.running[id] = nil
            state.forget(id)
        }
        pump()
    }

    private func cancel(_ id: UInt64, token: IOToken) {
        token.cancel(.task)
        let job = state.withLock { $0.removeQueued(id) }
        job?.fail(CancellationError())
    }

    // MARK: Volume lifecycle

    /// Fails everything queued and stops in-flight jobs at their next chunk. Call on `willUnmount`.
    /// New jobs fail until `resume()`, because `willUnmount` can precede an unmount that then fails.
    public func suspend() {
        let queued: [Job] = state.withLock { state in
            state.suspended = true
            for token in state.running.values { token.cancel(.suspended) }
            return state.removeAllQueued()
        }
        for job in queued { job.fail(VolumeIOError.volumeUnavailable) }
    }

    public func resume() {
        state.withLock { $0.suspended = false }
    }
}

// MARK: - Internals

private struct Job: Sendable {
    let id: UInt64
    let priority: IOPriority
    let token: IOToken
    let run: @Sendable () -> Void
    let fail: @Sendable (any Error) -> Void
}

private struct State {
    /// FIFO per priority. An id may stay here after its job is cancelled, and `takeNext` skips it.
    var queues = [[UInt64]](repeating: [], count: IOPriority.allCases.count)
    var heads = [Int](repeating: 0, count: IOPriority.allCases.count)
    var queued: [UInt64: Job] = [:]
    var running: [UInt64: IOToken] = [:]
    var tokens: [UInt64: IOToken] = [:]
    var suspended = false
    var nextID: UInt64 = 1
    var statistics = IOStatistics()

    mutating func allocateID(_ token: IOToken) -> UInt64 {
        defer { nextID += 1 }
        tokens[nextID] = token
        return nextID
    }

    mutating func forget(_ id: UInt64) { tokens[id] = nil }

    mutating func add(_ job: Job) {
        queued[job.id] = job
        queues[job.priority.rawValue].append(job.id)
    }

    mutating func takeNext() -> Job? {
        for index in queues.indices {
            while heads[index] < queues[index].count {
                let id = queues[index][heads[index]]
                heads[index] += 1
                if heads[index] == queues[index].count {
                    queues[index].removeAll(keepingCapacity: true)
                    heads[index] = 0
                }
                if let job = queued.removeValue(forKey: id) { return job }
            }
        }
        return nil
    }

    mutating func removeQueued(_ id: UInt64) -> Job? {
        guard let job = queued.removeValue(forKey: id) else { return nil }
        forget(id)
        return job
    }

    mutating func removeAllQueued() -> [Job] {
        let jobs = Array(queued.values)
        for job in jobs { forget(job.id) }
        queued.removeAll()
        for index in queues.indices {
            queues[index].removeAll()
            heads[index] = 0
        }
        return jobs
    }
}

/// Tells a job to stop. Checked between chunks, because a blocking read can't be interrupted.
final class IOToken: Sendable {
    enum Reason: Int { case none = 0, task, suspended }
    private let reason = Atomic<Int>(0)

    func cancel(_ newReason: Reason) {
        // Suspension wins, so that a job stopped by both reports the volume state.
        reason.max(newReason.rawValue, ordering: .relaxed)
    }

    var isCancelled: Bool { reason.load(ordering: .relaxed) != 0 }

    var error: any Error {
        reason.load(ordering: .relaxed) == Reason.suspended.rawValue
            ? VolumeIOError.volumeUnavailable : CancellationError()
    }

    func check() throws {
        if isCancelled { throw error }
    }
}

/// An open file, valid only inside the job that opened it.
public final class OpenFile: ByteSource {
    private var descriptor: Int32
    private let token: IOToken
    private let scheduler: VolumeIOScheduler
    public let size: Int64
    public let modifiedTime: FileTimestamp

    init(path: String, token: IOToken, scheduler: VolumeIOScheduler) throws {
        try token.check()
        // O_NOFOLLOW, because enumeration doesn't follow symlinks and a job shouldn't either.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ENOENT || code == ENOTDIR
                ? VolumeIOError.notFound : VolumeIOError.system(operation: "open", code: code)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw VolumeIOError.system(operation: "fstat", code: code)
        }
        // Background reads shouldn't push the user's apps out of the file cache.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        self.descriptor = descriptor
        self.token = token
        self.scheduler = scheduler
        size = info.st_size
        modifiedTime = FileTimestamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        scheduler.update {
            $0.filesOpened += 1
            $0.openHandles += 1
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
        scheduler.update { $0.openHandles -= 1 }
    }

    deinit { close() }

    /// Whether the file still has the size and modified time it had when opened.
    public func isUnchanged() throws -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw VolumeIOError.system(operation: "fstat", code: errno)
        }
        return info.st_size == size
            && FileTimestamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec) == modifiedTime
    }

    public func read(offset: Int64, length: Int) throws -> Data {
        let wanted = Int(min(Int64(length), max(0, size - offset)))
        guard wanted > 0 else {
            try token.check()
            return Data()
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: wanted, alignment: 16)
        var filled = 0
        do {
            while filled < wanted {
                try token.check()
                let count = pread(
                    descriptor, buffer + filled, min(wanted - filled, VolumeIOScheduler.chunkSize),
                    off_t(offset) + off_t(filled))
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw VolumeIOError.system(operation: "read", code: code)
                }
                if count == 0 { break }
                filled += count
            }
        } catch {
            buffer.deallocate()
            throw error
        }
        let total = filled
        scheduler.update { $0.bytesRead += Int64(total) }
        return Data(bytesNoCopy: buffer, count: filled, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }
}
