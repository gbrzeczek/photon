import Foundation
internal import GRDB

/// The library database. It lives on the internal disk, so disconnected drives stay browsable
/// and nothing is ever written to them.
///
/// GRDB stays private to this module: other layers go through this type's API, so `PhotonUI` can't
/// reach SQL. Writes go through GRDB's single writer, and all calls are `async`, so they never block
/// the caller's thread.
public final class LibraryStore: Sendable {
    let pool: DatabasePool
    public let databaseURL: URL

    /// Opens the library at `url`, creating it if needed, and applies any pending migrations.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.label = "PhotonLibrary"
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            // WAL is GRDB's default for a pool. NORMAL is safe with WAL, and much cheaper during indexing.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        databaseURL = url

        let migrator = LibraryMigrations.migrator
        if try pool.read({ try migrator.hasBeenSuperseded($0) }) {
            throw LibraryError.newerLibrary
        }
        try migrator.migrate(pool)
    }

    /// `~/Library/Application Support/Photon/Library.sqlite`.
    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Photon", directoryHint: .isDirectory)
            .appending(path: "Library.sqlite", directoryHint: .notDirectory)
    }
}

extension Row {
    /// Decodes a row selected from `file_instances`.
    func fileInstance() -> FileInstance {
        FileInstance(
            id: FileInstanceID(rawValue: self["id"]),
            assetID: AssetID(rawValue: self["asset_id"]),
            volumeID: VolumeID(rawValue: self["volume_id"]),
            path: RelativePath(directory: self["directory"], name: self["name"]),
            size: self["size"],
            modifiedTime: FileTimestamp(nanoseconds: self["modified_ns"]),
            indexState: IndexState(rawValue: self["index_state"]) ?? .pending,
            indexAttempts: self["index_attempts"],
            indexError: self["index_error"])
    }

    /// Decodes a row selected from `assets`.
    func asset() -> Asset {
        let captureMilliseconds: Int64? = self["capture_date_ms"]
        let colorValue: Int64? = self["dominant_color"]
        let hashBytes: Data? = self["content_hash"]
        return Asset(
            id: AssetID(rawValue: self["id"]),
            contentHash: hashBytes.flatMap(ContentHash.init(bytes:)),
            kind: MediaKind(rawValue: self["kind"]) ?? .photo,
            metadata: MediaMetadata(
                pixelWidth: self["width"],
                pixelHeight: self["height"],
                orientation: self["orientation"],
                captureDate: captureMilliseconds.map {
                    CaptureDate(wallClockMilliseconds: $0, utcOffsetMinutes: self["capture_utc_offset_min"])
                },
                durationSeconds: self["duration_seconds"]),
            dominantColor: colorValue.map { UInt32(truncatingIfNeeded: $0) },
            isFavorite: self["is_favorite"],
            rotation: self["rotation"])
    }

    func volume() -> Volume {
        Volume(
            id: VolumeID(rawValue: self["id"]),
            uuid: self["uuid"],
            name: self["name"],
            capacity: self["capacity"],
            filesystem: self["filesystem"],
            lastSeenAt: Date(timeIntervalSince1970: self["last_seen_at"]))
    }

    func libraryRoot() -> LibraryRoot {
        let completed: Double? = self["last_scan_completed_at"]
        return LibraryRoot(
            id: self["id"],
            volumeID: VolumeID(rawValue: self["volume_id"]),
            relativePath: self["relative_path"],
            lastScanCompletedAt: completed.map(Date.init(timeIntervalSince1970:)))
    }
}
