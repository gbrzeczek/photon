import Foundation
internal import GRDB

/// SQL for sources, searches and smart albums, over `file_instances f JOIN assets a`. Kept here so that
/// nothing above `PhotonCore` sees SQL.
struct AssetFilter {
    var sql: String
    var arguments: [DatabaseValue]

    static let everything = AssetFilter(sql: "1", arguments: [])
    static let nothing = AssetFilter(sql: "0", arguments: [])

    static func and(_ filters: [AssetFilter]) -> AssetFilter {
        let parts = filters.filter { $0.sql != "1" }
        guard !parts.isEmpty else { return .everything }
        return AssetFilter(
            sql: parts.map { "(\($0.sql))" }.joined(separator: " AND "), arguments: parts.flatMap(\.arguments))
    }

    static func or(_ filters: [AssetFilter]) -> AssetFilter {
        guard !filters.isEmpty else { return .nothing }
        return AssetFilter(
            sql: filters.map { "(\($0.sql))" }.joined(separator: " OR "), arguments: filters.flatMap(\.arguments))
    }

    /// The rows of a source. A smart album is looked up here, so this needs the database.
    static func source(_ source: BrowseSource, _ db: Database) throws -> AssetFilter {
        switch source {
        case .folder(let scope):
            let filter = BrowseColumns.filter(scope, alias: "f")
            return AssetFilter(sql: filter.sql, arguments: filter.arguments)
        case .allItems:
            return .everything
        case .favorites:
            return AssetFilter(sql: "a.is_favorite = 1", arguments: [])
        case .tag(let tag):
            return AssetFilter(
                sql: "a.id IN (SELECT asset_id FROM asset_tags WHERE tag_id = ?)",
                arguments: [tag.rawValue.databaseValue])
        case .album(let album):
            guard let row = try Row.fetchOne(db, sql: "SELECT smart_query FROM albums WHERE id = ?", arguments: [album.rawValue])
            else { return .nothing }
            let json: String? = row["smart_query"]
            guard let json else {
                return AssetFilter(
                    sql: "a.id IN (SELECT asset_id FROM album_assets WHERE album_id = ?)",
                    arguments: [album.rawValue.databaseValue])
            }
            // A query from a newer Photon shows nothing rather than something wrong.
            guard let query = SmartQuery.decode(json) else { return .nothing }
            return smart(query)
        }
    }

    // MARK: Smart albums

    static func smart(_ query: SmartQuery, now: Date = Date(), timeZone: TimeZone = .current) -> AssetFilter {
        guard !query.rules.isEmpty else { return .everything }
        let rules = query.rules.map { rule($0, now: now, timeZone: timeZone) }
        return query.match == .all ? and(rules) : or(rules)
    }

    static func rule(_ rule: SmartRule, now: Date, timeZone: TimeZone) -> AssetFilter {
        switch rule {
        case .favorite(let flag):
            return AssetFilter(sql: "a.is_favorite = ?", arguments: [flag.databaseValue])
        case .kind(let kind):
            return AssetFilter(sql: "a.kind = ?", arguments: [kind.rawValue.databaseValue])
        case .tag(let tag, let matches):
            return AssetFilter(
                sql: "a.id \(matches ? "" : "NOT ")IN (SELECT asset_id FROM asset_tags WHERE tag_id = ?)",
                arguments: [tag.rawValue.databaseValue])
        case .album(let album, let contains):
            return AssetFilter(
                sql: "a.id \(contains ? "" : "NOT ")IN (SELECT asset_id FROM album_assets WHERE album_id = ?)",
                arguments: [album.rawValue.databaseValue])
        case .name(let text, let contains):
            return AssetFilter(
                sql: "f.name \(contains ? "" : "NOT ")LIKE ? ESCAPE '\\'", arguments: [containing(text).databaseValue])
        case .folder(let text, let contains):
            return AssetFilter(
                sql: "f.directory \(contains ? "" : "NOT ")LIKE ? ESCAPE '\\'",
                arguments: [containing(text).databaseValue])
        case .fileType(let type):
            let type = type.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return AssetFilter(sql: "f.name LIKE ? ESCAPE '\\'", arguments: [("%." + escape(type)).databaseValue])
        case .capturedWithin(let days):
            let start = wallClock(now, timeZone: timeZone) - Int64(days) * 86_400_000
            return AssetFilter(sql: "a.capture_date_ms >= ?", arguments: [start.databaseValue])
        case .capturedBefore(let date):
            return AssetFilter(
                sql: "a.capture_date_ms < ?", arguments: [startOfDay(date, timeZone: timeZone).databaseValue])
        case .capturedAfter(let date):
            // After the day, so the day itself isn't included.
            return AssetFilter(
                sql: "a.capture_date_ms >= ?",
                arguments: [(startOfDay(date, timeZone: timeZone) + 86_400_000).databaseValue])
        case .capturedInYear(let year):
            return yearFilter(year)
        case .durationLonger(let seconds):
            return AssetFilter(sql: "a.duration_seconds > ?", arguments: [seconds.databaseValue])
        case .durationShorter(let seconds):
            return AssetFilter(sql: "a.duration_seconds < ?", arguments: [seconds.databaseValue])
        }
    }

