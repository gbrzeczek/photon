import Foundation
import PhotonCore
import os

/// Counts for one enumeration. Nothing here is proportional to a file's size.
public struct ScanReport: Hashable, Sendable {
    public var directories = 0
    public var added = 0
    public var modified = 0
    public var removed = 0
    public var unchanged = 0
    /// Directories that couldn't be listed, so nothing under them was treated as deleted.
    public var unreadableDirectories = 0
    public init() {}

    mutating func add(_ changes: DirectoryChanges) {
        added += changes.added
        modified += changes.modified
        removed += changes.removed
        unchanged += changes.unchanged
    }
}

/// The enumeration stage: walks a root, and records only what differs from the library.
///
/// A complete run is what allows files to be forgotten. Nothing under a directory that couldn't
/// be listed is removed, and a run that stops early removes only what it had confirmed gone, so a
/// failing drive never looks like an empty one.
struct VolumeScanner {
    let store: LibraryStore
    let scheduler: VolumeIOScheduler
    let volume: VolumeID
    var progress: (@Sendable (ScanReport) -> Void)?

    private static let signposter = OSSignposter(subsystem: Signposts.subsystem, category: "VolumeScanner")

    func scan(root: String) async throws -> ScanReport {
        let interval = Self.signposter.beginInterval("Enumerate")
        defer { Self.signposter.endInterval("Enumerate", interval) }

        var report = ScanReport()
        var pending = [root]
        var visited = Set<String>()
        var unreadable: [String] = []

        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let entries: [DirectoryEntry]
            do {
                entries = try await scheduler.listDirectory(directory, priority: .backgroundMetadata)
            } catch VolumeIOError.notFound {
                // Deleted during the scan. The scheduler has checked that the volume itself is still
                // here, so the sweep below can safely forget what's stored for it.
                continue
            } catch VolumeIOError.system(_, let code) where Self.isPerDirectory(code) {
                report.unreadableDirectories += 1
                unreadable.append(directory)
                continue
            }

            var files: [ScannedFile] = []
            files.reserveCapacity(entries.count)
            for entry in entries where !IgnoredNames.skips(entry.name, isDirectory: entry.kind == .directory) {
                switch entry.kind {
                case .directory:
                    pending.append(directory.isEmpty ? entry.name : directory + "/" + entry.name)
                case .file:
                    guard let kind = MediaKind(fileExtension: RelativePath(directory: "", name: entry.name).fileExtension)
                    else { continue }
                    files.append(
                        ScannedFile(name: entry.name, kind: kind, size: entry.size, modifiedTime: entry.modifiedTime))
                case .other:
                    continue
                }
            }

            report.add(try await store.applyDirectory(volume: volume, directory: directory, files: files))
            report.directories += 1
            visited.insert(directory)
            progress?(report)
        }

        // Every surviving directory was visited, so any other known directory is gone.
        let known = try await store.knownDirectories(volume: volume, under: root)
        let missing = known.filter { directory in
            !visited.contains(directory)
                && !unreadable.contains { directory == $0 || directory.hasPrefix($0 + "/") }
        }
        report.removed += try await store.removeDirectories(volume: volume, missing)
        return report
    }

    /// Errors about one directory rather than about the volume.
    private static func isPerDirectory(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM
    }
}

public enum Signposts {
    public static let subsystem = "app.photon"
}
