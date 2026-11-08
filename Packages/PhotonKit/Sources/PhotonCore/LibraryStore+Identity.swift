import Foundation
internal import GRDB

extension LibraryStore {
    /// Applies the identity rules from docs/PLAN.md to a batch of indexed files, in one transaction.
    public func applyIndexed(_ files: [IndexedFile], now: Date = Date()) async throws -> IdentityCounts {
        guard !files.isEmpty else { return IdentityCounts() }
        return try await pool.write { db in
            var counts = IdentityCounts()
            for file in files {
                try Self.applyIndexed(file, now: now, counts: &counts, db)
            }
            return counts
        }
    }

    private static func applyIndexed(
        _ file: IndexedFile, now: Date, counts: inout IdentityCounts, _ db: Database
    ) throws {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM file_instances WHERE id = ?", arguments: [file.instanceID.rawValue])
        else {
            counts.stale += 1
            return
        }
        let instance = row.fileInstance()
        // The file changed after it was read, so these bytes no longer describe it.
        guard instance.size == file.size, instance.modifiedTime == file.modifiedTime else {
            counts.stale += 1
            return
        }
        guard
            let current = try Row.fetchOne(
                db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [instance.assetID.rawValue]
            )?.asset()
        else { throw LibraryError.notFound }

        let match = try Row.fetchOne(
            db, sql: "SELECT * FROM assets WHERE content_hash = ?", arguments: [file.hash.bytes]
        )?.asset()

        if let match {
            if match.id == current.id {
                // Same content as before, or the sampled regions didn't change.
                try fillMetadata(file.metadata, on: match.id, db)
            } else if current.contentHash == nil {
                // A provisional asset whose content is already known: an exact duplicate, a reconnected
                // drive, or a moved file.
                try merge(current.id, into: match.id, db)
                try fillMetadata(file.metadata, on: match.id, db)
                counts.merged += 1
            } else {
                // A file that changed into content some other asset already has.
                let others = try otherInstanceCount(of: current.id, excluding: instance.id, db)
                let samePicture = file.metadata.map { current.metadata.isSamePicture(as: $0) } ?? false
                if others == 0 && samePicture {
                    try merge(current.id, into: match.id, db)
                } else {
                    try reassign(instance.id, to: match.id, from: current.id, db)
                }
                try fillMetadata(file.metadata, on: match.id, db)
                counts.reassigned += 1
            }
        } else if current.contentHash == nil {
            try setHash(file.hash, on: current.id, db)
            try fillMetadata(file.metadata, on: current.id, db)
            counts.hashed += 1
        } else {
            // New content at a path that used to hold something else.
            let samePicture = file.metadata.map { current.metadata.isSamePicture(as: $0) } ?? false
            let others = try otherInstanceCount(of: current.id, excluding: instance.id, db)
            if samePicture && others == 0 {
                // An edited or rotated file stays the same asset, and takes the new hash.
                try setHash(file.hash, on: current.id, db)
                try invalidateThumbnails(of: current.id, db)
                try fillMetadata(file.metadata, on: current.id, db)
                counts.rehashed += 1
            } else if samePicture {
                // Other copies still hold the old content, so the old asset has to keep its hash.
                // The edited copy carries the organization data with it.
                let fork = try insertAsset(kind: current.kind, hash: file.hash, now: now, db)
                try copyOrganizationData(from: current.id, to: fork, db)
                try reassign(instance.id, to: fork, from: current.id, db)
                try fillMetadata(file.metadata, on: fork, db)
                counts.rehashed += 1
            } else {
                let replacement = try insertAsset(kind: current.kind, hash: file.hash, now: now, db)
                try reassign(instance.id, to: replacement, from: current.id, db)
                try fillMetadata(file.metadata, on: replacement, db)
                counts.reassigned += 1
            }
        }

        try db.execute(
            sql: "UPDATE file_instances SET index_state = 1, index_attempts = 0, index_error = NULL WHERE id = ?",
            arguments: [instance.id.rawValue])
    }

