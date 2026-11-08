import Foundation
internal import GRDB

extension LibraryStore {
    /// Runs a sorted query. The rows come back unsorted and are sorted here on plain integers or bytes,
    /// because that takes milliseconds at 100k rows and an `ORDER BY` over this join doesn't.
    /// Run it off the main thread: the cost grows with the folder.
    public func browse(_ scope: BrowseScope, sort: BrowseSort) async throws -> BrowseResult {
        let usesNames = sort.key == .name || sort.key == .type
        let columns = BrowseColumns.fetchSQL(scope: scope, names: usesNames)
        let raw = try await pool.read { db in
            var columnsOut = BrowseColumns()
            let rows = try Row.fetchCursor(db, sql: columns.sql, arguments: StatementArguments(columns.arguments))
            while let row = try rows.next() { columnsOut.append(row, names: usesNames, sort: sort.key) }
            return columnsOut
        }
        return raw.sorted(by: sort)
    }

    /// Full rows, in the order of `instances`. Bounded by the caller's page size.
    public func browseRows(instances: [Int64]) async throws -> [BrowseRow] {
        guard !instances.isEmpty else { return [] }
        return try await pool.read { db in
            let marks = databaseQuestionMarks(count: instances.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.*, a.kind, a.width, a.height, a.capture_date_ms, a.capture_utc_offset_min,
                        a.duration_seconds
                    FROM file_instances f JOIN assets a ON a.id = f.asset_id
                    WHERE f.id IN (\(marks))
                    """,
                arguments: StatementArguments(instances))
            var byID: [Int64: BrowseRow] = [:]
            byID.reserveCapacity(rows.count)
            for row in rows {
                let date: Int64? = row["capture_date_ms"]
                let id: Int64 = row["id"]
                byID[id] = BrowseRow(
                    assetID: AssetID(rawValue: row["asset_id"]),
                    instanceID: FileInstanceID(rawValue: id),
                    volumeID: VolumeID(rawValue: row["volume_id"]),
                    path: RelativePath(directory: row["directory"], name: row["name"]),
                    size: row["size"],
                    modifiedTime: FileTimestamp(nanoseconds: row["modified_ns"]),
                    kind: MediaKind(rawValue: row["kind"]) ?? .photo,
                    pixelWidth: row["width"], pixelHeight: row["height"],
                    captureDate: date.map {
                        CaptureDate(wallClockMilliseconds: $0, utcOffsetMinutes: row["capture_utc_offset_min"])
                    },
                    durationSeconds: row["duration_seconds"])
            }
            return instances.compactMap { byID[$0] }
        }
    }

    /// Instances in `scope` whose names start with `prefix`, ignoring case, best match first.
    /// For jumping to a typed name.
    public func instances(in scope: BrowseScope, namePrefix prefix: String, limit: Int) async throws -> [Int64] {
        // LIKE treats these as wildcards, and a typed name means them literally.
        let escaped = prefix.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
        let filter = BrowseColumns.filter(scope, alias: "f")
        return try await pool.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT f.id FROM file_instances f
                    WHERE \(filter.sql) AND f.name LIKE ? ESCAPE '\\'
                    ORDER BY f.name COLLATE NOCASE LIMIT ?
                    """,
                arguments: StatementArguments(filter.arguments + [(escaped + "%").databaseValue, limit.databaseValue]))
        }
    }

