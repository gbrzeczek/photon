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
    /// Refuses a writable external volume, as `MountPolicy` describes. Tools leave this on. The app turns
    /// it off, because Photon writes nothing to a drive and a normal external drive is mounted writable.
    public var requiresReadOnlyExternal = true
    /// Injected I/O failures, for tests.
    public var faults: IOFaultInjector?
    public init() {}
}

public enum IndexOutcome: String, Hashable, Sendable {
    case completed
    case cancelled
    /// The volume went away during the run, which isn't an error. The next run resumes.
    case volumeOffline
    /// Reads are failing and the volume can't be listed, though its mount is still there. No file is
    /// blamed, and the next run resumes.
    case volumeFailing
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

/// One mounted volume that `connectKnownVolumes` looked at.
public struct VolumeConnection: Hashable, Sendable {
    public var volume: VolumeID
    public var mount: MountedVolume
    /// False if it was connected already. A newly connected volume wants a rescan.
    public var isNew: Bool
}

/// What `connectKnownVolumes` found.
public struct ConnectionReport: Hashable, Sendable {
    public var connections: [VolumeConnection] = []
    /// Names of clones mounted beside their originals, which stay out of the library this session.
    public var duplicateNames: [String] = []
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
    private let onChange = Mutex<(@Sendable () -> Void)?>(nil)

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

    /// Called, on any thread, when a volume stops or starts being usable without a new mount: a
    /// suspension, a refused unmount that lets work resume, or a mount found to be gone.
    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        onChange.withLock { $0 = handler }
    }

