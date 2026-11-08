import Foundation
internal import GRDB

/// Everything the inspector shows about one asset. All of it comes from the library, so it works offline.
public struct AssetDetails: Hashable, Sendable {
    public struct Location: Hashable, Sendable {
        public var instance: FileInstanceID
        public var volume: VolumeID
        public var volumeName: String
        public var path: RelativePath
        public var size: Int64
        public var modifiedTime: FileTimestamp
    }

    public struct StackMember: Hashable, Sendable {
        public var asset: AssetID
        public var name: String
        public var isCover: Bool
    }

    public var asset: Asset
    /// Every file holding this content, in path order.
    public var locations: [Location]
    public var tags: [Tag]
    /// Manual albums holding the asset, by name.
    public var albums: [Album]
    public var stackKind: StackKind?
    public var stackMembers: [StackMember]
}

extension LibraryStore {
    // MARK: Favorites

    /// Period's toggle: if any of `assets` isn't a favorite, all become favorites. Otherwise none are.
    /// Returns the new state.
    @discardableResult
    public func toggleFavorite(_ assets: [AssetID]) async throws -> Bool {
        guard !assets.isEmpty else { return false }
        return try await pool.write { db in
            let ids = assets.map(\.rawValue)
            let marks = databaseQuestionMarks(count: ids.count)
            let notFavorite = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM assets WHERE id IN (\(marks)) AND is_favorite = 0",
                arguments: StatementArguments(ids)) ?? 0
            let value = notFavorite > 0
            try db.execute(
                sql: "UPDATE assets SET is_favorite = ? WHERE id IN (\(marks)) AND is_favorite != ?",
                arguments: [value] as StatementArguments + StatementArguments(ids) + [value])
            return value
        }
    }

    public func setFavorite(_ assets: [AssetID], _ value: Bool) async throws {
        guard !assets.isEmpty else { return }
        try await pool.write { db in
            let ids = assets.map(\.rawValue)
            try db.execute(
                sql: "UPDATE assets SET is_favorite = ? WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: [value] as StatementArguments + StatementArguments(ids))
        }
    }

    // MARK: Albums

    /// Every album, manual and smart, by name.
    public func albums() async throws -> [Album] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, smart_query FROM albums ORDER BY name COLLATE NOCASE, id")
                .map(Self.album)
        }
    }

    public func album(_ id: AlbumID) async throws -> Album? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT id, name, smart_query FROM albums WHERE id = ?", arguments: [id.rawValue])
                .map(Self.album)
        }
    }

    private static func album(_ row: Row) -> Album {
        let json: String? = row["smart_query"]
        return Album(
            id: AlbumID(rawValue: row["id"]), name: row["name"], smartQuery: json.flatMap(SmartQuery.decode),
            isSmart: json != nil)
    }

    /// A manual album, or a smart one when `query` is given.
    public func createAlbum(name: String, query: SmartQuery? = nil, now: Date = Date()) async throws -> AlbumID {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO albums (name, smart_query, created_at) VALUES (?, ?, ?)",
                arguments: [name, query?.encoded(), now.timeIntervalSince1970])
            return AlbumID(rawValue: db.lastInsertedRowID)
        }
    }

    public func renameAlbum(_ album: AlbumID, to name: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE albums SET name = ? WHERE id = ?", arguments: [name, album.rawValue])
        }
    }

    /// Changes a smart album's rules. A manual album stays manual.
    public func setSmartQuery(_ album: AlbumID, _ query: SmartQuery) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE albums SET smart_query = ? WHERE id = ? AND smart_query IS NOT NULL",
                arguments: [query.encoded(), album.rawValue])
        }
    }

    /// Deletes the album and its memberships. No file is touched.
    public func deleteAlbum(_ album: AlbumID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [album.rawValue])
        }
    }

    /// Adds to a manual album, after what's there. Assets already in it stay where they are.
    public func addAssets(_ assets: [AssetID], to album: AlbumID, now: Date = Date()) async throws {
        guard !assets.isEmpty else { return }
        try await pool.write { db in
            guard
                try Row.fetchOne(
                    db, sql: "SELECT 1 FROM albums WHERE id = ? AND smart_query IS NULL", arguments: [album.rawValue])
                    != nil
            else { throw LibraryError.notFound }
            var position =
                try Int64.fetchOne(
                    db, sql: "SELECT coalesce(max(position), -1) FROM album_assets WHERE album_id = ?",
                    arguments: [album.rawValue]) ?? -1
            let statement = try db.makeStatement(
                sql: """
                    INSERT OR IGNORE INTO album_assets (album_id, asset_id, position, added_at)
                    SELECT ?, id, ?, ? FROM assets WHERE id = ?
                    """)
            for asset in assets {
                position += 1
                try statement.execute(arguments: [album.rawValue, position, now.timeIntervalSince1970, asset.rawValue])
            }
        }
    }

    public func removeAssets(_ assets: [AssetID], from album: AlbumID) async throws {
        guard !assets.isEmpty else { return }
        try await pool.write { db in
            let ids = assets.map(\.rawValue)
            try db.execute(
                sql: "DELETE FROM album_assets WHERE album_id = ? AND asset_id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: [album.rawValue] as StatementArguments + StatementArguments(ids))
        }
    }

    // MARK: Tags

    public func tags() async throws -> [Tag] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM tags ORDER BY name COLLATE NOCASE").map(Self.tag)
        }
    }

    private static func tag(_ row: Row) -> Tag { Tag(id: TagID(rawValue: row["id"]), name: row["name"]) }

    /// Tags `assets` with `name`, creating the tag if no tag has that name, ignoring case.
    @discardableResult
    public func addTag(named name: String, to assets: [AssetID]) async throws -> TagID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidName }
        return try await pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO tags (name) VALUES (?)", arguments: [name])
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name]) else {
                throw LibraryError.notFound
            }
            let statement = try db.makeStatement(
                sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) SELECT id, ? FROM assets WHERE id = ?")
            for asset in assets { try statement.execute(arguments: [id, asset.rawValue]) }
            return TagID(rawValue: id)
        }
    }

    public func addTag(_ tag: TagID, to assets: [AssetID]) async throws {
        try await pool.write { db in
            let statement = try db.makeStatement(
                sql: """
                    INSERT OR IGNORE INTO asset_tags (asset_id, tag_id)
                    SELECT a.id, t.id FROM assets a, tags t WHERE a.id = ? AND t.id = ?
                    """)
            for asset in assets { try statement.execute(arguments: [asset.rawValue, tag.rawValue]) }
        }
    }

    public func removeTag(_ tag: TagID, from assets: [AssetID]) async throws {
        guard !assets.isEmpty else { return }
        try await pool.write { db in
            let ids = assets.map(\.rawValue)
            try db.execute(
                sql: "DELETE FROM asset_tags WHERE tag_id = ? AND asset_id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: [tag.rawValue] as StatementArguments + StatementArguments(ids))
        }
    }

    /// Fails with `nameTaken` if another tag already has the name, ignoring case.
    public func renameTag(_ tag: TagID, to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidName }
        try await pool.write { db in
            if let other = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name]),
                other != tag.rawValue
            {
                throw LibraryError.nameTaken
            }
            try db.execute(sql: "UPDATE tags SET name = ? WHERE id = ?", arguments: [name, tag.rawValue])
        }
    }

    public func deleteTag(_ tag: TagID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tag.rawValue])
        }
    }

    /// How many of `assets` have each tag, for the Tags menu's check marks.
    public func tagCounts(of assets: [AssetID]) async throws -> [TagID: Int] {
        guard !assets.isEmpty else { return [:] }
        return try await pool.read { db in
            let ids = assets.map(\.rawValue)
            var counts: [TagID: Int] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT tag_id, count(*) AS n FROM asset_tags
                    WHERE asset_id IN (\(databaseQuestionMarks(count: ids.count))) GROUP BY tag_id
                    """,
                arguments: StatementArguments(ids))
            for row in rows { counts[TagID(rawValue: row["tag_id"])] = row["n"] }
            return counts
        }
    }

    // MARK: Inspector

    public func details(of asset: AssetID) async throws -> AssetDetails? {
        try await pool.read { db in
            guard
                let found = try Row.fetchOne(db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [asset.rawValue])?
                    .asset()
            else { return nil }
            let locations = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.*, v.name AS volume_name FROM file_instances f JOIN volumes v ON v.id = f.volume_id
                    WHERE f.asset_id = ? ORDER BY v.name, f.directory, f.name
                    """,
                arguments: [asset.rawValue]
            ).map { row in
                let instance = row.fileInstance()
                return AssetDetails.Location(
                    instance: instance.id, volume: instance.volumeID, volumeName: row["volume_name"],
                    path: instance.path, size: instance.size, modifiedTime: instance.modifiedTime)
            }
            let tags = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id, t.name FROM tags t JOIN asset_tags at ON at.tag_id = t.id
                    WHERE at.asset_id = ? ORDER BY t.name COLLATE NOCASE
                    """,
                arguments: [asset.rawValue]
            ).map(Self.tag)
            let albums = try Row.fetchAll(
                db,
                sql: """
                    SELECT al.id, al.name, al.smart_query FROM albums al JOIN album_assets aa ON aa.album_id = al.id
                    WHERE aa.asset_id = ? ORDER BY al.name COLLATE NOCASE
                    """,
                arguments: [asset.rawValue]
            ).map(Self.album)

            var kind: StackKind?
            var members: [AssetDetails.StackMember] = []
            if let stack = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.id, s.kind, s.cover_asset_id FROM stacks s JOIN stack_members m ON m.stack_id = s.id
                    WHERE m.asset_id = ? LIMIT 1
                    """,
                arguments: [asset.rawValue])
            {
                kind = StackKind(rawValue: stack["kind"])
                let cover: Int64? = stack["cover_asset_id"]
                members = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.asset_id, (SELECT name FROM file_instances WHERE asset_id = m.asset_id ORDER BY id LIMIT 1)
                            AS name
                        FROM stack_members m WHERE m.stack_id = ? ORDER BY m.position
                        """,
                    arguments: [stack["id"] as Int64]
                ).map { row in
                    let id: Int64 = row["asset_id"]
                    return AssetDetails.StackMember(
                        asset: AssetID(rawValue: id), name: row["name"] ?? "", isCover: id == cover)
                }
            }
            return AssetDetails(
                asset: found, locations: locations, tags: tags, albums: albums.filter { !$0.isSmart },
                stackKind: kind, stackMembers: members)
        }
    }

    public func instances(in source: BrowseSource, namePrefix prefix: String, limit: Int) async throws -> [Int64] {
        let pattern = (AssetFilter.escape(prefix) + "%").databaseValue
        return try await pool.read { db in
            let filter = AssetFilter.and([
                try AssetFilter.source(source, db), AssetFilter(sql: "f.name LIKE ? ESCAPE '\\'", arguments: [pattern]),
            ])
            return try Int64.fetchAll(
                db,
                sql: """
                    SELECT f.id FROM file_instances f JOIN assets a ON a.id = f.asset_id
                    WHERE \(filter.sql) ORDER BY f.name COLLATE NOCASE LIMIT ?
                    """,
                arguments: StatementArguments(filter.arguments + [limit.databaseValue]))
        }
    }
}