    /// Every root, and every folder holding indexed files, in path order.
    public func folders() async throws -> [BrowseFolder] {
        try await pool.read { db in
            var folders: [BrowseFolder] = []
            let roots = try Row.fetchAll(db, sql: "SELECT * FROM library_roots ORDER BY volume_id, relative_path")
                .map { $0.libraryRoot() }
            for root in roots {
                folders.append(BrowseFolder(volume: root.volumeID, path: root.relativePath, isRoot: true))
                let filter = BrowseColumns.filter(
                    BrowseScope(volume: root.volumeID, path: root.relativePath), alias: "f")
                let directories = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT f.directory FROM file_instances f WHERE \(filter.sql) ORDER BY f.directory",
                    arguments: StatementArguments(filter.arguments))
                var seen = Set([root.relativePath])
                for directory in directories {
                    // Include folders that hold only folders, so the tree has no gaps.
                    var ancestors: [String] = []
                    var path = directory
                    while seen.insert(path).inserted {
                        ancestors.append(path)
                        guard let slash = path.lastIndex(of: "/") else { break }
                        path = String(path[..<slash])
                    }
                    folders += ancestors.reversed().map {
                        BrowseFolder(volume: root.volumeID, path: $0, isRoot: false)
                    }
                }
            }
            return folders
        }
    }

    // MARK: Sessions

    public func session(for scope: BrowseScope) async throws -> BrowseSession? {
        try await pool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM sessions WHERE volume_id = ? AND relative_path = ?",
                arguments: [scope.volume.rawValue, scope.path]
            ).map(Self.session)
        }
    }

    /// The folder used last, to reopen at launch.
    public func latestSession() async throws -> BrowseSession? {
        try await pool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM sessions WHERE volume_id IS NOT NULL ORDER BY updated_at DESC, id DESC LIMIT 1"
            ).map(Self.session)
        }
    }

    public func saveSession(_ session: BrowseSession, now: Date = Date()) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (volume_id, relative_path, sort_key, sort_ascending, view_mode, tile_size, anchor_asset_id,
                         anchor_position, current_asset_id, viewer_open, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?,
                        (SELECT id FROM assets WHERE id = ?), ?,
                        (SELECT id FROM assets WHERE id = ?), ?, ?)
                    ON CONFLICT (volume_id, relative_path) WHERE volume_id IS NOT NULL DO UPDATE SET
                        sort_key = excluded.sort_key,
                        sort_ascending = excluded.sort_ascending,
                        view_mode = excluded.view_mode,
                        tile_size = excluded.tile_size,
                        anchor_asset_id = excluded.anchor_asset_id,
                        anchor_position = excluded.anchor_position,
                        current_asset_id = excluded.current_asset_id,
                        viewer_open = excluded.viewer_open,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    session.scope.volume.rawValue, session.scope.path, session.sort.key.rawValue,
                    session.sort.ascending, session.viewMode, session.tileSize, session.anchor?.rawValue,
                    session.anchorPosition, session.current?.rawValue, session.isViewerOpen,
                    now.timeIntervalSince1970,
                ])
        }
    }

    private static func session(_ row: Row) -> BrowseSession {
        let anchor: Int64? = row["anchor_asset_id"]
        let current: Int64? = row["current_asset_id"]
        return BrowseSession(
            scope: BrowseScope(volume: VolumeID(rawValue: row["volume_id"]), path: row["relative_path"]),
            sort: BrowseSort(
                key: SortKey(rawValue: row["sort_key"]) ?? .date, ascending: row["sort_ascending"]),
            viewMode: row["view_mode"], tileSize: row["tile_size"],
            anchor: anchor.map(AssetID.init(rawValue:)), anchorPosition: row["anchor_position"],
            current: current.map(AssetID.init(rawValue:)), isViewerOpen: row["viewer_open"])
    }
}

/// Unsorted query output, in plain arrays.
struct BrowseColumns: Sendable {
    private var assets: [Int64] = []
    private var instances: [Int64] = []
    private var aspects: [Float] = []
    private var colors: [UInt32] = []
    private var flags: [BrowseResult.Flags] = []
    private var durations: [Float] = []
    /// One value per row for the numeric sorts.
    private var numericKeys: [Int64] = []
    /// Keys one after another for the text sorts, with where each row's starts.
    private var textKeys: [UInt8] = []
    private var textOffsets: [Int32] = []

    private static let defaultVideoAspect: Float = 16.0 / 9.0
    /// A panorama shouldn't take a whole row, or a slice leave a sliver.
    private static let aspectRange: ClosedRange<Float> = 0.25...4

    static func filter(_ scope: BrowseScope, alias: String) -> (sql: String, arguments: [DatabaseValue]) {
        if scope.path.isEmpty { return ("\(alias).volume_id = ?", [scope.volume.rawValue.databaseValue]) }
        // Ranges over the unique index rather than LIKE. "0" is the character after "/".
        return (
            "\(alias).volume_id = ? AND (\(alias).directory = ? OR (\(alias).directory >= ? AND \(alias).directory < ?))",
            [
                scope.volume.rawValue.databaseValue, scope.path.databaseValue, (scope.path + "/").databaseValue,
                (scope.path + "0").databaseValue,
            ]
        )
    }

    static func fetchSQL(scope: BrowseScope, names: Bool) -> (sql: String, arguments: [DatabaseValue]) {
        let filter = filter(scope, alias: "f")
        return (
            """
            SELECT f.id, f.asset_id, f.size, f.modified_ns, a.kind, a.width, a.height, a.orientation, a.rotation,
                a.capture_date_ms, a.duration_seconds, a.dominant_color\(names ? ", f.name" : "")
            FROM file_instances f JOIN assets a ON a.id = f.asset_id
            WHERE \(filter.sql)
            """,
            filter.arguments
        )
    }

