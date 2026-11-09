import Foundation

/// An album, manual or smart. Albums hold assets, never files.
public struct AlbumID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { "album-\(rawValue)" }
}

public struct TagID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { "tag-\(rawValue)" }
}

public struct Album: Hashable, Sendable, Identifiable {
    public var id: AlbumID
    public var name: String
    /// Nil for a manual album. A smart album that this version can't read has `isReadable` false.
    public var smartQuery: SmartQuery?
    public var isSmart: Bool
    public var isReadable: Bool { !isSmart || smartQuery != nil }
}

public struct Tag: Hashable, Sendable, Identifiable {
    public var id: TagID
    public var name: String
}

public enum StackKind: Int, Sendable, Hashable {
    case rawAndJPEG = 1
    case livePhoto = 2
}

/// What the browser shows. Grid, list and viewer don't know which, because each is a query that gives
/// the same `BrowseResult`.
public enum BrowseSource: Hashable, Sendable {
    case folder(BrowseScope)
    case allItems
    case favorites
    /// A manual or a smart album.
    case album(AlbumID)
    case tag(TagID)

    public var folder: BrowseScope? {
        if case .folder(let scope) = self { return scope }
        return nil
    }
}

/// How a query is shown, beyond its source.
public struct BrowseOptions: Hashable, Sendable {
    /// Words typed into the search field. Every one must match.
    public var search: String
    /// Show every member of a stack, instead of its cover alone.
    public var expandsStacks: Bool
    /// Volumes that are online now. A source spanning volumes prefers their files for each asset.
    public var preferredVolumes: Set<VolumeID>

    public init(search: String = "", expandsStacks: Bool = false, preferredVolumes: Set<VolumeID> = []) {
        self.search = search
        self.expandsStacks = expandsStacks
        self.preferredVolumes = preferredVolumes
    }
}

// MARK: Smart albums

/// A saved query: all or any of a list of rules. Stored as JSON in `albums.smart_query`.
public struct SmartQuery: Hashable, Sendable, Codable {
    public enum Match: String, Sendable, Codable, CaseIterable {
        case all, any
    }

    public var match: Match
    public var rules: [SmartRule]

    public init(match: Match = .all, rules: [SmartRule]) {
        self.match = match
        self.rules = rules
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }

    /// Nil when the JSON isn't something this version understands, such as a rule from a newer Photon.
    public static func decode(_ json: String) -> SmartQuery? {
        try? JSONDecoder().decode(SmartQuery.self, from: Data(json.utf8))
    }
}

/// One condition of a smart album. Each case says what it compares, so an editor can show it as pop-ups.
public enum SmartRule: Hashable, Sendable, Codable {
    case favorite(Bool)
    case kind(MediaKind)
    case tag(TagID, matches: Bool)
    case album(AlbumID, contains: Bool)
    case name(String, contains: Bool)
    case folder(String, contains: Bool)
    /// The extension, without its dot, ignoring case.
    case fileType(String)
    case capturedWithin(days: Int)
    case capturedBefore(Date)
    case capturedAfter(Date)
    case capturedInYear(Int)
    case durationLonger(seconds: Double)
    case durationShorter(seconds: Double)

    private enum CodingKeys: String, CodingKey {
        case field, value, flag
    }

