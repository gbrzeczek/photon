import Foundation

/// Photon's own identifier for a volume. It's not the volume UUID, which clones share.
public struct VolumeID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { "volume-\(rawValue)" }
}

/// One piece of content. All organization data attaches here, never to a path.
public struct AssetID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { "asset-\(rawValue)" }
}

/// One copy of an asset at a location on a volume.
public struct FileInstanceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { "instance-\(rawValue)" }
}

/// A sampled SHA-256 over a file's size and chunks of its contents.
///
/// Good enough for identity, but it isn't proof that two files are identical.
/// Any destructive action must compare the full contents first.
public struct ContentHash: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hex }
}

/// A file's modified time, in nanoseconds since 1970.
/// Stored as an integer because rescans compare it for exact equality.
public struct FileTimestamp: Hashable, Sendable, Comparable {
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    public init(seconds: Int, nanoseconds: Int) {
        self.nanoseconds = Int64(seconds) &* 1_000_000_000 &+ Int64(nanoseconds)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }
}

/// A location relative to a volume root. Mount paths change, so absolute paths are never stored.
public struct RelativePath: Hashable, Sendable, CustomStringConvertible {
    /// The containing directory, with no leading or trailing slash. Empty at the volume root.
    public let directory: String
    public let name: String

    public init(directory: String, name: String) {
        self.directory = directory
        self.name = name
    }

    /// Fails for absolute paths and for paths that climb out of the volume.
    public init?(string: String) {
        guard !string.isEmpty, !string.hasPrefix("/"), !string.hasSuffix("/") else { return nil }
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return nil }
        self.name = String(parts[parts.count - 1])
        self.directory = parts.dropLast().joined(separator: "/")
    }

    public var string: String { directory.isEmpty ? name : directory + "/" + name }
    public var description: String { string }

    /// The extension without its dot, or an empty string.
    public var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }
}