    private func volumesChanged() {
        onChange.withLock { $0 }?()
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
        try checkPolicy(mount)
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
            // A failing volume isn't retried here. Its mount is still there, so this would never end.
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
        } catch let error as VolumeIOError where error.isDeviceFailure {
            report.processSeconds = (clock.now - stageStart) / .seconds(1)
            report.outcome = .volumeFailing
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
        /// The device failed rather than the file, as far as anyone can tell yet.
        case deviceFailure(FileInstanceID, VolumeIOError)
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
            var deviceFailures: [(FileInstanceID, VolumeIOError)] = []
            for outcome in outcomes {
                switch outcome {
                case .indexed(let file):
                    indexed.append(file)
                case .skipped:
                    break
                case .failed(let id, let message):
                    report.failed += 1
                    try await store.recordIndexFailure(id, message: message, maxAttempts: options.maxAttempts)
                case .deviceFailure(let id, let error):
                    deviceFailures.append((id, error))
                case .interrupted(let error):
                    interruption = interruption ?? error
                }
            }
            // A whole batch failing looks like the drive, so the drive gets asked. If it can still list its
            // root, the files really are bad. A single bad sector costs one file, not the run.
            if let (_, error) = deviceFailures.first, indexed.isEmpty, interruption == nil,
                await !canListRoot(session)
            {
                interruption = error
            } else if interruption == nil {
                for (id, error) in deviceFailures {
                    report.failed += 1
                    try await store.recordIndexFailure(
                        id, message: String(describing: error), maxAttempts: options.maxAttempts)
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

    private func canListRoot(_ session: MountSession) async -> Bool {
        (try? await session.scheduler.listDirectory("", priority: .userHash)) != nil
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
        } catch let error as VolumeIOError where error.isDeviceFailure {
            return .deviceFailure(instance.id, error)
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
        volumesChanged()
        let grace = options.unmountGracePeriod
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: grace)
            // Checked away from the cooperative pool, because a dying drive can hold this.
            let isMounted = await isMounted(session)
            let isCurrent = sessions.withLock { $0[mountPoint] === session }
            guard isCurrent else { return }
            if isMounted {
                session.scheduler.resume()
            } else {
                sessions.withLock { if $0[mountPoint] === session { $0[mountPoint] = nil } }
            }
            volumesChanged()
        }
    }

    /// Call on `didUnmount`. A new volume may already be at this path, so only a mount that has really
    /// gone is dropped.
    public func volumeDidUnmount(mountPoint: String) {
        guard let session = sessions.withLock({ $0[mountPoint] }) else { return }
        Task.detached(priority: .utility) { [self] in
            guard await !isMounted(session) else { return }
            session.scheduler.suspend()
            drop(session, at: mountPoint)
        }
    }

    /// The volume's mount point moved, which is what renaming a volume does. The old session can't reach
    /// anything now, and the next connection makes a new one.
    public func volumeDidRename(from oldMountPoint: String) {
        guard let session = sessions.withLock({ $0[oldMountPoint] }) else { return }
        session.scheduler.suspend()
        drop(session, at: oldMountPoint)
    }

    private func drop(_ session: MountSession, at mountPoint: String) {
        let removed = sessions.withLock { sessions in
            guard sessions[mountPoint] === session else { return false }
            sessions[mountPoint] = nil
            return true
        }
        if removed { volumesChanged() }
    }

    // MARK: Eject

    /// Ejects an online volume, as the user's command. Stops all Photon's work on the disk first and
    /// waits for its handles to close, because an open handle blocks the unmount. If the eject fails,
    /// the volume is still mounted and work resumes.
    public func eject(_ volume: VolumeID, using ejector: VolumeEjector) async throws {
        let found = sessions.withLock { sessions in
            sessions.first { $0.value.volume == volume }
        }
        guard let (mountPoint, session) = found else { throw EjectError.notConnected }
        if let reason = ejector.refusal(for: session.mount) { throw EjectError.refused(reason) }

        // Other volumes on the same disk go with it.
        let disk = session.mount.wholeDiskName
        let affected = sessions.withLock { sessions in
            sessions.filter { $0.value.mount.wholeDiskName == disk }
        }
        for sibling in affected.values { sibling.scheduler.suspend() }
        volumesChanged()
        for sibling in affected.values { _ = await sibling.scheduler.waitUntilIdle(timeout: .seconds(2)) }

        do {
            try await ejector.eject(session.mount)
        } catch {
            for sibling in affected.values { sibling.scheduler.resume() }
            volumesChanged()
            throw error
        }
        for (path, sibling) in affected { drop(sibling, at: path) }
        drop(session, at: mountPoint)
    }

    /// The mounted volume behind an online volume.
    public func mount(of volume: VolumeID) -> MountedVolume? {
        sessions.withLock { sessions in
            sessions.values.first { $0.volume == volume }?.mount
        }
    }

    /// What can be done with a volume's files now. Suspended counts as offline, because nothing can be
    /// read until the unmount has settled either way.
    public func access(to volume: VolumeID) -> VolumeAccess {
        sessions.withLock { sessions in
            guard let session = sessions.values.first(where: { $0.volume == volume && !$0.scheduler.isSuspended })
            else { return .offline }
            return session.mount.isReadOnly ? .readOnly : .writable
        }
    }

    /// Connects a mounted volume without scanning it, so that its files can be read.
    /// The same rules as indexing apply: a refused mount stays unconnected.
    @discardableResult
    public func connect(mount: MountedVolume) async throws -> VolumeID {
        try checkPolicy(mount)
        try await ensureLibraryIsOff(mount)
        return try await session(for: mount).volume
    }

    private func checkPolicy(_ mount: MountedVolume) throws {
        guard options.requiresReadOnlyExternal, let reason = MountPolicy.refusalReason(for: mount) else { return }
        throw IndexingError.refused(reason)
    }

    /// Connects every mounted volume the library already knows. Each one reads only what's needed to
    /// recognize it, and a volume that can't be connected is skipped: it just stays offline.
    public func connectKnownVolumes() async throws -> ConnectionReport {
        var report = ConnectionReport()
        let known = Set(try await store.allVolumes().map(\.uuid))
        guard !known.isEmpty else { return report }
        let mounted = try await onIOThread { MountedVolume.all() }
        for mount in mounted where known.contains(mount.uuid) {
            let wasConnected = sessions.withLock { $0[mount.mountPoint]?.mount == mount }
            do {
                let volume = try await connect(mount: mount)
                report.connections.append(VolumeConnection(volume: volume, mount: mount, isNew: !wasConnected))
            } catch IndexingError.duplicateVolume {
                report.duplicateNames.append(mount.name)
            } catch {
                // It stays offline.
            }
        }
        return report
    }

    /// The scheduler for an online volume, or nil when it's offline. All reads of its files go through this.
    public func scheduler(for volume: VolumeID) -> VolumeIOScheduler? {
        sessions.withLock { sessions in
            sessions.values.first { $0.volume == volume && !$0.scheduler.isSuspended }?.scheduler
        }
    }

    /// Where an online volume is mounted right now.
    public func mountPoint(of volume: VolumeID) -> String? {
        scheduler(for: volume)?.mountPoint
    }

    /// Volumes that can be read right now, by mount point. A suspended one isn't among them.
    public func onlineVolumes() -> [String: VolumeID] {
        sessions.withLock { sessions in
            sessions.filter { !$0.value.scheduler.isSuspended }.mapValues(\.volume)
        }
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

        let mountPoint = mount.mountPoint
        let scheduler = VolumeIOScheduler(
            mountPoint: mountPoint, concurrency: options.concurrency,
            isAvailable: { mount.isStillMounted() }, observer: observer,
            onLost: { [weak self] in self?.mountWasLost(mountPoint) }, faults: options.faults)
        let resolver = VolumeResolver(store: store)
        let online = Set(live.values.map(\.volume))
        switch try await resolver.resolve(mount, scheduler: scheduler, online: online) {
        case .duplicateOfOnlineVolume(let volume):
            throw IndexingError.duplicateVolume(volume)
        case .online(let volume, let isNew):
            let session = MountSession(mount: mount, scheduler: scheduler, volume: volume.id, isNew: isNew)
            // Two connections can get here together: a mount event and Add Folder, say.
            let installed: MountSession? = sessions.withLock { sessions in
                if let existing = sessions[mount.mountPoint], existing.mount == mount { return existing }
                if sessions.values.contains(where: { $0.volume == volume.id }) { return nil }
                sessions[mount.mountPoint] = session
                return session
            }
            guard let installed else { throw IndexingError.duplicateVolume(volume.id) }
            return installed
        }
    }

    /// A job found the mount gone, and no notification may ever arrive for it.
    private func mountWasLost(_ mountPoint: String) {
        guard let session = sessions.withLock({ $0[mountPoint] }) else { return }
        session.scheduler.suspend()
        drop(session, at: mountPoint)
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
