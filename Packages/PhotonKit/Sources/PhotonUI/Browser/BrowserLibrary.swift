import AppKit
import Foundation
import Observation
import PhotonCore
import PhotonIndex
import PhotonMedia

/// The library and everything that works on it, for one app window. Everything it awaits runs off the
/// main thread.
@MainActor
@Observable
public final class BrowserLibrary {
    public private(set) var folders: [BrowseFolder] = []
    public private(set) var volumes: [VolumeSummary] = []
    public private(set) var onlineVolumes: Set<VolumeID> = []
    public private(set) var isIndexing = false
    public private(set) var activity = ""
    public private(set) var lastError: String?

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let indexer: LibraryIndexer
    @ObservationIgnored let generator: ThumbnailGenerator
    @ObservationIgnored let loader: ThumbnailLoader
    @ObservationIgnored private var packs: ThumbnailPackStore
    @ObservationIgnored private var monitor: VolumeEventMonitor?
    @ObservationIgnored private var backgroundTasks: [VolumeID: Task<Void, Never>] = [:]
    /// Tells the browser that the library changed. It decides how often to look.
    @ObservationIgnored var onContentChanged: (() -> Void)?

    /// Must run off the main thread, because it opens the database.
    public nonisolated static func open(url: URL?) throws -> LibraryHandle {
        LibraryHandle(store: try LibraryStore(url: url ?? LibraryStore.defaultURL()))
    }

    public init(_ handle: LibraryHandle) {
        let store = handle.store
        self.store = store
        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
        self.indexer = indexer
        let packs = ThumbnailPackStore(store: store)
        self.packs = packs
        let generator = ThumbnailGenerator(store: store, packs: packs, scheduler: { indexer.scheduler(for: $0) })
        self.generator = generator
        loader = ThumbnailLoader(store: store, packs: packs, generator: generator, cache: ThumbnailMemoryCache())
        monitor = VolumeEventMonitor(
            center: NSWorkspace.shared.notificationCenter,
            willUnmount: { [weak self] path in
                indexer.volumeWillUnmount(mountPoint: path)
                Task { @MainActor in await self?.refreshVolumes() }
            },
            didUnmount: { [weak self] path in
                indexer.volumeDidUnmount(mountPoint: path)
                Task { @MainActor in await self?.refreshVolumes() }
            },
            didMount: { [weak self] _ in
                Task { @MainActor in await self?.connectVolumes() }
            })
    }

    /// Connects known volumes that are mounted, and carries on with any thumbnails they're missing.
    public func start() async {
        await refresh()
        await connectVolumes()
    }

    private func connectVolumes() async {
        if let connected = try? await indexer.connectKnownVolumes() {
            for volume in connected { startThumbnails(volume) }
        }
        await refreshVolumes()
    }

    private func refreshVolumes() async {
        onlineVolumes = Set(indexer.onlineVolumes().values)
        onContentChanged?()
    }

    private func refresh() async {
        do {
            volumes = try await store.volumeSummaries()
            folders = try await store.folders()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func addFolder(_ folder: URL) {
        guard !isIndexing else { return }
        isIndexing = true
        lastError = nil
        activity = "Reading folders…"
        Task {
            defer { isIndexing = false }
            do {
                // At most one update per directory or batch, so the hop to the main actor is bounded.
                let report = try await indexer.index(path: folder.path) { progress in
                    Task { @MainActor in self.show(progress) }
                }
                activity = Self.describe(report)
                await refresh()
                await refreshVolumes()
                if let volume = report.volumeID { startThumbnails(volume) }
            } catch {
                activity = ""
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    private func show(_ progress: IndexProgress) {
        guard isIndexing else { return }
        switch progress {
        case .scanning(let report):
            activity = "Found \(report.added + report.modified + report.unchanged) files…"
        case .processing(let processed):
            activity = "Read \(processed) files…"
        }
        Task { await refresh() }
        onContentChanged?()
    }

    private func startThumbnails(_ volume: VolumeID) {
        guard backgroundTasks[volume] == nil else { return }
        let generator = generator
        backgroundTasks[volume] = Task {
            let total = (try? await store.thumbnailBacklog(volume: volume)) ?? 0
            _ = try? await generator.runBackground(volume: volume) { report in
                Task { @MainActor in
                    guard !self.isIndexing else { return }
                    let done = report.previews + report.full
                    self.activity = "Making thumbnails: \(min(done, total * 2) * 100 / max(1, total * 2))%"
                    self.onContentChanged?()
                }
            }
            backgroundTasks[volume] = nil
            if !isIndexing { activity = "" }
            onContentChanged?()
        }
    }

    private static func describe(_ report: IndexReport) -> String {
        switch report.outcome {
        case .completed:
            let changed = report.scan.added + report.scan.modified + report.scan.removed
            return "Done. \(changed) changed, \(report.scan.unchanged) unchanged, \(report.processed) read."
        case .cancelled:
            return "Stopped."
        case .volumeOffline:
            return "The volume went offline. Indexing continues when it's back."
        }
    }
}

/// An opened library, on its way from a background task to the main thread.
public struct LibraryHandle: Sendable {
    let store: LibraryStore
}
