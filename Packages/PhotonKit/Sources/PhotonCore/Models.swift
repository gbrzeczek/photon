import Foundation

/// When a photo or video was taken.
public struct CaptureDate: Hashable, Sendable {
    /// Milliseconds since 1970, reading the camera's wall clock as if it were UTC.
    /// EXIF dates usually carry no time zone, so this is the value that sorts consistently.
    public var wallClockMilliseconds: Int64
    /// Minutes east of UTC, when the file states it.
    public var utcOffsetMinutes: Int?

    public init(wallClockMilliseconds: Int64, utcOffsetMinutes: Int? = nil) {
        self.wallClockMilliseconds = wallClockMilliseconds
        self.utcOffsetMinutes = utcOffsetMinutes
    }
}

/// What the metadata stage learns about a file. Every field is optional, because files often lack them.
public struct MediaMetadata: Hashable, Sendable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// An EXIF orientation from 1 to 8.
    public var orientation: Int?
    public var captureDate: CaptureDate?
    public var durationSeconds: Double?

    public init(
        pixelWidth: Int? = nil, pixelHeight: Int? = nil, orientation: Int? = nil,
        captureDate: CaptureDate? = nil, durationSeconds: Double? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.captureDate = captureDate
        self.durationSeconds = durationSeconds
    }

    /// Whether this could be the same picture after an in-place edit: same capture date and dimensions,
    /// with width and height allowed to swap, to allow for rotation.
    ///
    /// A missing date or dimension never counts as a match. Attaching a favorite to the wrong picture
    /// is worse than leaving it on the old content.
    public func isSamePicture(as other: MediaMetadata) -> Bool {
        guard let date = captureDate?.wallClockMilliseconds, date == other.captureDate?.wallClockMilliseconds,
            let width = pixelWidth, let height = pixelHeight,
            let otherWidth = other.pixelWidth, let otherHeight = other.pixelHeight
        else { return false }
        return (width == otherWidth && height == otherHeight) || (width == otherHeight && height == otherWidth)
    }
}

public struct Volume: Hashable, Sendable, Identifiable {
    public var id: VolumeID
    public var uuid: String
    public var name: String
    public var capacity: Int64?
    public var filesystem: String?
    public var lastSeenAt: Date
}

public struct LibraryRoot: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var volumeID: VolumeID
    /// A directory relative to the volume root. Empty means the whole volume.
    public var relativePath: String
    public var lastScanCompletedAt: Date?
}

public struct Asset: Hashable, Sendable, Identifiable {
    public var id: AssetID
    /// Nil while the asset is provisional, before the file has been hashed.
    public var contentHash: ContentHash?
    public var kind: MediaKind
    public var metadata: MediaMetadata
    public var dominantColor: UInt32?
    public var isFavorite: Bool
    /// Non-destructive rotation, in clockwise quarter turns from 0 to 3.
    public var rotation: Int
}

public enum IndexState: Int, Sendable, Hashable {
    /// Waiting for the metadata and hash stages.
    case pending = 0
    case complete = 1
    /// Gave up after repeated read failures. A change to the file puts it back to pending.
    case failed = 2
}

public struct FileInstance: Hashable, Sendable, Identifiable {
    public var id: FileInstanceID
    public var assetID: AssetID
    public var volumeID: VolumeID
    public var path: RelativePath
    public var size: Int64
    public var modifiedTime: FileTimestamp
    public var indexState: IndexState
    public var indexAttempts: Int
    public var indexError: String?
}

/// One file seen during enumeration.
public struct ScannedFile: Hashable, Sendable {
    public var name: String
    public var kind: MediaKind
    public var size: Int64
    public var modifiedTime: FileTimestamp

    public init(name: String, kind: MediaKind, size: Int64, modifiedTime: FileTimestamp) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedTime = modifiedTime
    }
}

/// What a directory listing changed in the library.
public struct DirectoryChanges: Hashable, Sendable {
    public var added = 0
    public var modified = 0
    public var removed = 0
    public var unchanged = 0
    public init() {}
}

/// The outcome of reading one file: its hash, and its metadata if the file had any.
/// `size` and `modifiedTime` are what was read, so a result for a file that has since changed is dropped.
public struct IndexedFile: Hashable, Sendable {
    public var instanceID: FileInstanceID
    public var size: Int64
    public var modifiedTime: FileTimestamp
    public var hash: ContentHash
    public var metadata: MediaMetadata?

    public init(
        instanceID: FileInstanceID, size: Int64, modifiedTime: FileTimestamp, hash: ContentHash,
        metadata: MediaMetadata?
    ) {
        self.instanceID = instanceID
        self.size = size
        self.modifiedTime = modifiedTime
        self.hash = hash
        self.metadata = metadata
    }
}

/// How the identity rules resolved a batch of indexed files.
public struct IdentityCounts: Hashable, Sendable {
    /// Provisional assets that took their first hash.
    public var hashed = 0
    /// Provisional assets merged into an existing asset with the same hash.
    public var merged = 0
    /// Files that changed but kept their asset, because they're the same picture.
    public var rehashed = 0
    /// Files that changed into different content, and so got a different asset.
    public var reassigned = 0
    /// Results dropped because the file changed after it was read.
    public var stale = 0
    public init() {}
}

/// Indexing state for one volume, for status displays.
public struct VolumeSummary: Hashable, Sendable, Identifiable {
    public var volume: Volume
    public var roots: [LibraryRoot]
    public var fileCount: Int
    public var pendingCount: Int
    public var failedCount: Int
    public var totalBytes: Int64
    public var id: VolumeID { volume.id }
}

public enum LibraryError: Error, Equatable {
    /// The library was written by a newer Photon. Opening it could damage it.
    case newerLibrary
    case notFound
    /// A tag or album name that's empty once trimmed.
    case invalidName
    /// Another tag already has this name, ignoring case.
    case nameTaken
}
