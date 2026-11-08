import Foundation
internal import GRDB

extension LibraryStore {
    /// Compares one fully listed directory with what's stored, and writes only the differences.
    ///
    /// New files get a provisional asset at once, so they can show before hashing finishes. A file is
    /// unchanged when its name, size and modified time all match. An unchanged directory causes no
    /// write at all. Comparing one directory at a time keeps memory bounded on large libraries.
    public func applyDirectory(
        volume: VolumeID, directory: String, files: [ScannedFile], now: Date = Date()
    ) async throws -> DirectoryChanges {
        struct Known: Sendable { let id: Int64; let assetID: Int64; let size: Int64; let modified: Int64 }
        var byName: [String: Known] = try await pool.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT id, asset_id, name, size, modified_ns FROM file_instances WHERE volume_id = ? AND directory = ?",
                arguments: [volume.rawValue, directory])
            var known: [String: Known] = [:]
            while let row = try rows.next() {
                known[row["name"]] = Known(
                    id: row["id"], assetID: row["asset_id"], size: row["size"], modified: row["modified_ns"])
            }
            return known
        }

        var changes = DirectoryChanges()
        var newFiles: [ScannedFile] = []
        var modified: [(id: Int64, file: ScannedFile)] = []
        for file in files {
            guard let existing = byName.removeValue(forKey: file.name) else {
                newFiles.append(file)
                continue
            }
            if existing.size == file.size && existing.modified == file.modifiedTime.nanoseconds {
                changes.unchanged += 1
            } else {
                modified.append((existing.id, file))
            }
        }
        let removed = Array(byName.values)
        changes.added = newFiles.count
        changes.modified = modified.count
        changes.removed = removed.count
        guard !newFiles.isEmpty || !modified.isEmpty || !removed.isEmpty else { return changes }

        let added = newFiles
        let modifiedRows = modified.map { (id: $0.id, size: $0.file.size, modified: $0.file.modifiedTime.nanoseconds) }
        let removals = removed.map { (id: $0.id, assetID: $0.assetID) }
        let timestamp = now.timeIntervalSince1970
        try await pool.write { db in
            let insertAsset = try db.cachedStatement(sql: "INSERT INTO assets (kind, created_at) VALUES (?, ?)")
            let insertInstance = try db.cachedStatement(
                sql: """
                    INSERT INTO file_instances (asset_id, volume_id, directory, name, size, modified_ns)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """)
            for file in added {
                try insertAsset.execute(arguments: [file.kind.rawValue, timestamp])
                try insertInstance.execute(arguments: [
                    db.lastInsertedRowID, volume.rawValue, directory, file.name, file.size,
                    file.modifiedTime.nanoseconds,
                ])
            }
            let updateInstance = try db.cachedStatement(
                sql: """
                    UPDATE file_instances
                    SET size = ?, modified_ns = ?, index_state = 0, index_attempts = 0, index_error = NULL
                    WHERE id = ?
                    """)
            for row in modifiedRows {
                try updateInstance.execute(arguments: [row.size, row.modified, row.id])
            }
            for removal in removals {
                try db.execute(sql: "DELETE FROM file_instances WHERE id = ?", arguments: [removal.id])
                try Self.deleteAssetIfUnreferenced(removal.assetID, db)
            }
        }
        return changes
    }

    /// Directories with indexed files at or under `root`.
    public func knownDirectories(volume: VolumeID, under root: String) async throws -> [String] {
        try await pool.read { db in
            if root.isEmpty {
                return try String.fetchAll(
                    db, sql: "SELECT DISTINCT directory FROM file_instances WHERE volume_id = ?",
                    arguments: [volume.rawValue])
            }
            // A range over the index rather than LIKE, so that it's fast and needs no escaping.
            // "0" is the character after "/".
            return try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT directory FROM file_instances
                    WHERE volume_id = ? AND (directory = ? OR (directory >= ? AND directory < ?))
                    """,
                arguments: [volume.rawValue, root, root + "/", root + "0"])
        }
    }

    /// Forgets directories that are gone from the volume. Their assets survive if anything refers to them.
    @discardableResult
    public func removeDirectories(volume: VolumeID, _ directories: [String]) async throws -> Int {
        guard !directories.isEmpty else { return 0 }
        return try await pool.write { db in
            var removed = 0
            for directory in directories {
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, asset_id FROM file_instances WHERE volume_id = ? AND directory = ?",
                    arguments: [volume.rawValue, directory])
                for row in rows {
                    let id: Int64 = row["id"]
                    let assetID: Int64 = row["asset_id"]
                    try db.execute(sql: "DELETE FROM file_instances WHERE id = ?", arguments: [id])
                    try Self.deleteAssetIfUnreferenced(assetID, db)
                    removed += 1
                }
            }
            return removed
        }
    }

    public func instances(volume: VolumeID, directory: String) async throws -> [FileInstance] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM file_instances WHERE volume_id = ? AND directory = ? ORDER BY name",
                arguments: [volume.rawValue, directory]
            ).map { $0.fileInstance() }
        }
    }

    public func instance(volume: VolumeID, path: RelativePath) async throws -> FileInstance? {
        try await pool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM file_instances WHERE volume_id = ? AND directory = ? AND name = ?",
                arguments: [volume.rawValue, path.directory, path.name]
            )?.fileInstance()
        }
    }

    /// Pending files after `cursor`, in id order, with a bounded page size.
    public func pendingInstances(
        volume: VolumeID, after cursor: FileInstanceID?, limit: Int
    ) async throws -> [FileInstance] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM file_instances
                    WHERE volume_id = ? AND index_state = 0 AND id > ?
                    ORDER BY id LIMIT ?
                    """,
                arguments: [volume.rawValue, cursor?.rawValue ?? 0, limit]
            ).map { $0.fileInstance() }
        }
    }

    /// Records a failed read. After `maxAttempts` the file stops being retried until it changes.
    public func recordIndexFailure(_ id: FileInstanceID, message: String, maxAttempts: Int) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE file_instances
                    SET index_attempts = index_attempts + 1,
                        index_error = ?,
                        index_state = CASE WHEN index_attempts + 1 >= ? THEN 2 ELSE 0 END
                    WHERE id = ?
                    """,
                arguments: [message, maxAttempts, id.rawValue])
        }
    }

    /// Deletes an asset only when nothing refers to it: no file, and no organization data.
    /// An asset whose only file went away keeps its favorite, albums and tags, ready to reattach by hash.
    static func deleteAssetIfUnreferenced(_ id: Int64, _ db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM assets WHERE id = ?
                AND is_favorite = 0 AND rotation = 0
                AND NOT EXISTS (SELECT 1 FROM file_instances WHERE asset_id = assets.id)
                AND NOT EXISTS (SELECT 1 FROM album_assets WHERE asset_id = assets.id)
                AND NOT EXISTS (SELECT 1 FROM asset_tags WHERE asset_id = assets.id)
                AND NOT EXISTS (SELECT 1 FROM stack_members WHERE asset_id = assets.id)
                AND NOT EXISTS (SELECT 1 FROM stacks WHERE cover_asset_id = assets.id)
                AND NOT EXISTS (SELECT 1 FROM sessions WHERE anchor_asset_id = assets.id)
                AND NOT EXISTS (SELECT 1 FROM sessions WHERE current_asset_id = assets.id)
                """,
            arguments: [id])
    }
}
