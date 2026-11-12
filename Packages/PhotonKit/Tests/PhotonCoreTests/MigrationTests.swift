import Foundation
import GRDB
import Testing

@testable import PhotonCore

@Suite("Migrations keep user libraries working")
struct MigrationTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "photon-migrations-\(UUID().uuidString)")
            .appending(path: "Library.sqlite")
    }

    /// Every table and index, in a stable order.
    private func schema(_ store: LibraryStore) async throws -> String {
        try await store.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT sql FROM sqlite_master
                    WHERE sql IS NOT NULL AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%'
                    ORDER BY type DESC, name
                    """
            ).joined(separator: ";\n\n") + ";\n"
        }
    }

    /// Every table and index, in a stable order, for a database at any migration.
    private static let schemaSQL = """
        SELECT sql FROM sqlite_master
        WHERE sql IS NOT NULL AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%'
        ORDER BY type DESC, name
        """

    private func snapshot(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "sql"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The v1 schema matches its snapshot, so a shipped migration can't be edited unnoticed")
    func schemaSnapshotV1() throws {
        let queue = try DatabaseQueue()
        try LibraryMigrations.migrator.migrate(queue, upTo: "v1")
        let schema = try queue.read { try String.fetchAll($0, sql: Self.schemaSQL).joined(separator: ";\n\n") + ";\n" }
        #expect(schema == (try snapshot("schema-v1")), "Add a migration instead of editing v1.")
    }

    @Test("The v2 schema matches its snapshot")
    func schemaSnapshotV2() throws {
        let queue = try DatabaseQueue()
        try LibraryMigrations.migrator.migrate(queue, upTo: "v2")
        let schema = try queue.read { try String.fetchAll($0, sql: Self.schemaSQL).joined(separator: ";\n\n") + ";\n" }
        #expect(schema == (try snapshot("schema-v2")), "Add a migration instead of editing v2.")
    }

    @Test("The v3 schema matches its snapshot")
    func schemaSnapshotV3() throws {
        let queue = try DatabaseQueue()
        try LibraryMigrations.migrator.migrate(queue, upTo: "v3")
        let schema = try queue.read { try String.fetchAll($0, sql: Self.schemaSQL).joined(separator: ";\n\n") + ";\n" }
        #expect(schema == (try snapshot("schema-v3")), "Add a migration instead of editing v3.")
    }

    @Test("The v4 schema matches its snapshot")
    func schemaSnapshotV4() throws {
        let queue = try DatabaseQueue()
        try LibraryMigrations.migrator.migrate(queue, upTo: "v4")
        let schema = try queue.read { try String.fetchAll($0, sql: Self.schemaSQL).joined(separator: ";\n\n") + ";\n" }
        #expect(schema == (try snapshot("schema-v4")), "Add a migration instead of editing v4.")
    }

    @Test("The v5 schema matches its snapshot")
    func schemaSnapshotV5() throws {
        let queue = try DatabaseQueue()
        try LibraryMigrations.migrator.migrate(queue, upTo: "v5")
        let schema = try queue.read { try String.fetchAll($0, sql: Self.schemaSQL).joined(separator: ";\n\n") + ";\n" }
        #expect(schema == (try snapshot("schema-v5")), "Add a migration instead of editing v5.")
    }

    @Test("The v6 schema matches its snapshot, which is v5's, because v6 changes only data")
    func schemaSnapshotV6() async throws {
        let store = try LibraryStore(url: temporaryURL())
        #expect(try await schema(store) == (try snapshot("schema-v6")), "Add a migration instead of editing v6.")
        #expect(try snapshot("schema-v6") == (try snapshot("schema-v5")))
    }

    @Test("A v5 library upgrades in place, and videos no engine could read get another try")
    func upgradeFromV5() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: url.path)
            try LibraryMigrations.migrator.migrate(queue, upTo: "v5")
            try await queue.write { db in
                // 1: an MKV with no metadata and a failed thumbnail. 2: an MP4 that read fine, whose
                // thumbnail failed. 3: an MP4 with everything. 4: a photo that failed.
                try db.execute(
                    sql: """
                        INSERT INTO volumes (id, uuid, name, first_seen_at, last_seen_at) VALUES (1, 'U', 'Drive', 0, 0);
                        INSERT INTO assets (id, kind, width, height, duration_seconds, thumbnail_state, created_at) VALUES
                            (1, 2, NULL, NULL, NULL, 3, 0),
                            (2, 2, 1920, 1080, 12.5, 3, 0),
                            (3, 2, 1920, 1080, 12.5, 2, 0),
                            (4, 1, 4000, 3000, NULL, 3, 0);
                        INSERT INTO file_instances (id, asset_id, volume_id, directory, name, size, modified_ns, index_state)
                        VALUES
                            (1, 1, 1, 'Videos', 'trip.mkv', 100, 1, 1),
                            (2, 2, 1, 'Videos', 'odd.mp4', 100, 1, 1),
                            (3, 3, 1, 'Videos', 'fine.mp4', 100, 1, 1),
                            (4, 4, 1, 'Photos', 'bad.jpg', 100, 1, 2);
                        """)
            }
        }
        let store = try LibraryStore(url: url)
        let (thumbnails, indexing) = try await store.pool.read { db in
            (
                try [Int: Int](
                    uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, thumbnail_state FROM assets").map {
                        ($0["id"], $0["thumbnail_state"])
                    }),
                try [Int: Int](
                    uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, index_state FROM file_instances").map {
                        ($0["id"], $0["index_state"])
                    })
            )
        }
        #expect(thumbnails == [1: 0, 2: 0, 3: 2, 4: 3])
        #expect(indexing == [1: 0, 2: 1, 3: 1, 4: 2])
    }

    @Test("A v4 library upgrades in place, with every folder closed, and the tree's folders save")
    func upgradeFromV4() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: url.path)
            try LibraryMigrations.migrator.migrate(queue, upTo: "v4")
            try await queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO volumes (id, uuid, name, first_seen_at, last_seen_at) VALUES (1, 'U', 'Drive', 0, 0);
                        INSERT INTO sessions (volume_id, relative_path, sort_key, updated_at) VALUES (1, 'Photos', 'name', 1);
                        """)
            }
        }
        let store = try LibraryStore(url: url)
        #expect(try await store.latestSession()?.source == .folder(BrowseScope(volume: VolumeID(rawValue: 1), path: "Photos")))
        #expect(try await store.expandedFolders().isEmpty)

        let photos = BrowseScope(volume: VolumeID(rawValue: 1), path: "Photos")
        let trip = BrowseScope(volume: VolumeID(rawValue: 1), path: "Photos/Trip")
        try await store.setFolder(photos, expanded: true)
        try await store.setFolder(trip, expanded: true)
        try await store.setFolder(trip, expanded: true)
        try await store.setFolder(trip, expanded: false)
        // A volume that isn't in the library saves nothing.
        try await store.setFolder(BrowseScope(volume: VolumeID(rawValue: 99), path: "X"), expanded: true)
        #expect(try await store.expandedFolders() == [photos])

        // They go with their volume.
        try await store.pool.write { try $0.execute(sql: "DELETE FROM volumes WHERE id = 1") }
        #expect(try await store.expandedFolders().isEmpty)
    }

    @Test("A v3 library upgrades in place, keeping folder and album sessions and organization data")
    func upgradeFromV3() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: url.path)
            try LibraryMigrations.migrator.migrate(queue, upTo: "v3")
            try await queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO volumes (id, uuid, name, first_seen_at, last_seen_at) VALUES (1, 'U', 'Drive', 0, 0);
                        INSERT INTO assets (id, kind, created_at, is_favorite) VALUES (7, 1, 0, 1);
                        INSERT INTO albums (id, name, created_at) VALUES (3, 'Trip', 0);
                        INSERT INTO album_assets (album_id, asset_id, added_at) VALUES (3, 7, 0);
                        INSERT INTO sessions (volume_id, relative_path, sort_key, anchor_asset_id, current_asset_id,
                            anchor_position, viewer_open, tile_size, updated_at)
                        VALUES (1, 'Photos', 'name', 7, 7, 0.5, 1, 120, 1);
                        INSERT INTO sessions (album_id, sort_key, updated_at) VALUES (3, 'date', 2);
                        """)
            }
        }
        let store = try LibraryStore(url: url)
        let folder = try #require(try await store.session(for: BrowseScope(volume: VolumeID(rawValue: 1), path: "Photos")))
        #expect(folder.sort.key == .name)
        #expect(folder.anchor == AssetID(rawValue: 7) && folder.current == AssetID(rawValue: 7))
        #expect(folder.anchorPosition == 0.5 && folder.isViewerOpen && folder.tileSize == 120)
        #expect(try await store.latestSession()?.source == .album(AlbumID(rawValue: 3)))
        #expect(try await store.asset(AssetID(rawValue: 7))?.isFavorite == true)
        let album = try await store.browse(.album(AlbumID(rawValue: 3)), sort: .default)
        #expect(album.assetIDs.isEmpty)  // The asset has no file, so it has no row, but it's still in the album.
        let members = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM album_assets") }
        #expect(members == 1)
        // A source that v3 couldn't store saves now.
        try await store.saveSession(BrowseSession(source: .favorites, sort: .default, viewMode: 0, tileSize: nil, anchor: nil))
        #expect(try await store.session(for: .favorites) != nil)
    }

    @Test("A v2 library upgrades in place, and its sessions keep their anchors")
    func upgradeFromV2() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: url.path)
            try LibraryMigrations.migrator.migrate(queue, upTo: "v2")
            try await queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO volumes (id, uuid, name, first_seen_at, last_seen_at) VALUES (1, 'U', 'Drive', 0, 0);
                        INSERT INTO assets (id, kind, created_at) VALUES (7, 1, 0);
                        INSERT INTO sessions (volume_id, relative_path, sort_key, anchor_asset_id, updated_at)
                        VALUES (1, 'Photos', 'date', 7, 1);
                        """)
            }
        }
        let store = try LibraryStore(url: url)
        let session = try #require(try await store.latestSession())
        #expect(session.scope?.path == "Photos")
        #expect(session.anchor == AssetID(rawValue: 7))
        #expect(session.current == AssetID(rawValue: 7))
        #expect(session.anchorPosition == nil)
        #expect(!session.isViewerOpen)
    }

    @Test("A v1 library upgrades in place and keeps its assets, with thumbnails still to make")
    func upgradeFromV1() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: url.path)
            try LibraryMigrations.migrator.migrate(queue, upTo: "v1")
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO assets (kind, created_at, is_favorite) VALUES (1, 0, 1)")
            }
        }
        let store = try LibraryStore(url: url)
        let asset = try #require(try await store.asset(AssetID(rawValue: 1)))
        #expect(asset.isFavorite)
        let state = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT thumbnail_state FROM assets") }
        #expect(state == 0)
    }

    @Test("The plan's tables all exist, including those whose features arrive later")
    func requiredTablesExist() async throws {
        let store = try LibraryStore(url: temporaryURL())
        let tables = try await store.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        for table in [
            "volumes", "assets", "file_instances", "stacks", "stack_members", "albums", "album_assets", "tags",
            "asset_tags", "sessions",
        ] {
            #expect(tables.contains(table))
        }
    }

    @Test("Reopening a library keeps its data")
    func reopenKeepsData() async throws {
        let url = temporaryURL()
        do {
            let store = try LibraryStore(url: url)
            let volume = try await store.insertVolume(uuid: "U", name: "N", capacity: nil, filesystem: nil)
            _ = try await store.applyDirectory(volume: volume.id, directory: "D", files: [TestLibrary.file("a.jpg")])
        }
        let reopened = try LibraryStore(url: url)
        let volume = try #require(try await reopened.volumes(uuid: "U").first)
        #expect(try await reopened.instances(volume: volume.id, directory: "D").count == 1)
    }

    @Test("A library from a newer Photon is refused rather than damaged")
    func newerLibraryIsRefused() async throws {
        let url = temporaryURL()
        do {
            let store = try LibraryStore(url: url)
            try await store.pool.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')")
            }
        }
        #expect(throws: LibraryError.newerLibrary) { try LibraryStore(url: url) }
    }

    @Test("Foreign keys are on, so a file can't point at a missing asset")
    func foreignKeysAreEnforced() async throws {
        let library = try await TestLibrary()
        await #expect(throws: (any Error).self) {
            try await library.execute(
                "INSERT INTO file_instances (asset_id, volume_id, directory, name, size, modified_ns) VALUES (999, ?, '', 'x', 1, 1)",
                [library.volume.rawValue])
        }
    }

    @Test("An asset with a file can't be deleted out from under it")
    func assetsWithFilesAreProtected() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        await #expect(throws: (any Error).self) {
            try await library.execute("DELETE FROM assets WHERE id = ?", [instance.assetID.rawValue])
        }
    }

    @Test("Two assets can't share a hash, but any number can have none")
    func hashesAreUnique() async throws {
        let library = try await TestLibrary()
        try await library.add("a.jpg")
        try await library.add("b.jpg")
        #expect(try await library.store.assetCount() == 2)

        let hash = TestLibrary.hash(1).bytes
        try await library.execute("UPDATE assets SET content_hash = ? WHERE id = 1", [hash])
        await #expect(throws: (any Error).self) {
            try await library.execute("UPDATE assets SET content_hash = ? WHERE id = 2", [hash])
        }
    }

    @Test("The library uses WAL")
    func usesWAL() async throws {
        let store = try LibraryStore(url: temporaryURL())
        let mode = try await store.pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }

    @Test("The pending query uses its index, so it stays fast as a library grows")
    func pendingQueryUsesIndex() async throws {
        let library = try await TestLibrary()
        let details = try await library.store.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN SELECT * FROM file_instances
                    WHERE volume_id = 1 AND index_state = 0 AND id > 0 ORDER BY id LIMIT 10
                    """
            ).map { row -> String in row["detail"] }
        }
        #expect(details.contains { $0.contains("file_instances_pending") })
    }
}
