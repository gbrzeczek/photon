import CoreGraphics
import PhotonCore
import PhotonIndex

/// Makes a still frame from a video, for its stored thumbnails. Implemented in `PhotonVideo`, which sits
/// above this layer. Every read goes through `scheduler`, so it's cancellable and never memory-maps.
public protocol VideoThumbnailing: Sendable {
    /// Whether this format can be decoded at all, answered without reading anything.
    func canThumbnail(fileExtension: String) -> Bool

    /// A frame near the start, upright, at most `maxPixelSize` on its long edge. Returns nil for a file
    /// that can't be decoded, which marks it as failed.
    ///
    /// Throws when the file couldn't be read, which isn't the file's fault: `VolumeIOError` for the
    /// volume, `CancellationError`, or `VideoReadError.fileChanged` when it isn't the indexed file.
    func poster(
        of instance: FileInstance, scheduler: VolumeIOScheduler, priority: IOPriority, maxPixelSize: Int
    ) async throws -> CGImage?
}

public enum VideoReadError: Error, Equatable, Sendable {
    /// The file's size or modified time isn't what the library has. A rescan picks it up.
    case fileChanged
}
