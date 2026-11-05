import Foundation
import PhotonCore
import Synchronization
import os

public enum IndexingError: Error, Equatable, Sendable {
    /// Refused by `MountPolicy`.
    case refused(String)
    /// The library sits on the volume being indexed. Photon never writes to a user's drive.
    case libraryOnScannedVolume
    case alreadyIndexing
    /// A clone is mounted alongside its original.
    case duplicateVolume(VolumeID)
    /// The file isn't the one that was enumerated. The next rescan picks it up.
    case fileChanged
}

extension IndexingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .refused(let reason): reason
        case .libraryOnScannedVolume: "The library can't be stored on the drive being indexed."
        case .alreadyIndexing: "This volume is already being indexed."
        case .duplicateVolume: "A copy of this drive is already connected. Disconnect one of them."
        case .fileChanged: "The file changed while it was being read."
        }
    }
}

public struct IndexOptions: Sendable {
    /// Files read and committed together. Results reach the database at the end of each batch.
    public var batchSize = 128
    /// Read attempts for one file before it stops being retried.
    public var maxAttempts = 3
    /// How long to wait for a `willUnmount` to turn into an unmount before resuming work.
    public var unmountGracePeriod: Duration = .seconds(5)
    public var concurrency = 4
    public init() {}
}

public enum IndexOutcome: String, Hashable, Sendable {
    case completed
    case cancelled
    /// The volume went away during the run, which isn't an error. The next run resumes.
    case volumeOffline
}

public struct IndexReport: Hashable, Sendable {
    public var outcome = IndexOutcome.completed
    public var volumeID: VolumeID?
    public var isNewVolume = false
    public var scan = ScanReport()
    /// Files read and recorded during this run.
    public var processed = 0
    /// Files that hit an error during this run.
    public var failed = 0
    public var identity = IdentityCounts()
    public var scanSeconds = 0.0
    public var processSeconds = 0.0
    /// What this run read. `openHandles` is what was open when it ended.
    public var io = IOStatistics()
    public init() {}
}

public enum IndexProgress: Sendable {
    case scanning(ScanReport)
    case processing(processed: Int)
}

/// Runs indexing for mounted volumes: resolve the volume, enumerate its roots, then read what's pending.
///
/// Nothing here runs on the main thread. A run can stop at any point, because everything left to do
/// is stored as pending rows, and the next run carries on from them.
public final class LibraryIndexer: Sendable {
    private let store: LibraryStore
    private let extractor: any MetadataExtracting
    private let options: IndexOptions
    private let sessions = Mutex<[String: MountSession]>([:])
    private let observer: (@Sendable (String) -> Void)?

    private static let signposter = OSSignposter(subsystem: Signposts.subsystem, category: "Indexer")

