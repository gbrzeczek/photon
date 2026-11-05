import AppKit
import Foundation
import Observation
import PhotonCore
import PhotonIndex
import PhotonMedia

/// Connects the status window to the indexer. Everything it awaits runs off the main thread.
@MainActor
@Observable
public final class IndexingController {
    public private(set) var summaries: [VolumeSummary] = []
    public private(set) var isIndexing = false
    public private(set) var activity = ""
    public private(set) var lastError: String?

    private var indexer: LibraryIndexer?
    private var store: LibraryStore?
    private var monitor: VolumeEventMonitor?

    public init() {}

    /// Opens the library. Disk access, so it doesn't happen on the main thread.
    public func start() async {
        guard store == nil else { return }
        do {
            let store = try await Task.detached(priority: .userInitiated) {
                try LibraryStore(url: LibraryStore.defaultURL())
            }.value
            let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
            self.store = store
            self.indexer = indexer
            monitor = VolumeEventMonitor(
                center: NSWorkspace.shared.notificationCenter,
                willUnmount: { indexer.volumeWillUnmount(mountPoint: $0) },
                didUnmount: { indexer.volumeDidUnmount(mountPoint: $0) })
            await refresh()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func index(folder: URL) {
        guard let indexer, !isIndexing else { return }
        isIndexing = true
        lastError = nil
        activity = "Reading folders…"
        Task {
            defer { isIndexing = false }
            do {
                // The hop to the main actor is bounded: at most one update per directory or batch.
                let report = try await indexer.index(path: folder.path) { progress in
                    Task { @MainActor in self.show(progress) }
                }
                activity = Self.describe(report)
            } catch {
                activity = ""
                lastError = error.localizedDescription
            }
            await refresh()
        }
    }

    private func show(_ progress: IndexProgress) {
        guard isIndexing else { return }
        switch progress {
        case .scanning(let report):
            activity = "Found \(report.added + report.modified + report.unchanged) files…"
        case .processing(let processed):
            activity = "Indexed \(processed) files…"
        }
    }

    private func refresh() async {
        guard let store else { return }
        do {
            summaries = try await store.volumeSummaries()
        } catch {
            lastError = String(describing: error)
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