    private enum Field: String, Codable {
        case favorite, kind, tag, album, name, folder, fileType, capturedWithin, capturedBefore, capturedAfter,
            capturedInYear, durationLonger, durationShorter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown field throws here, which makes the whole query unreadable rather than wrong.
        let field = try container.decode(Field.self, forKey: .field)
        func flag() throws -> Bool { try container.decodeIfPresent(Bool.self, forKey: .flag) ?? true }
        switch field {
        case .favorite: self = .favorite(try flag())
        case .kind:
            guard let kind = MediaKind(rawValue: try container.decode(Int.self, forKey: .value)) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Unknown kind")
            }
            self = .kind(kind)
        case .tag: self = .tag(TagID(rawValue: try container.decode(Int64.self, forKey: .value)), matches: try flag())
        case .album:
            self = .album(AlbumID(rawValue: try container.decode(Int64.self, forKey: .value)), contains: try flag())
        case .name: self = .name(try container.decode(String.self, forKey: .value), contains: try flag())
        case .folder: self = .folder(try container.decode(String.self, forKey: .value), contains: try flag())
        case .fileType: self = .fileType(try container.decode(String.self, forKey: .value))
        case .capturedWithin: self = .capturedWithin(days: try container.decode(Int.self, forKey: .value))
        case .capturedBefore:
            self = .capturedBefore(Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .value)))
        case .capturedAfter:
            self = .capturedAfter(Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .value)))
        case .capturedInYear: self = .capturedInYear(try container.decode(Int.self, forKey: .value))
        case .durationLonger: self = .durationLonger(seconds: try container.decode(Double.self, forKey: .value))
        case .durationShorter: self = .durationShorter(seconds: try container.decode(Double.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .favorite(let flag):
            try container.encode(Field.favorite, forKey: .field)
            try container.encode(flag, forKey: .flag)
        case .kind(let kind):
            try container.encode(Field.kind, forKey: .field)
            try container.encode(kind.rawValue, forKey: .value)
        case .tag(let tag, let matches):
            try container.encode(Field.tag, forKey: .field)
            try container.encode(tag.rawValue, forKey: .value)
            try container.encode(matches, forKey: .flag)
        case .album(let album, let contains):
            try container.encode(Field.album, forKey: .field)
            try container.encode(album.rawValue, forKey: .value)
            try container.encode(contains, forKey: .flag)
        case .name(let text, let contains):
            try container.encode(Field.name, forKey: .field)
            try container.encode(text, forKey: .value)
            try container.encode(contains, forKey: .flag)
        case .folder(let text, let contains):
            try container.encode(Field.folder, forKey: .field)
            try container.encode(text, forKey: .value)
            try container.encode(contains, forKey: .flag)
        case .fileType(let type):
            try container.encode(Field.fileType, forKey: .field)
            try container.encode(type, forKey: .value)
        case .capturedWithin(let days):
            try container.encode(Field.capturedWithin, forKey: .field)
            try container.encode(days, forKey: .value)
        case .capturedBefore(let date):
            try container.encode(Field.capturedBefore, forKey: .field)
            try container.encode(date.timeIntervalSince1970, forKey: .value)
        case .capturedAfter(let date):
            try container.encode(Field.capturedAfter, forKey: .field)
            try container.encode(date.timeIntervalSince1970, forKey: .value)
        case .capturedInYear(let year):
            try container.encode(Field.capturedInYear, forKey: .field)
            try container.encode(year, forKey: .value)
        case .durationLonger(let seconds):
            try container.encode(Field.durationLonger, forKey: .field)
            try container.encode(seconds, forKey: .value)
        case .durationShorter(let seconds):
            try container.encode(Field.durationShorter, forKey: .field)
            try container.encode(seconds, forKey: .value)
        }
    }
}

// MARK: Search

/// The words of a search, each of which must match. See docs/PLAN.md, under Organization.
public struct SearchQuery: Hashable, Sendable {
    public enum Term: Hashable, Sendable {
        /// Matches a file name, a folder path, or the start of a tag's or an album's name.
        case text(String)
        /// A kind word also matches as text, since a file can be called "video.jpg".
        case kind(MediaKind, text: String)
        /// A four-digit year of capture, or text.
        case year(Int, text: String)
        /// A month of capture, from 1 to 12, or text.
        case month(Int, text: String)
    }

    public var terms: [Term]

    public var isEmpty: Bool { terms.isEmpty }

    public init(_ text: String, monthNames: [[String]] = SearchQuery.defaultMonthNames) {
        terms = text.split(whereSeparator: \.isWhitespace).map { word in
            let word = String(word)
            let lowered = word.lowercased()
            switch lowered {
            case "photo", "photos": return .kind(.photo, text: word)
            case "video", "videos": return .kind(.video, text: word)
            default: break
            }
            if lowered.count == 4, let year = Int(lowered), (1800...2200).contains(year) {
                return .year(year, text: word)
            }
            for names in monthNames {
                if let index = names.firstIndex(where: { $0.lowercased() == lowered }) {
                    return .month(index + 1, text: word)
                }
            }
            return .text(word)
        }
    }

    /// Month names in English and the current language, full and short.
    public static let defaultMonthNames: [[String]] = {
        var lists: [[String]] = []
        for identifier in ["en_US", Locale.current.identifier] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            lists.append(formatter.monthSymbols)
            // A month term matches as text too, so a short name like "Mar" still finds "Marseille".
            lists.append(formatter.shortMonthSymbols.map { $0.trimmingCharacters(in: .punctuationCharacters) })
        }
        return lists
    }()
}
