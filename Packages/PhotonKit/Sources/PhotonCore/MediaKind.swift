/// Whether a file is a photo or a video. Anything else isn't indexed.
public enum MediaKind: Int, Sendable, Hashable, CaseIterable {
    case photo = 1
    case video = 2

    /// Matching is case-insensitive, because cameras write `.JPG` and `.MOV`.
    public init?(fileExtension: String) {
        let lowered = fileExtension.lowercased()
        if Self.photoExtensions.contains(lowered) {
            self = .photo
        } else if Self.videoExtensions.contains(lowered) {
            self = .video
        } else {
            return nil
        }
    }

    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "heic", "heif", "hif", "avif", "png", "gif", "tif", "tiff", "bmp", "webp",
        // Camera RAW formats.
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f",
        "3fr", "erf", "kdc", "mrw", "raw", "rwl", "iiq",
    ]

    // `.ts` is left out on purpose: it's a TypeScript file more often than a video.
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "3gp", "3g2", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "mts", "m2ts",
        "vob", "ogv", "dv", "asf", "divx", "rm", "rmvb", "mxf",
    ]
}
