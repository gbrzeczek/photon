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

    @Test("The v1 schema matches its snapshot, so a shipped migration can't be edited unnoticed")
    func schemaSnapshot() async throws {
        let store = try LibraryStore(url: temporaryURL())
        let snapshotURL = try #require(Bundle.module.url(forResource: "Fixtures/schema-v1", withExtension: "sql"))
        let snapshot = try String(contentsOf: snapshotURL, encoding: .utf8)
        #expect(try await schema(store) == snapshot, "Add a migration instead of editing v1.")
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
