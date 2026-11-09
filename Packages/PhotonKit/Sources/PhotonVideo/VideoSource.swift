import Foundation
import PhotonCore
import PhotonIndex

/// One video file to play or take frames from, and the scheduler that every read of it goes through.
public struct VideoSource: Sendable {
    public var path: RelativePath
    /// What the library recorded. A file that no longer matches isn't read.
    public var size: Int64
    public var modifiedTime: FileTimestamp
    public var scheduler: VolumeIOScheduler

    public init(path: RelativePath, size: Int64, modifiedTime: FileTimestamp, scheduler: VolumeIOScheduler) {
        self.path = path
        self.size = size
        self.modifiedTime = modifiedTime
        self.scheduler = scheduler
    }

    public init(_ instance: FileInstance, scheduler: VolumeIOScheduler) {
        self.init(path: instance.path, size: instance.size, modifiedTime: instance.modifiedTime, scheduler: scheduler)
    }

    public var fileExtension: String { path.fileExtension.lowercased() }
}

/// The formats each engine takes, by extension, so that choosing one reads nothing.
public enum VideoFormats {
    /// What AVFoundation opens from a file. MPEG-TS, Matroska, WebM and AVI aren't among them.
    public static let avFoundation: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2"]
}