    /// Reads by column index, because this runs once per row of the folder.
    mutating func append(_ row: Row, names: Bool, sort: SortKey) {
        let kind: Int = row[4]
        let duration: Double? = row[10]
        let color: Int64? = row[11]
        var rowFlags: BrowseResult.Flags = kind == MediaKind.video.rawValue ? .video : []
        if color != nil { rowFlags.insert(.hasColor) }

        instances.append(row[0])
        assets.append(row[1])
        aspects.append(Self.aspect(
            width: row[5], height: row[6], orientation: row[7], rotation: row[8], isVideo: rowFlags.contains(.video)))
        colors.append(UInt32(truncatingIfNeeded: color ?? 0))
        flags.append(rowFlags)
        durations.append(Float(duration ?? 0))

        switch sort {
        case .date:
            let capture: Int64? = row[9]
            let modified: Int64 = row[3]
            numericKeys.append(capture ?? modified / 1_000_000)
        case .size:
            numericKeys.append(row[2])
        case .duration:
            numericKeys.append(duration.map { Int64($0 * 1000) } ?? -1)
        case .name, .type:
            let name: String = row[12]
            textOffsets.append(Int32(textKeys.count))
            if sort == .type {
                let fileExtension = RelativePath(directory: "", name: name).fileExtension.lowercased()
                textKeys.append(contentsOf: fileExtension.utf8)
                textKeys.append(1)  // Sorts below every character, so a shorter extension comes first.
            }
            NaturalSortKey.append(name, to: &textKeys)
        }
    }

    static func aspect(width: Int?, height: Int?, orientation: Int?, rotation: Int, isVideo: Bool) -> Float {
        guard let width, let height, width > 0, height > 0 else { return isVideo ? defaultVideoAspect : 1 }
        // EXIF orientations 5 to 8 are a quarter turn, and so is an odd non-destructive rotation.
        let turned = ((orientation ?? 1) >= 5) != (rotation % 2 == 1)
        let aspect = turned ? Float(height) / Float(width) : Float(width) / Float(height)
        return min(max(aspect, aspectRange.lowerBound), aspectRange.upperBound)
    }

    func sorted(by sort: BrowseSort) -> BrowseResult {
        var order = uniqueRows()
        switch sort.key {
        case .date, .size, .duration:
            numericKeys.withUnsafeBufferPointer { keys in
                order.sort { keys[Int($0)] != keys[Int($1)] ? keys[Int($0)] < keys[Int($1)] : $0 < $1 }
            }
        case .name, .type:
            textKeys.withUnsafeBufferPointer { bytes in
                textOffsets.withUnsafeBufferPointer { offsets in
                    let base = bytes.baseAddress!
                    order.sort { left, right in
                        let a = base + Int(offsets[Int(left)])
                        let b = base + Int(offsets[Int(right)])
                        var index = 0
                        // Every key ends in its only zero byte.
                        while a[index] == b[index] {
                            if a[index] == 0 { return left < right }
                            index += 1
                        }
                        return a[index] < b[index]
                    }
                }
            }
        }
        if !sort.ascending { order.reverse() }
        if sort.key == .duration {
            // Items with no duration go last, in both directions.
            let timed = order.filter { numericKeys[Int($0)] >= 0 }
            let untimed = order.filter { numericKeys[Int($0)] < 0 }
            order = timed + untimed
        }
        return BrowseResult(
            assetIDs: order.map { assets[Int($0)] },
            instanceIDs: order.map { instances[Int($0)] },
            aspects: order.map { aspects[Int($0)] },
            colors: order.map { colors[Int($0)] },
            flags: order.map { flags[Int($0)] },
            durations: order.map { durations[Int($0)] })
    }

    /// Rows to keep: the first of each asset, as a list of row numbers. A bitmap over the id range is
    /// much cheaper than a set, and ids are dense.
    private func uniqueRows() -> [Int32] {
        guard let lowest = assets.min(), let highest = assets.max() else { return [] }
        let range = Int(highest - lowest) + 1
        var seen = [UInt64](repeating: 0, count: range / 64 + 1)
        var rows: [Int32] = []
        rows.reserveCapacity(assets.count)
        for (row, asset) in assets.enumerated() {
            let bit = Int(asset - lowest)
            let mask: UInt64 = 1 << UInt64(bit & 63)
            if seen[bit >> 6] & mask == 0 {
                seen[bit >> 6] |= mask
                rows.append(Int32(row))
            }
        }
        return rows
    }
}
