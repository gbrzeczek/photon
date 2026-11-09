import AVFoundation
import CoreGraphics
import PhotonCore
import PhotonIndex
import PhotonMedia

/// Video frames for stored thumbnails, from AVFoundation, reading through the scheduler.
public struct AVFoundationThumbnailer: VideoThumbnailing {
    public init() {}

    public func canThumbnail(fileExtension: String) -> Bool {
        VideoFormats.avFoundation.contains(fileExtension.lowercased())
    }

    public func poster(
        of instance: FileInstance, scheduler: VolumeIOScheduler, priority: IOPriority, maxPixelSize: Int
    ) async throws -> CGImage? {
        let loader = ScheduledResourceLoader(source: VideoSource(instance, scheduler: scheduler), priority: priority)
        return try await VideoFrames.poster(loader: loader, maxPixelSize: maxPixelSize)
    }
}

/// Still frames from a video, for thumbnails and scrub previews.
enum VideoFrames {
    static func poster(loader: ScheduledResourceLoader, maxPixelSize: Int) async throws -> CGImage? {
        let asset = loader.makeAsset()
        let box = UncheckedGenerator(generator: makeGenerator(asset, maxPixelSize: maxPixelSize))
        do {
            let duration = try await asset.load(.duration).seconds
            let time = VideoPoster.time(duration: duration)
            return try await withTaskCancellationHandler {
                try await box.generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            } onCancel: {
                box.generator.cancelAllCGImageGeneration()
                loader.cancelAll()
            }
        } catch {
            try Task.checkCancellation()
            // A read that failed for the drive's sake says nothing about the file.
            if let readError = loader.readError { throw readError }
            return nil
        }
    }

    /// Takes the nearest keyframe within the tolerance, which decodes one frame instead of a run of them.
    static func makeGenerator(_ asset: AVAsset, maxPixelSize: Int, tolerance: Double = 1) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let window = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = window
        generator.requestedTimeToleranceAfter = window
        return generator
    }
}