    private static func otherInstanceCount(of asset: AssetID, excluding instance: FileInstanceID, _ db: Database) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT count(*) FROM file_instances WHERE asset_id = ? AND id != ?",
            arguments: [asset.rawValue, instance.rawValue]) ?? 0
    }

    private static func insertAsset(kind: MediaKind, hash: ContentHash, now: Date, _ db: Database) throws -> AssetID {
        try db.execute(
            sql: "INSERT INTO assets (kind, content_hash, created_at) VALUES (?, ?, ?)",
            arguments: [kind.rawValue, hash.bytes, now.timeIntervalSince1970])
        return AssetID(rawValue: db.lastInsertedRowID)
    }

    private static func setHash(_ hash: ContentHash, on asset: AssetID, _ db: Database) throws {
        try db.execute(
            sql: "UPDATE assets SET content_hash = ? WHERE id = ?", arguments: [hash.bytes, asset.rawValue])
    }

    /// New values win, because they come from the file as it is now. Fields the file didn't provide
    /// keep what's stored.
    private static func fillMetadata(_ metadata: MediaMetadata?, on asset: AssetID, _ db: Database) throws {
        guard let metadata else { return }
        try db.execute(
            sql: """
                UPDATE assets SET
                    width = coalesce(?, width),
                    height = coalesce(?, height),
                    orientation = coalesce(?, orientation),
                    capture_date_ms = coalesce(?, capture_date_ms),
                    capture_utc_offset_min = coalesce(?, capture_utc_offset_min),
                    duration_seconds = coalesce(?, duration_seconds)
                WHERE id = ?
                """,
            arguments: [
                metadata.pixelWidth, metadata.pixelHeight, metadata.orientation,
                metadata.captureDate?.wallClockMilliseconds, metadata.captureDate?.utcOffsetMinutes,
                metadata.durationSeconds, asset.rawValue,
            ])
    }

    private static func reassign(
        _ instance: FileInstanceID, to target: AssetID, from source: AssetID, _ db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE file_instances SET asset_id = ? WHERE id = ?",
            arguments: [target.rawValue, instance.rawValue])
        try deleteAssetIfUnreferenced(source.rawValue, db)
    }

    /// Moves everything from `source` to `target` and deletes `source`, keeping organization data from both.
    /// A rotation on `target` wins over one on `source`, since the two can't be combined meaningfully.
    private static func merge(_ source: AssetID, into target: AssetID, _ db: Database) throws {
        try db.execute(
            sql: """
                UPDATE assets SET
                    is_favorite = max(is_favorite, (SELECT is_favorite FROM assets WHERE id = :source)),
                    rotation = CASE WHEN rotation != 0 THEN rotation
                                    ELSE (SELECT rotation FROM assets WHERE id = :source) END
                WHERE id = :target
                """,
            arguments: ["source": source.rawValue, "target": target.rawValue])
        try db.execute(
            sql: "UPDATE file_instances SET asset_id = ? WHERE asset_id = ?",
            arguments: [target.rawValue, source.rawValue])
        try copyMemberships(from: source, to: target, db)
        try db.execute(
            sql: "UPDATE stacks SET cover_asset_id = ? WHERE cover_asset_id = ?",
            arguments: [target.rawValue, source.rawValue])
        try db.execute(
            sql: "UPDATE sessions SET anchor_asset_id = ? WHERE anchor_asset_id = ?",
            arguments: [target.rawValue, source.rawValue])
        try db.execute(
            sql: "UPDATE sessions SET current_asset_id = ? WHERE current_asset_id = ?",
            arguments: [target.rawValue, source.rawValue])
        try moveThumbnails(from: source, to: target, db)
        // Cascades remove the source's own memberships, which were copied above.
        try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [source.rawValue])
    }

    private static func copyOrganizationData(from source: AssetID, to target: AssetID, _ db: Database) throws {
        try db.execute(
            sql: """
                UPDATE assets SET
                    is_favorite = (SELECT is_favorite FROM assets WHERE id = :source),
                    rotation = (SELECT rotation FROM assets WHERE id = :source)
                WHERE id = :target
                """,
            arguments: ["source": source.rawValue, "target": target.rawValue])
        try copyMemberships(from: source, to: target, db)
    }

    private static func copyMemberships(from source: AssetID, to target: AssetID, _ db: Database) throws {
        let arguments: StatementArguments = [target.rawValue, source.rawValue]
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO album_assets (album_id, asset_id, position, added_at)
                SELECT album_id, ?, position, added_at FROM album_assets WHERE asset_id = ?
                """,
            arguments: arguments)
        try db.execute(
            sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) SELECT ?, tag_id FROM asset_tags WHERE asset_id = ?",
            arguments: arguments)
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO stack_members (stack_id, asset_id, position)
                SELECT stack_id, ?, position FROM stack_members WHERE asset_id = ?
                """,
            arguments: arguments)
    }

    /// The asset with this hash, if any.
    public func asset(hash: ContentHash) async throws -> Asset? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM assets WHERE content_hash = ?", arguments: [hash.bytes])?.asset()
        }
    }

    public func asset(_ id: AssetID) async throws -> Asset? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [id.rawValue])?.asset()
        }
    }

    public func instances(of asset: AssetID) async throws -> [FileInstance] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM file_instances WHERE asset_id = ? ORDER BY id", arguments: [asset.rawValue]
            ).map { $0.fileInstance() }
        }
    }

    /// Row counts by table, for tests and diagnostics.
    public func assetCount() async throws -> Int {
        try await pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM assets") ?? 0 }
    }
}
