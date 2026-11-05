import CryptoKit
import Foundation
import PhotonCore

/// The identity hash from docs/PLAN.md: SHA-256 over the file size and sampled head, middle and tail chunks.
///
/// Changing anything here changes every asset's identity, and needs a migration that re-hashes libraries.
public enum ContentHasher {
    public static let chunkSize = 64 * 1024

    public static func hash(_ source: any ByteSource) throws -> ContentHash {
        var hasher = SHA256()
        let size = source.size
        withUnsafeBytes(of: UInt64(size).littleEndian) { hasher.update(bufferPointer: $0) }

        let chunk = Int64(chunkSize)
        if size <= chunk * 3 {
            try absorb(source, offset: 0, length: Int(size), into: &hasher)
        } else {
            for offset in [0, size / 2 - chunk / 2, size - chunk] {
                try absorb(source, offset: offset, length: chunkSize, into: &hasher)
            }
        }
        guard let hash = ContentHash(bytes: Data(hasher.finalize())) else {
            preconditionFailure("SHA-256 always produces 32 bytes")
        }
        return hash
    }

    private static func absorb(
        _ source: any ByteSource, offset: Int64, length: Int, into hasher: inout SHA256
    ) throws {
        let data = try source.read(offset: offset, length: length)
        // A short read means the file shrank underneath us, so this wouldn't be a hash of anything real.
        guard data.count == length else { throw IndexingError.fileChanged }
        hasher.update(data: data)
    }
}
