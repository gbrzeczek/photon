import Foundation
import PhotonCore

/// Random access to a file's bytes. Implementations read normally and never memory-map,
/// because pulling a drive during a mapped read kills the process.
public protocol ByteSource: AnyObject {
    var size: Int64 { get }
    /// Reads up to `length` bytes. The result is shorter only at the end of the file.
    func read(offset: Int64, length: Int) throws -> Data
}

/// Reads metadata from a file. Implemented in `PhotonMedia`, which sits above this layer.
public protocol MetadataExtracting: Sendable {
    /// Returns nil for a file it can't make sense of, which isn't a failure: the file still gets a hash.
    /// Throws only what `source` throws, so that a removed drive is never mistaken for a bad file.
    func metadata(kind: MediaKind, fileExtension: String, from source: any ByteSource) throws -> MediaMetadata?
}

/// Bytes already in memory.
public final class DataByteSource: ByteSource {
    private let data: Data
    public init(_ data: Data) { self.data = Data(data) }
    public var size: Int64 { Int64(data.count) }

    public func read(offset: Int64, length: Int) throws -> Data {
        guard offset < data.count else { return Data() }
        let start = Int(offset)
        return data.subdata(in: start..<min(start + length, data.count))
    }
}

/// Keeps the longest prefix read so far, so that one read serves both metadata and hashing.
/// A full read is the expensive step, and it should only happen once for a file.
final class PrefixCachingSource: ByteSource {
    private let base: any ByteSource
    private var prefix = Data()

    init(_ base: any ByteSource) { self.base = base }

    var size: Int64 { base.size }

    func read(offset: Int64, length: Int) throws -> Data {
        let end = min(offset + Int64(length), size)
        if end <= Int64(prefix.count), offset <= end {
            return prefix.subdata(in: Int(offset)..<Int(end))
        }
        let data = try base.read(offset: offset, length: length)
        if offset == 0, data.count > prefix.count { prefix = data }
        return data
    }
}
