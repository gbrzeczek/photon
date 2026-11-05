import Foundation
import PhotonCore

/// How a mounted volume relates to the library.
public enum VolumeResolution: Hashable, Sendable {
    /// A known volume, or a new row for one Photon hasn't seen.
    case online(Volume, isNew: Bool)
    /// Another volume with this UUID is online, so this is a clone mounted alongside its original.
    /// It stays out of the library for this session.
    case duplicateOfOnlineVolume(VolumeID)
}

/// Decides which `volumes` row a mount belongs to, following the steps in docs/PLAN.md.
struct VolumeResolver {
    /// Files checked per candidate row.
    static let sampleSize = 64
    /// The share of sampled files that must still match. It's a majority rather than all of them,
    /// because files on a drive do change between sessions.
    static let requiredMatchRatio = 0.5

    let store: LibraryStore

    /// - Parameter online: Volumes that are online right now, on other mounts.
    func resolve(
        _ mount: MountedVolume, scheduler: VolumeIOScheduler, online: Set<VolumeID>, now: Date = Date()
    ) async throws -> VolumeResolution {
        let candidates = try await store.volumes(uuid: mount.uuid)
        if let duplicate = candidates.first(where: { online.contains($0.id) }) {
            return .duplicateOfOnlineVolume(duplicate.id)
        }
        for candidate in candidates where try await sampleMatches(candidate.id, scheduler: scheduler) {
            try await store.markVolumeSeen(
                candidate.id, name: mount.name, capacity: mount.capacity, filesystem: mount.filesystem, now: now)
            var updated = candidate
            updated.name = mount.name
            updated.capacity = mount.capacity
            updated.filesystem = mount.filesystem
            updated.lastSeenAt = now
            return .online(updated, isNew: false)
        }
        // A reused drive or a clone that has diverged. Assets reattach as its files are hashed.
        let volume = try await store.insertVolume(
            uuid: mount.uuid, name: mount.name, capacity: mount.capacity, filesystem: mount.filesystem, now: now)
        return .online(volume, isNew: true)
    }

    private func sampleMatches(_ volume: VolumeID, scheduler: VolumeIOScheduler) async throws -> Bool {
        let sample = try await store.sampleInstances(volume: volume, limit: Self.sampleSize)
        guard !sample.isEmpty else { return true }
        let matches = try await withThrowingTaskGroup(of: Bool.self) { group in
            for instance in sample {
                group.addTask {
                    let status = try await scheduler.status(of: instance.path, priority: .userHash)
                    return status?.size == instance.size && status?.modifiedTime == instance.modifiedTime
                }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        return Double(matches) >= Double(sample.count) * Self.requiredMatchRatio
    }
}
