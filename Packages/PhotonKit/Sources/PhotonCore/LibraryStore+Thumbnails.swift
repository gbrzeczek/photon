import Foundation
internal import GRDB

/// One stored size of a thumbnail. `preview` is a temporary embedded image, which goes away once the
/// full read has produced `small` and `large`.
public enum ThumbnailTier: Int, Sendable, Hashable, CaseIterable, Comparable {
    case preview = 0
    case small = 1
    case large = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ThumbnailState: Int, Sendable, Hashable {
    case none = 0
    /// An embedded preview was tried. Whether it found one or not, a full read comes next.
    case preview = 1
    case complete = 2
    /// The file couldn't be decoded. A change to the file clears this.
    case failed = 3
}

/// Where one thumbnail's bytes are.
public struct ThumbnailLocation: Hashable, Sendable {
    public var tier: ThumbnailTier
    public var packID: Int64
    public var offset: Int64
    public var length: Int
    public var width: Int
    public var height: Int

    public init(tier: ThumbnailTier, packID: Int64, offset: Int64, length: Int, width: Int, height: Int) {
        self.tier = tier
        self.packID = packID
        self.offset = offset
        self.length = length
        self.width = width
        self.height = height
    }
}

/// What a finished thumbnail job learned about one asset.
public struct ThumbnailRecord: Sendable {
    public var assetID: AssetID
    public var instanceID: FileInstanceID
    /// The file as it was read. A result for a file that has since changed is dropped.
    public var size: Int64
    public var modifiedTime: FileTimestamp
    public var state: ThumbnailState
    public var dominantColor: UInt32?
    public var locations: [ThumbnailLocation]

    public init(
        assetID: AssetID, instanceID: FileInstanceID, size: Int64, modifiedTime: FileTimestamp,
        state: ThumbnailState, dominantColor: UInt32?, locations: [ThumbnailLocation]
    ) {
        self.assetID = assetID
        self.instanceID = instanceID
        self.size = size
        self.modifiedTime = modifiedTime
        self.state = state
        self.dominantColor = dominantColor
        self.locations = locations
    }
}

/// An asset waiting for thumbnails, and the file to make them from.
public struct ThumbnailJob: Hashable, Sendable {
    public var assetID: AssetID
    public var state: ThumbnailState
    public var kind: MediaKind
    public var instance: FileInstance
}

public struct ThumbnailPack: Hashable, Sendable {
    public var id: Int64
    public var tier: ThumbnailTier
    public var byteCount: Int64
    public var lastUsedAt: Date
    public var favoriteCount: Int
}

extension LibraryStore {
    // MARK: Identity hooks

    /// The content changed, so anything derived from it is wrong.
    static func invalidateThumbnails(of asset: AssetID, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM thumbnails WHERE asset_id = ?", arguments: [asset.rawValue])
        try db.execute(
            sql: "UPDATE assets SET thumbnail_state = 0, dominant_color = NULL WHERE id = ?",
            arguments: [asset.rawValue])
    }

    /// Identical content, so whatever `source` already has saves `target` a read.
    static func moveThumbnails(from source: AssetID, to target: AssetID, _ db: Database) throws {
        try db.execute(
            sql: "UPDATE OR IGNORE thumbnails SET asset_id = ? WHERE asset_id = ?",
            arguments: [target.rawValue, source.rawValue])
        try db.execute(
            sql: """
                UPDATE assets SET
                    thumbnail_state = max(thumbnail_state, (SELECT thumbnail_state FROM assets WHERE id = :source)),
                    dominant_color = coalesce(dominant_color, (SELECT dominant_color FROM assets WHERE id = :source))
                WHERE id = :target
                """,
            arguments: ["source": source.rawValue, "target": target.rawValue])
    }

    // MARK: Reading

    /// Stored locations for these assets. Blocks, for the decoding threads. Never call it on the main
    /// thread, and never from Swift's cooperative pool.
    public func thumbnailLocationsBlocking(assets: [AssetID]) throws -> [AssetID: [ThumbnailLocation]] {
        guard !assets.isEmpty else { return [:] }
        return try pool.read { db in
            var result: [AssetID: [ThumbnailLocation]] = [:]
            let marks = databaseQuestionMarks(count: assets.count)
            let rows = try Row.fetchCursor(
                db, sql: "SELECT * FROM thumbnails WHERE asset_id IN (\(marks))",
                arguments: StatementArguments(assets.map(\.rawValue)))
            while let row = try rows.next() {
                let asset = AssetID(rawValue: row["asset_id"])
                result[asset, default: []].append(
                    ThumbnailLocation(
                        tier: ThumbnailTier(rawValue: row["tier"]) ?? .small, packID: row["pack_id"],
                        offset: row["byte_offset"], length: row["byte_count"], width: row["width"],
                        height: row["height"]))
            }
            return result
        }
    }

