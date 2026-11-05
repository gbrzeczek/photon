import Foundation
import GRDB
import Testing

@testable import PhotonCore

/// A library in a temporary folder, with shortcuts for what identity tests need.
final class TestLibrary: Sendable {
    let directory: URL
    let store: LibraryStore
    let volume: VolumeID

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "photon-core-\(UUID().uuidString)")
        store = try LibraryStore(url: directory.appending(path: "Library.sqlite"))
        volume = try await store.insertVolume(uuid: "VOLUME-A", name: "A", capacity: 1, filesystem: "exfat").id
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func hash(_ byte: UInt8) -> ContentHash { ContentHash(bytes: Data(repeating: byte, count: 32))! }

    static func file(_ name: String, size: Int64 = 100, modified: Int64 = 1000) -> ScannedFile {
        ScannedFile(name: name, kind: .photo, size: size, modifiedTime: FileTimestamp(nanoseconds: modified))
    }

    /// Enumerates one file into `directory` and returns its row.
    @discardableResult
    func add(
        _ name: String, directory: String = "DCIM", on volume: VolumeID? = nil, size: Int64 = 100, modified: Int64 = 1000
    ) async throws -> FileInstance {
        let volume = volume ?? self.volume
        let existing = try await store.instances(volume: volume, directory: directory)
            .filter { $0.path.name != name }
            .map { ScannedFile(name: $0.path.name, kind: .photo, size: $0.size, modifiedTime: $0.modifiedTime) }
        _ = try await store.applyDirectory(
            volume: volume, directory: directory, files: existing + [Self.file(name, size: size, modified: modified)])
        return try #require(
            try await store.instance(volume: volume, path: RelativePath(directory: directory, name: name)))
    }

    /// Records a hash and metadata for a file, as the read stage would.
    @discardableResult
    func index(_ instance: FileInstance, hash: ContentHash, metadata: MediaMetadata? = nil) async throws -> IdentityCounts {
        try await store.applyIndexed([
            IndexedFile(
                instanceID: instance.id, size: instance.size, modifiedTime: instance.modifiedTime, hash: hash,
                metadata: metadata)
        ])
    }

    /// Adds a file and indexes it in one step, and returns its asset.
    func addIndexed(
        _ name: String, directory: String = "DCIM", on volume: VolumeID? = nil, hash: ContentHash,
        metadata: MediaMetadata? = nil
    ) async throws -> FileInstance {
        let instance = try await add(name, directory: directory, on: volume)
        try await index(instance, hash: hash, metadata: metadata)
        return try await reload(instance)
    }

    func reload(_ instance: FileInstance) async throws -> FileInstance {
        try #require(try await store.instance(volume: instance.volumeID, path: instance.path))
    }

    func asset(_ instance: FileInstance) async throws -> Asset {
        let current = try await reload(instance)
        return try #require(try await store.asset(current.assetID))
    }

    // Organization features arrive in Milestone 5, so tests set this data directly.

    func execute(_ sql: String, _ arguments: [any DatabaseValueConvertible] = []) async throws {
        let values = arguments.map(\.databaseValue)
        try await store.pool.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(values))
        }
    }

    func favorite(_ asset: AssetID) async throws {
        try await execute("UPDATE assets SET is_favorite = 1 WHERE id = ?", [asset.rawValue])
    }

    func rotate(_ asset: AssetID, _ quarterTurns: Int) async throws {
        try await execute("UPDATE assets SET rotation = ? WHERE id = ?", [quarterTurns, asset.rawValue])
    }

    func addToAlbum(_ asset: AssetID, albumID: Int64 = 1) async throws {
        try await execute("INSERT OR IGNORE INTO albums (id, name, created_at) VALUES (?, 'Album', 0)", [albumID])
        try await execute(
            "INSERT INTO album_assets (album_id, asset_id, added_at) VALUES (?, ?, 0)", [albumID, asset.rawValue])
    }

    func tag(_ asset: AssetID, tagID: Int64 = 1) async throws {
        try await execute("INSERT OR IGNORE INTO tags (id, name) VALUES (?, ?)", [tagID, "tag\(tagID)"])
        try await execute("INSERT INTO asset_tags (asset_id, tag_id) VALUES (?, ?)", [asset.rawValue, tagID])
    }

    func count(_ sql: String) async throws -> Int {
        try await store.pool.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }
}

let photoA = MediaMetadata(
    pixelWidth: 4000, pixelHeight: 3000,
    captureDate: CaptureDate(wallClockMilliseconds: 1_700_000_000_000))
