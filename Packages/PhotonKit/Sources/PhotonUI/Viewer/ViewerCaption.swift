import Foundation
import PhotonCore

/// What the window's title says about the photo in the viewer.
public struct ViewerCaption: Equatable, Sendable {
    public var name: String
    /// When it was taken, or else last changed.
    public var detail: String
    public var isVideo: Bool

    init(_ row: BrowseRow) {
        name = (row.path.string as NSString).lastPathComponent
        isVideo = row.kind == .video
        detail = Self.date(row)
    }

    private static func date(_ row: BrowseRow) -> String {
        if let capture = row.captureDate {
            // Capture dates are the camera's wall clock, so they show as written.
            let date = Date(timeIntervalSince1970: Double(capture.wallClockMilliseconds) / 1000)
            return date.formatted(Date.FormatStyle(date: .long, time: .shortened, timeZone: .gmt))
        }
        let date = Date(timeIntervalSince1970: Double(row.modifiedTime.nanoseconds) / 1e9)
        return date.formatted(date: .long, time: .shortened)
    }
}