    /// The file and state for a thumbnail requested on screen.
    public func thumbnailJob(asset: AssetID, instance: FileInstanceID) async throws -> ThumbnailJob? {
        try await pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT f.*, a.thumbnail_state, a.kind FROM file_instances f
                    JOIN assets a ON a.id = f.asset_id
                    WHERE a.id = ? AND f.id = ?
                    """,
                arguments: [asset.rawValue, instance.rawValue]
            ).map(Self.thumbnailJob)
        }
    }

    /// Hashed photos on `volume` in this state, in id order, one file each. Waiting for the hash means an
    /// exact duplicate never gets decoded twice.
    public func pendingThumbnails(
        volume: VolumeID, state: ThumbnailState, after cursor: AssetID?, limit: Int
    ) async throws -> [ThumbnailJob] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.*, a.thumbnail_state, a.kind FROM assets a
                    JOIN file_instances f ON f.id =
                        (SELECT min(id) FROM file_instances WHERE asset_id = a.id AND volume_id = :volume)
                    WHERE a.thumbnail_state = :state AND a.kind = 1 AND a.id > :cursor
                        AND a.content_hash IS NOT NULL
                    ORDER BY a.id LIMIT :limit
                    """,
                arguments: [
                    "volume": volume.rawValue, "state": state.rawValue, "cursor": cursor?.rawValue ?? 0,
                    "limit": limit,
                ]
            ).map(Self.thumbnailJob)
        }
    }

    public func thumbnailBacklog(volume: VolumeID) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM assets a
                    WHERE a.thumbnail_state < 2 AND a.kind = 1
                        AND EXISTS (SELECT 1 FROM file_instances WHERE asset_id = a.id AND volume_id = ?)
                    """,
                arguments: [volume.rawValue]) ?? 0
        }
    }

    private static func thumbnailJob(_ row: Row) -> ThumbnailJob {
        ThumbnailJob(
            assetID: AssetID(rawValue: row["asset_id"]),
            state: ThumbnailState(rawValue: row["thumbnail_state"]) ?? .none,
            kind: MediaKind(rawValue: row["kind"]) ?? .photo,
            instance: row.fileInstance())
    }

    // MARK: Writing

    /// Records finished jobs in one transaction. A complete asset loses its preview.
    /// Returns the assets actually recorded.
    @discardableResult
    public func recordThumbnails(_ records: [ThumbnailRecord]) async throws -> Set<AssetID> {
        guard !records.isEmpty else { return [] }
        return try await pool.write { db in
            var recorded = Set<AssetID>()
            let insert = try db.cachedStatement(
                sql: """
                    INSERT OR REPLACE INTO thumbnails
                        (asset_id, tier, pack_id, byte_offset, byte_count, width, height)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """)
            for record in records {
                // The file must still be this asset, with the content that was read.
                let isCurrent = try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM file_instances WHERE id = ? AND asset_id = ? AND size = ? AND modified_ns = ?",
                    arguments: [
                        record.instanceID.rawValue, record.assetID.rawValue, record.size,
                        record.modifiedTime.nanoseconds,
                    ]) ?? false
                guard isCurrent else { continue }

                for location in record.locations {
                    try insert.execute(arguments: [
                        record.assetID.rawValue, location.tier.rawValue, location.packID, location.offset,
                        location.length, location.width, location.height,
                    ])
                }
                if record.state == .complete {
                    try db.execute(
                        sql: "DELETE FROM thumbnails WHERE asset_id = ? AND tier = ?",
                        arguments: [record.assetID.rawValue, ThumbnailTier.preview.rawValue])
                }
                try db.execute(
                    sql: """
                        UPDATE assets SET
                            thumbnail_state = max(thumbnail_state, ?),
                            dominant_color = coalesce(?, dominant_color)
                        WHERE id = ?
                        """,
                    arguments: [record.state.rawValue, record.dominantColor.map { Int64($0) }, record.assetID.rawValue])
                recorded.insert(record.assetID)
            }
            return recorded
        }
    }

    /// Forgets a thumbnail whose bytes turned out to be missing, so that it gets made again.
    public func dropThumbnail(asset: AssetID, tier: ThumbnailTier) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM thumbnails WHERE asset_id = ? AND tier = ?",
                arguments: [asset.rawValue, tier.rawValue])
            try db.execute(
                sql: "UPDATE assets SET thumbnail_state = 0 WHERE id = ? AND thumbnail_state != 3",
                arguments: [asset.rawValue])
        }
    }

    // MARK: Packs

    public func insertThumbnailPack(tier: ThumbnailTier, now: Date = Date()) async throws -> Int64 {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO thumbnail_packs (tier, last_used_at) VALUES (?, ?)",
                arguments: [tier.rawValue, now.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    public func setThumbnailPackSize(_ id: Int64, byteCount: Int64) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE thumbnail_packs SET byte_count = ? WHERE id = ?", arguments: [byteCount, id])
        }
    }

    public func markThumbnailPacksUsed(_ ids: [Int64], now: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        try await pool.write { db in
            let marks = databaseQuestionMarks(count: ids.count)
            var arguments: [any DatabaseValueConvertible] = [now.timeIntervalSince1970]
            arguments += ids
            try db.execute(
                sql: "UPDATE thumbnail_packs SET last_used_at = ? WHERE id IN (\(marks))",
                arguments: StatementArguments(arguments))
        }
    }

    public func thumbnailPacks() async throws -> [ThumbnailPack] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.*, (
                        SELECT count(*) FROM thumbnails t JOIN assets a ON a.id = t.asset_id
                        WHERE t.pack_id = p.id AND a.is_favorite = 1
                    ) AS favorites
                    FROM thumbnail_packs p ORDER BY p.id
                    """
            ).map { row in
                ThumbnailPack(
                    id: row["id"], tier: ThumbnailTier(rawValue: row["tier"]) ?? .small,
                    byteCount: row["byte_count"],
                    lastUsedAt: Date(timeIntervalSince1970: row["last_used_at"]),
                    favoriteCount: row["favorites"])
            }
        }
    }

    /// Removes a pack's row, and with it every thumbnail stored there. The caller deletes the file.
    public func deleteThumbnailPack(_ id: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM thumbnail_packs WHERE id = ?", arguments: [id])
        }
    }

    /// Packs that nothing refers to any more, other than `keeping`, such as packs being written.
    public func emptyThumbnailPacks(keeping: Set<Int64>) async throws -> [Int64] {
        try await pool.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT id FROM thumbnail_packs p WHERE NOT EXISTS (SELECT 1 FROM thumbnails WHERE pack_id = p.id)"
            ).filter { !keeping.contains($0) }
        }
    }
}
