import Foundation
internal import GRDB

extension LibraryStore {
    /// Rows with this UUID, most recently seen first. There can be several: clones share a UUID.
    public func volumes(uuid: String) async throws -> [Volume] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM volumes WHERE uuid = ? ORDER BY last_seen_at DESC, id DESC",
                arguments: [uuid]
            ).map { $0.volume() }
        }
    }

    public func allVolumes() async throws -> [Volume] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM volumes ORDER BY last_seen_at DESC, id DESC").map { $0.volume() }
        }
    }

    public func insertVolume(
        uuid: String, name: String, capacity: Int64?, filesystem: String?, now: Date = Date()
    ) async throws -> Volume {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO volumes (uuid, name, capacity, filesystem, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [uuid, name, capacity, filesystem, now.timeIntervalSince1970, now.timeIntervalSince1970])
            return Volume(
                id: VolumeID(rawValue: db.lastInsertedRowID), uuid: uuid, name: name, capacity: capacity,
                filesystem: filesystem, lastSeenAt: now)
        }
    }

    public func markVolumeSeen(
        _ id: VolumeID, name: String, capacity: Int64?, filesystem: String?, now: Date = Date()
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE volumes SET name = ?, capacity = ?, filesystem = ?, last_seen_at = ? WHERE id = ?",
                arguments: [name, capacity, filesystem, now.timeIntervalSince1970, id.rawValue])
        }
    }

    /// A random sample of indexed files, to check that a mounted volume is the one the row describes.
    public func sampleInstances(volume: VolumeID, limit: Int) async throws -> [FileInstance] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM file_instances WHERE volume_id = ? ORDER BY random() LIMIT ?",
                arguments: [volume.rawValue, limit]
            ).map { $0.fileInstance() }
        }
    }

    /// Registers a directory to index, and returns its root. Adding a known root changes nothing.
    @discardableResult
    public func addRoot(volume: VolumeID, relativePath: String, now: Date = Date()) async throws -> LibraryRoot {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO library_roots (volume_id, relative_path, added_at) VALUES (?, ?, ?)
                    ON CONFLICT (volume_id, relative_path) DO NOTHING
                    """,
                arguments: [volume.rawValue, relativePath, now.timeIntervalSince1970])
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM library_roots WHERE volume_id = ? AND relative_path = ?",
                    arguments: [volume.rawValue, relativePath])
            else { throw LibraryError.notFound }
            return row.libraryRoot()
        }
    }

    public func roots(volume: VolumeID) async throws -> [LibraryRoot] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM library_roots WHERE volume_id = ? ORDER BY relative_path",
                arguments: [volume.rawValue]
            ).map { $0.libraryRoot() }
        }
    }

    public func markRootScanned(_ root: LibraryRoot, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE library_roots SET last_scan_completed_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, root.id])
        }
    }

    /// Per-volume counts. Run off the main thread: the cost grows with the library.
    public func volumeSummaries() async throws -> [VolumeSummary] {
        try await pool.read { db in
            let volumes = try Row.fetchAll(db, sql: "SELECT * FROM volumes ORDER BY last_seen_at DESC, id DESC")
                .map { $0.volume() }
            return try volumes.map { volume in
                let counts = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) AS files,
                               coalesce(sum(index_state = 0), 0) AS pending,
                               coalesce(sum(index_state = 2), 0) AS failed,
                               coalesce(sum(size), 0) AS bytes
                        FROM file_instances WHERE volume_id = ?
                        """,
                    arguments: [volume.id.rawValue])
                let roots = try Row.fetchAll(
                    db, sql: "SELECT * FROM library_roots WHERE volume_id = ? ORDER BY relative_path",
                    arguments: [volume.id.rawValue]
                ).map { $0.libraryRoot() }
                return VolumeSummary(
                    volume: volume, roots: roots, fileCount: counts?["files"] ?? 0,
                    pendingCount: counts?["pending"] ?? 0, failedCount: counts?["failed"] ?? 0,
                    totalBytes: counts?["bytes"] ?? 0)
            }
        }
    }
}
