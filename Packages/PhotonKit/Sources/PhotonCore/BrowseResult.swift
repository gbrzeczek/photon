import Foundation

/// Which part of the library to show: a folder and everything under it. Empty means the whole volume.
public struct BrowseScope: Hashable, Sendable {
    public var volume: VolumeID
    public var path: String

    public init(volume: VolumeID, path: String) {
        self.volume = volume
        self.path = path
    }

    /// The folder above this one, staying inside `root`.
    public func parent(within root: String) -> BrowseScope? {
        guard path != root, !path.isEmpty else { return nil }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        return BrowseScope(volume: volume, path: parent)
    }
}

public enum SortKey: String, Sendable, Hashable, CaseIterable {
    case date, name, size, type, duration

    /// Which way a new sort starts: newest and largest first, names from A.
    public var defaultAscending: Bool {
        switch self {
        case .date, .size, .duration: false
        case .name, .type: true
        }
    }
}

public struct BrowseSort: Hashable, Sendable {
    public var key: SortKey
    public var ascending: Bool

    public init(key: SortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    public static let `default` = BrowseSort(key: .date, ascending: false)
}

/// A sorted query as compact arrays, one entry per row. There are no per-item objects, so a million
/// rows stay cheap, and it's safe to hand from a background task to the main thread.
///
/// A row is one asset. Exact duplicates in a folder show as one tile, the first in path order.
public final class BrowseResult: Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let video = Flags(rawValue: 1)
        public static let hasColor = Flags(rawValue: 2)
    }

    public let assetIDs: [Int64]
    public let instanceIDs: [Int64]
    /// Width over height, after orientation and rotation.
    public let aspects: [Float]
    /// 0xRRGGBB, valid where `flags` has `hasColor`.
    public let colors: [UInt32]
    public let flags: [Flags]
    /// Seconds, or zero when unknown.
    public let durations: [Float]

    public var count: Int { assetIDs.count }

    public init(
        assetIDs: [Int64], instanceIDs: [Int64], aspects: [Float], colors: [UInt32], flags: [Flags],
        durations: [Float]
    ) {
        self.assetIDs = assetIDs
        self.instanceIDs = instanceIDs
        self.aspects = aspects
        self.colors = colors
        self.flags = flags
        self.durations = durations
    }

    public static let empty = BrowseResult(
        assetIDs: [], instanceIDs: [], aspects: [], colors: [], flags: [], durations: [])

    /// The row holding `asset`, by scanning. Proportional to the library, so run it off the main thread.
    public func row(of asset: AssetID) -> Int? {
        assetIDs.firstIndex(of: asset.rawValue)
    }

    /// For each row of this result, its row in `other`, or -1 if it's gone. Off the main thread.
    public func rowMap(to other: BrowseResult) -> [Int32] {
        var rows = [Int64: Int32](minimumCapacity: other.count)
        for (row, asset) in other.assetIDs.enumerated() { rows[asset] = Int32(row) }
        return assetIDs.map { rows[$0] ?? -1 }
    }
}

/// One row with everything the list and accessibility show. Loaded in pages.
public struct BrowseRow: Hashable, Sendable {
    public var assetID: AssetID
    public var instanceID: FileInstanceID
    public var volumeID: VolumeID
    public var path: RelativePath
    public var size: Int64
    public var modifiedTime: FileTimestamp
    public var kind: MediaKind
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var captureDate: CaptureDate?
    public var durationSeconds: Double?
}

/// A folder with indexed files, for the sidebar.
public struct BrowseFolder: Hashable, Sendable {
    public var volume: VolumeID
    public var path: String
    public var isRoot: Bool

    public init(volume: VolumeID, path: String, isRoot: Bool) {
        self.volume = volume
        self.path = path
        self.isRoot = isRoot
    }
}

/// The saved state of a folder's view, anchored to an asset and never to a pixel offset.
public struct BrowseSession: Hashable, Sendable {
    public var scope: BrowseScope
    public var sort: BrowseSort
    /// 0 for tiles, 1 for the list.
    public var viewMode: Int
    public var tileSize: Double?
    /// What the view keeps on screen.
    public var anchor: AssetID?
    /// How far down the viewport `anchor` was, from 0 to 1.
    public var anchorPosition: Double?
    /// The current item, which may have been scrolled away from.
    public var current: AssetID?
    public var isViewerOpen: Bool

    public init(
        scope: BrowseScope, sort: BrowseSort, viewMode: Int, tileSize: Double?, anchor: AssetID?,
        anchorPosition: Double? = nil, current: AssetID? = nil, isViewerOpen: Bool = false
    ) {
        self.scope = scope
        self.sort = sort
        self.viewMode = viewMode
        self.tileSize = tileSize
        self.anchor = anchor
        self.anchorPosition = anchorPosition
        self.current = current
        self.isViewerOpen = isViewerOpen
    }
}

/// Sort keys that make `IMG_2` come before `IMG_10`, comparable as plain bytes.
///
/// `localizedStandardCompare` gives the order Finder uses, but at 100k rows it costs seconds. This is
/// close to it for camera names, and building and comparing bytes takes milliseconds.
enum NaturalSortKey {
    private static let digitRun: UInt8 = 2

    /// Appends the key for `name`, ending in a zero byte.
    static func append(_ name: String, to key: inout [UInt8]) {
        var name = name
        let isASCII = name.withUTF8 { bytes in bytes.allSatisfy { $0 < 0x80 } }
        if !isASCII {
            name = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        name.withUTF8 { bytes in
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 48, byte <= 57 {
                    // Digits go before letters, and a longer run of significant digits is a larger number.
                    var start = index
                    while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
                    while start < index - 1, bytes[start] == 48 { start += 1 }
                    key.append(digitRun)
                    key.append(UInt8(min(index - start, 255)))
                    key.append(contentsOf: bytes[start..<index])
                } else {
                    key.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
                    index += 1
                }
            }
        }
        key.append(0)
    }
}
