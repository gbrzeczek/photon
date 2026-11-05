import Foundation
import PhotonCore
import PhotonIndex

/// Reads metadata from a file's bytes, with no system framework touching the file itself.
/// Everything goes through the `ByteSource`, and so through the volume's I/O scheduler.
public struct MediaMetadataReader: MetadataExtracting {
    public init() {}

    public func metadata(
        kind: MediaKind, fileExtension: String, from source: any ByteSource
    ) throws -> MediaMetadata? {
        switch kind {
        case .photo:
            try ImageMetadataReader.read(fileExtension: fileExtension.lowercased(), from: source)
        case .video:
            try VideoMetadataReader.read(fileExtension: fileExtension.lowercased(), from: source)
        }
    }
}