    // MARK: Search

    static func search(_ query: SearchQuery) -> AssetFilter {
        and(query.terms.map(term))
    }

    private static func term(_ term: SearchQuery.Term) -> AssetFilter {
        switch term {
        case .text(let text):
            return textFilter(text)
        case .kind(let kind, let text):
            return or([AssetFilter(sql: "a.kind = ?", arguments: [kind.rawValue.databaseValue]), textFilter(text)])
        case .year(let year, let text):
            return or([yearFilter(year), textFilter(text)])
        case .month(let month, let text):
            return or([
                AssetFilter(
                    sql: "CAST(strftime('%m', a.capture_date_ms / 1000, 'unixepoch') AS INTEGER) = ?",
                    arguments: [month.databaseValue]),
                textFilter(text),
            ])
        }
    }

    /// A file name or folder containing the text, or a tag or a manual album starting with it.
    private static func textFilter(_ text: String) -> AssetFilter {
        let anywhere = containing(text).databaseValue
        let prefix = (escape(text) + "%").databaseValue
        return AssetFilter(
            sql: """
                f.name LIKE ? ESCAPE '\\' OR f.directory LIKE ? ESCAPE '\\'
                OR a.id IN (SELECT at.asset_id FROM asset_tags at JOIN tags t ON t.id = at.tag_id
                    WHERE t.name LIKE ? ESCAPE '\\')
                OR a.id IN (SELECT aa.asset_id FROM album_assets aa JOIN albums al ON al.id = aa.album_id
                    WHERE al.smart_query IS NULL AND al.name LIKE ? ESCAPE '\\')
                """,
            arguments: [anywhere, anywhere, prefix, prefix])
    }

    // MARK: Helpers

    private static func yearFilter(_ year: Int) -> AssetFilter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Capture dates are wall-clock time read as UTC, so a year is UTC midnight to UTC midnight.
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        return AssetFilter(
            sql: "a.capture_date_ms >= ? AND a.capture_date_ms < ?",
            arguments: [
                Int64(start.timeIntervalSince1970 * 1000).databaseValue,
                Int64(end.timeIntervalSince1970 * 1000).databaseValue,
            ])
    }

    /// A moment as the wall clock here reads it, in the same milliseconds as capture dates.
    private static func wallClock(_ date: Date, timeZone: TimeZone) -> Int64 {
        Int64((date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))) * 1000)
    }

    /// The start of the day holding `date` here, as wall-clock milliseconds.
    private static func startOfDay(_ date: Date, timeZone: TimeZone) -> Int64 {
        let wall = wallClock(date, timeZone: timeZone)
        return wall - ((wall % 86_400_000) + 86_400_000) % 86_400_000
    }

    /// LIKE treats these as wildcards, and typed text means them literally.
    static func escape(_ text: String) -> String {
        text.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
    }

    private static func containing(_ text: String) -> String { "%" + escape(text) + "%" }
}
