import Foundation
import PhotonCore
import PhotonIndex
import os

/// Makes thumbnails from originals, on request for tiles on screen and in the background for the rest.
///
/// Every read goes through the volume's I/O scheduler, so it's cancellable, has its priority and never
/// memory-maps. A video's frame comes from `video`, which reads through the same scheduler.
public final class ThumbnailGenerator: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// There may be something new to show.
        case updated
        /// Nothing more can be done: the work is finished, the volume is offline or the file changed.
        case nothing
    }

    private let store: LibraryStore
    private let packs: ThumbnailPackStore
    private let scheduler: @Sendable (VolumeID) -> VolumeIOScheduler?
    private let video: (any VideoThumbnailing)?
    private static let signposter = OSSignposter(subsystem: Signposts.subsystem, category: "Thumbnails")

    /// - Parameters:
    ///   - scheduler: The scheduler for an online volume, or nil when it's offline.
    ///   - video: Frames for videos. Without it, videos stay pending and are never read.
    public init(
        store: LibraryStore, packs: ThumbnailPackStore,
        scheduler: @escaping @Sendable (VolumeID) -> VolumeIOScheduler?, video: (any VideoThumbnailing)? = nil
    ) {
        self.store = store
        self.packs = packs
        self.scheduler = scheduler
        self.video = video
    }

    private enum Stage: Sendable { case preview, full }

    private struct Produced: Sendable {
        var job: ThumbnailJob
        var size: Int64
        var modifiedTime: FileTimestamp
        var state: ThumbnailState
        var set: ThumbnailSet?
    }

    // MARK: On request

    /// Brings one asset up to date, reporting after each stage so that a tile can show the preview
    /// while the full read runs. Throws `CancellationError` when the tile goes away first.
    public func generate(
        asset: AssetID, instance: FileInstanceID, priority: IOPriority,
        progress: @Sendable () -> Void
    ) async throws {
        guard var job = try await store.thumbnailJob(asset: asset, instance: instance),
            let scheduler = scheduler(job.instance.volumeID)
        else { return }

        if job.state == .none {
            if let produced = try await run(.preview, job: job, priority: priority, scheduler: scheduler) {
                try await record([produced])
                if produced.set != nil { progress() }
                job.state = .preview
            } else {
                return
            }
        }
        if job.state == .preview,
            let produced = try await run(.full, job: job, priority: priority, scheduler: scheduler)
        {
            try await record([produced])
            progress()
        }
    }

    // MARK: Background

    public struct BackgroundReport: Sendable, Hashable {
        public var previews = 0
        public var full = 0
        public var failed = 0
        public var seconds = 0.0
        public var outcome = IndexOutcome.completed
        public init() {}
    }

    /// Works through what a volume is missing: embedded previews for everything first, because that's
    /// quick, then full reads. A run can stop at any point, and the next one carries on.
    public func runBackground(
        volume: VolumeID, batchSize: Int = 32,
        progress: (@Sendable (BackgroundReport) -> Void)? = nil
    ) async throws -> BackgroundReport {
        var report = BackgroundReport()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            for (state, stage) in [(ThumbnailState.none, Stage.preview), (.preview, .full)] {
                var cursor: AssetID?
                while true {
                    try Task.checkCancellation()
                    guard let scheduler = scheduler(volume) else { throw VolumeIOError.volumeUnavailable }
                    let page = try await store.pendingThumbnails(
                        volume: volume, state: state, after: cursor, limit: batchSize)
                    guard let last = page.last else { break }
                    cursor = last.assetID

                    let interval = Self.signposter.beginInterval("Background batch", "\(page.count) files")
                    let produced = try await withThrowingTaskGroup(of: Produced?.self) { group in
                        for job in page {
                            group.addTask {
                                try await self.run(stage, job: job, priority: .backgroundWork, scheduler: scheduler)
                            }
                        }
                        return try await group.reduce(into: [Produced]()) { if let item = $1 { $0.append(item) } }
                    }
                    Self.signposter.endInterval("Background batch", interval)

                    try await record(produced)
                    switch stage {
                    case .preview: report.previews += produced.count
                    case .full: report.full += produced.count
                    }
                    report.failed += produced.filter { $0.state == .failed }.count
                    report.seconds = (clock.now - start) / .seconds(1)
                    progress?(report)
                }
            }
            try await packs.enforceLimit()
        } catch is CancellationError {
            report.outcome = .cancelled
        } catch VolumeIOError.volumeUnavailable {
            report.outcome = .volumeOffline
        }
        report.seconds = (clock.now - start) / .seconds(1)
        return report
    }

    // MARK: Stages

    /// Reads one file and makes thumbnails, inside one I/O job. Returns nil when the file changed or
    /// vanished: it stays pending, and a rescan picks it up.
    private func run(
        _ stage: Stage, job: ThumbnailJob, priority: IOPriority, scheduler: VolumeIOScheduler
    ) async throws -> Produced? {
        let instance = job.instance
        if job.kind == .video { return try await runVideo(stage, job: job, priority: priority, scheduler: scheduler) }
        let hasPreview = Thumbnailer.mayHaveEmbeddedPreview(fileExtension: instance.path.fileExtension)
        // Nothing to read for this stage. Skipping the read here is the point of checking the format.
        if stage == .preview, !hasPreview {
            return Produced(
                job: job, size: instance.size, modifiedTime: instance.modifiedTime, state: .preview, set: nil)
        }
        do {
            return try await scheduler.withFile(instance.path, priority: priority) { file in
                guard file.size == instance.size, file.modifiedTime == instance.modifiedTime else {
                    throw IndexingError.fileChanged
                }
                let set: ThumbnailSet?
                let state: ThumbnailState
                switch stage {
                case .preview:
                    set = try Thumbnailer.embeddedPreview(from: file)
                    state = .preview
                case .full:
                    set = try Thumbnailer.fullThumbnails(from: file)
                    state = set == nil ? .failed : .complete
                }
                guard try file.isUnchanged() else { throw IndexingError.fileChanged }
                return Produced(job: job, size: file.size, modifiedTime: file.modifiedTime, state: state, set: set)
            }
        } catch IndexingError.fileChanged {
            return nil
        } catch VolumeIOError.notFound {
            return nil
        } catch VolumeIOError.system {
            // One bad read says nothing about the file. It stays pending for the next run.
            return nil
        }
    }

    /// A video has no embedded preview worth finding, so its first stage reads nothing. Its frame comes
    /// from the video thumbnailer, whose reads go through the same scheduler.
    private func runVideo(
        _ stage: Stage, job: ThumbnailJob, priority: IOPriority, scheduler: VolumeIOScheduler
    ) async throws -> Produced? {
        let instance = job.instance
        guard stage == .full else {
            return Produced(
                job: job, size: instance.size, modifiedTime: instance.modifiedTime, state: .preview, set: nil)
        }
        guard let video else { return nil }
        // A format nothing here can decode fails without a read. When an engine that can arrives, a
        // migration has to clear these.
        guard video.canThumbnail(fileExtension: instance.path.fileExtension) else {
            return Produced(
                job: job, size: instance.size, modifiedTime: instance.modifiedTime, state: .failed, set: nil)
        }
        do {
            let image = try await video.poster(
                of: instance, scheduler: scheduler, priority: priority, maxPixelSize: ThumbnailSizes.large)
            let set = image.flatMap(Thumbnailer.thumbnails(from:))
            return Produced(
                job: job, size: instance.size, modifiedTime: instance.modifiedTime,
                state: set == nil ? .failed : .complete, set: set)
        } catch VideoReadError.fileChanged {
            return nil
        } catch VolumeIOError.notFound {
            return nil
        } catch VolumeIOError.system {
            return nil
        }
    }

    private func record(_ produced: [Produced]) async throws {
        let thumbnails = produced.flatMap { $0.set?.thumbnails ?? [] }
        var locations = try await packs.append(thumbnails)[...]
        let records = produced.map { item in
            let count = item.set?.thumbnails.count ?? 0
            let own = Array(locations.prefix(count))
            locations = locations.dropFirst(count)
            return ThumbnailRecord(
                assetID: item.job.assetID, instanceID: item.job.instance.id, size: item.size,
                modifiedTime: item.modifiedTime, state: item.state, dominantColor: item.set?.dominantColor,
                locations: own)
        }
        try await store.recordThumbnails(records)
    }
}