    /// - Parameter observer: Called with each path the I/O layer opens. For tests.
    public init(
        store: LibraryStore, extractor: any MetadataExtracting, options: IndexOptions = IndexOptions(),
        observer: (@Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.extractor = extractor
        self.options = options
        self.observer = observer
    }

    private final class MountSession: Sendable {
        let mount: MountedVolume
        let scheduler: VolumeIOScheduler
        let volume: VolumeID
        let isNew: Bool
        let isRunning = Atomic<Bool>(false)

        init(mount: MountedVolume, scheduler: VolumeIOScheduler, volume: VolumeID, isNew: Bool) {
            self.mount = mount
            self.scheduler = scheduler
            self.volume = volume
            self.isNew = isNew
        }
    }

    // MARK: Running

    /// Adds `path` as a root and indexes it. Safe to call again: a rescan touches only what changed.
    public func index(
        path: String, progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexReport {
        let (mount, relativePath) = try await onIOThread { try MountedVolume.containing(path: path) }
        return try await index(mount: mount, roots: [relativePath], progress: progress)
    }

    /// Rescans every root stored for this mount's volume.
    public func rescan(
        mount: MountedVolume, progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexReport {
        try await index(mount: mount, roots: [], progress: progress)
    }

    private func index(
        mount: MountedVolume, roots: [String], progress: (@Sendable (IndexProgress) -> Void)?
    ) async throws -> IndexReport {
        if let reason = MountPolicy.refusalReason(for: mount) { throw IndexingError.refused(reason) }
        try await ensureLibraryIsOff(mount)

        let session = try await session(for: mount)
        guard session.isRunning.exchange(true, ordering: .acquiringAndReleasing) == false else {
            throw IndexingError.alreadyIndexing
        }
        defer { session.isRunning.store(false, ordering: .releasing) }

        for root in roots { try await store.addRoot(volume: session.volume, relativePath: root) }
        let storedRoots = try await store.roots(volume: session.volume)

        let startingIO = session.scheduler.statistics
        while true {
            var report = try await runOnce(session: session, roots: storedRoots, progress: progress)
            report.volumeID = session.volume
            report.isNewVolume = session.isNew
            report.io = session.scheduler.statistics.since(startingIO)
            guard report.outcome == .volumeOffline else { return report }
            // Either the unmount is real, or it was refused and `willUnmount` was a false alarm.
            while session.scheduler.isSuspended, await isMounted(session), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !session.scheduler.isSuspended, await isMounted(session), !Task.isCancelled else {
                return report
            }
        }
    }

    private func isMounted(_ session: MountSession) async -> Bool {
        (try? await onIOThread { session.mount.isStillMounted() }) ?? false
    }

    private func runOnce(
        session: MountSession, roots: [LibraryRoot], progress: (@Sendable (IndexProgress) -> Void)?
    ) async throws -> IndexReport {
        var report = IndexReport()
        let clock = ContinuousClock()
        var stageStart = clock.now
        do {
            let scanner = VolumeScanner(
                store: store, scheduler: session.scheduler, volume: session.volume,
                progress: progress.map { callback in { @Sendable in callback(.scanning($0)) } })
            for root in roots {
                let scan = try await scanner.scan(root: root.relativePath)
                report.scan.directories += scan.directories
                report.scan.added += scan.added
                report.scan.modified += scan.modified
                report.scan.removed += scan.removed
                report.scan.unchanged += scan.unchanged
                report.scan.unreadableDirectories += scan.unreadableDirectories
                try await store.markRootScanned(root)
            }
            report.scanSeconds = (clock.now - stageStart) / .seconds(1)

            stageStart = clock.now
            try await processPending(session: session, report: &report, progress: progress)
            report.processSeconds = (clock.now - stageStart) / .seconds(1)
        } catch is CancellationError {
            report.processSeconds = (clock.now - stageStart) / .seconds(1)
            report.outcome = .cancelled
        } catch VolumeIOError.volumeUnavailable {
            report.processSeconds = (clock.now - stageStart) / .seconds(1)
            report.outcome = .volumeOffline
        }
        // Anything else, such as a full internal disk, is a real failure, and the caller should see it.
        return report
    }

    // MARK: Metadata and hashing

    private enum FileOutcome: Sendable {
        case indexed(IndexedFile)
        /// The file changed or vanished since enumeration. It stays pending for the next rescan.
        case skipped
        case failed(FileInstanceID, String)
        /// Stop the run. This isn't about this file.
        case interrupted(any Error)
    }

    private func processPending(
        session: MountSession, report: inout IndexReport, progress: (@Sendable (IndexProgress) -> Void)?
    ) async throws {
        var cursor: FileInstanceID?
        while true {
            try Task.checkCancellation()
            let page = try await store.pendingInstances(
                volume: session.volume, after: cursor, limit: options.batchSize)
            guard let last = page.last else { return }
            cursor = last.id

            let interval = Self.signposter.beginInterval("Read batch", "\(page.count) files")
            let outcomes = await withTaskGroup(of: FileOutcome.self, returning: [FileOutcome].self) { group in
                for instance in page {
                    group.addTask { await self.process(instance, session: session) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            Self.signposter.endInterval("Read batch", interval)

            // Results that finished before an interruption are real work, so they're kept.
            var indexed: [IndexedFile] = []
            var interruption: (any Error)?
            for outcome in outcomes {
                switch outcome {
                case .indexed(let file):
                    indexed.append(file)
                case .skipped:
                    break
                case .failed(let id, let message):
                    report.failed += 1
                    try await store.recordIndexFailure(id, message: message, maxAttempts: options.maxAttempts)
                case .interrupted(let error):
                    interruption = interruption ?? error
                }
            }
            let identity = try await store.applyIndexed(indexed)
            report.processed += indexed.count
            report.identity.hashed += identity.hashed
            report.identity.merged += identity.merged
            report.identity.rehashed += identity.rehashed
            report.identity.reassigned += identity.reassigned
            report.identity.stale += identity.stale
            progress?(.processing(processed: report.processed))
            if let interruption { throw interruption }
        }
    }

    private func process(_ instance: FileInstance, session: MountSession) async -> FileOutcome {
        let extractor = extractor
        do {
            let kind = MediaKind(fileExtension: instance.path.fileExtension) ?? .photo
            let extensionName = instance.path.fileExtension
            let file = try await session.scheduler.withFile(instance.path, priority: .backgroundMetadata) { file in
                guard file.size == instance.size, file.modifiedTime == instance.modifiedTime else {
                    throw IndexingError.fileChanged
                }
                let source = PrefixCachingSource(file)
                let metadata = try extractor.metadata(kind: kind, fileExtension: extensionName, from: source)
                let hash = try ContentHasher.hash(source)
                guard try file.isUnchanged() else { throw IndexingError.fileChanged }
                return IndexedFile(
                    instanceID: instance.id, size: file.size, modifiedTime: file.modifiedTime, hash: hash,
                    metadata: metadata)
            }
            return .indexed(file)
        } catch is CancellationError {
            return .interrupted(CancellationError())
        } catch VolumeIOError.volumeUnavailable {
            return .interrupted(VolumeIOError.volumeUnavailable)
        } catch IndexingError.fileChanged {
            return .skipped
        } catch VolumeIOError.notFound {
            return .skipped
        } catch {
            return .failed(instance.id, String(describing: error))
        }
    }

    // MARK: Volumes

    /// Call on `willUnmount`. Cancels all work and lets every handle close, without blocking.
    ///
    /// `willUnmount` also fires before an unmount that then fails, so work resumes if the volume is
    /// still mounted after the grace period.
    public func volumeWillUnmount(mountPoint: String) {
        guard let session = sessions.withLock({ $0[mountPoint] }) else { return }
        session.scheduler.suspend()
        let grace = options.unmountGracePeriod
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: grace)
            if session.mount.isStillMounted() {
                session.scheduler.resume()
            } else {
                sessions.withLock { if $0[mountPoint] === session { $0[mountPoint] = nil } }
            }
        }
    }

    /// Call on `didUnmount`.
    public func volumeDidUnmount(mountPoint: String) {
        let session = sessions.withLock { $0.removeValue(forKey: mountPoint) }
        session?.scheduler.suspend()
    }

    /// Volumes in use this session, by mount point.
    public func onlineVolumes() -> [String: VolumeID] {
        sessions.withLock { $0.mapValues(\.volume) }
    }

    private func session(for mount: MountedVolume) async throws -> MountSession {
        // A session for a mount that has gone isn't reusable, and it mustn't count as online.
        // The mount checks stay outside the lock: they can block, and `willUnmount` needs that lock.
        let known = sessions.withLock { $0 }
        let live = try await onIOThread { known.filter { $0.value.mount.isStillMounted() } }
        sessions.withLock { sessions in
            for (mountPoint, session) in known where live[mountPoint] == nil && sessions[mountPoint] === session {
                sessions[mountPoint] = nil
            }
        }
        if let existing = live[mount.mountPoint], existing.mount == mount { return existing }

        let scheduler = VolumeIOScheduler(
            mountPoint: mount.mountPoint, concurrency: options.concurrency,
            isAvailable: { mount.isStillMounted() }, observer: observer)
        let resolver = VolumeResolver(store: store)
        let online = Set(live.values.map(\.volume))
        switch try await resolver.resolve(mount, scheduler: scheduler, online: online) {
        case .duplicateOfOnlineVolume(let volume):
            throw IndexingError.duplicateVolume(volume)
        case .online(let volume, let isNew):
            let session = MountSession(mount: mount, scheduler: scheduler, volume: volume.id, isNew: isNew)
            sessions.withLock { $0[mount.mountPoint] = session }
            return session
        }
    }

    /// Photon's own files must never land on a user's drive.
    private func ensureLibraryIsOff(_ mount: MountedVolume) async throws {
        guard mount.location != .internal else { return }
        let libraryPath = store.databaseURL.deletingLastPathComponent().path
        let libraryVolume = try await onIOThread { try MountedVolume.containing(path: libraryPath).volume }
        if libraryVolume.bsdName == mount.bsdName { throw IndexingError.libraryOnScannedVolume }
    }
}

/// Runs blocking system calls away from the cooperative pool. A sleeping drive can hold them for seconds.
func onIOThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(with: Result { try body() })
        }
    }
}
