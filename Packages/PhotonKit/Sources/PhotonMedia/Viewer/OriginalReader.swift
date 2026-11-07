import Foundation
import PhotonCore
import PhotonIndex

/// Reads a whole original into memory, for the viewer and the pasteboard. The read goes through the
/// volume's I/O scheduler, so it's cancellable, has its priority and never memory-maps.
public struct OriginalReader: Sendable {
    private let store: LibraryStore
    private let scheduler: @Sendable (VolumeID) -> VolumeIOScheduler?

    /// - Parameter scheduler: The scheduler for an online volume, or nil when it's offline.
    public init(store: LibraryStore, scheduler: @escaping @Sendable (VolumeID) -> VolumeIOScheduler?) {
        self.store = store
        self.scheduler = scheduler
    }

    /// The file's bytes. Nil when there's nothing to read, which is a normal state: the volume is
    /// offline, or the file has gone or changed since it was indexed. A removed drive lands here too.
    /// Throws `CancellationError` when the task is cancelled.
    public func read(_ instance: FileInstanceID, priority: IOPriority) async throws -> Data? {
        guard let row = try await store.browseRows(instances: [instance.rawValue]).first,
            row.size <= ThumbnailSizes.fullReadLimit, let scheduler = scheduler(row.volumeID)
        else { return nil }
        do {
            return try await scheduler.withFile(row.path, priority: priority) { file in
                guard file.size == row.size, file.modifiedTime == row.modifiedTime else { return nil }
                let data = try file.read(offset: 0, length: Int(file.size))
                return try file.isUnchanged() ? data : nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // `VolumeIOError` of every kind. None of them is worth more than keeping the thumbnail.
            return nil
        }
    }
}
