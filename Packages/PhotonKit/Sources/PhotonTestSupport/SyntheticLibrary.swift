import Foundation
import PhotonIndex

public enum SyntheticLibraryError: Error, Equatable {
    /// Synthetic files must never land on a real drive.
    case refusedLocation(String)
    case encodingFailed
}

/// Generates a folder of camera-shaped media, so that tests never depend on personal photos.
public struct SyntheticLibrary: Sendable {
    public struct Options: Sendable {
        public var fileCount = 100
        public var seed: UInt64 = 1
        public var filesPerFolder = 200
        /// One file in this many is a video.
        public var videoInterval = 10
        /// One file in this many is an exact copy of the file before it. Zero for none.
        public var duplicateInterval = 25
        /// Pads files to about this size, as a camera's file would be. Zero for tiny files.
        public var averageBytes = 0
        public init() {}
    }

    public struct Manifest: Hashable, Sendable {
        public var files: [String] = []
        public var photos = 0
        public var videos = 0
        public var duplicates = 0
        public var bytes: Int64 = 0
        /// Distinct content, which is how many assets the library should end up with.
        public var uniqueContent: Int { files.count - duplicates }
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    /// Writes the library under `root`, which must be on the internal disk or a disk image.
    @discardableResult
    public func generate(at root: URL) throws -> Manifest {
        try Self.ensureSafeLocation(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let templates = try makeTemplates()
        var generator = SeededGenerator(seed: options.seed)
        var manifest = Manifest()
        var previous: Data?

        for index in 0..<options.fileCount {
            let folder = "DCIM/\(100 + index / options.filesPerFolder)SYNTH"
            let directory = root.appending(path: folder, directoryHint: .isDirectory)
            if index % options.filesPerFolder == 0 {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let isDuplicate = options.duplicateInterval > 0 && index > 0 && index % options.duplicateInterval == 0
            let isVideo = options.videoInterval > 0 && index % options.videoInterval == 1
            let name: String
            let bytes: Data
            if isDuplicate, let previous {
                name = "COPY_\(String(format: "%06d", index)).JPG"
                bytes = previous
                manifest.duplicates += 1
                manifest.photos += 1
            } else if isVideo {
                var movie = SyntheticMedia.MovieOptions()
                movie.seed = options.seed &+ UInt64(index)
                movie.moovAtEnd = index % 20 == 1
                movie.durationUnits = UInt64(600 + index % 3600)
                movie.mediaBytes = max(4096, paddedLength(&generator))
                name = "VID_\(String(format: "%06d", index)).MP4"
                bytes = SyntheticMedia.movie(movie)
                manifest.videos += 1
            } else {
                let template = templates[index % templates.count]
                var photo = SyntheticMedia.uniquified(jpeg: template, marker: options.seed &* 31 &+ UInt64(index))
                let padding = paddedLength(&generator)
                if padding > photo.count { photo.append(noise(padding - photo.count, &generator)) }
                name = "IMG_\(String(format: "%06d", index)).JPG"
                bytes = photo
                manifest.photos += 1
            }

            try bytes.write(to: directory.appending(path: name, directoryHint: .notDirectory))
            manifest.files.append(folder + "/" + name)
            manifest.bytes += Int64(bytes.count)
            previous = isVideo ? previous : bytes
        }
        return manifest
    }

    private func makeTemplates() throws -> [Data] {
        try (0..<16).map { index in
            var image = SyntheticMedia.ImageOptions()
            image.seed = options.seed &+ UInt64(index)
            image.width = 160 + index * 8
            image.height = 120 + index * 6
            image.captureDate = String(format: "2024:%02d:%02d 12:%02d:00", 1 + index % 12, 1 + index, index)
            image.orientation = [1, 1, 6, 8][index % 4]
            guard let data = SyntheticMedia.jpeg(image) else { throw SyntheticLibraryError.encodingFailed }
            return data
        }
    }

    private func paddedLength(_ generator: inout SeededGenerator) -> Int {
        guard options.averageBytes > 0 else { return 0 }
        return Int.random(in: (options.averageBytes / 2)...(options.averageBytes * 3 / 2), using: &generator)
    }

    private func noise(_ count: Int, _ generator: inout SeededGenerator) -> Data {
        // Bytes after a JPEG's end marker are ignored by decoders. One block repeats, which keeps
        // generation fast, and the leading bytes differ per file.
        var data = Data(capacity: count)
        var block = Data(count: min(count, 4096))
        block.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 7, by: 8) {
                bytes.storeBytes(of: generator.next(), toByteOffset: offset, as: UInt64.self)
            }
        }
        while data.count < count { data.append(block.prefix(count - data.count)) }
        return data
    }

    /// Checks the nearest existing ancestor, before anything has been created.
    public static func ensureSafeLocation(_ root: URL) throws {
        var candidate = root.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
        }
        let volume = try MountedVolume.containing(path: candidate.path).volume
        guard volume.location == .internal || volume.location == .diskImage else {
            throw SyntheticLibraryError.refusedLocation(
                "Synthetic files only go on the internal disk or a disk image.")
        }
    }
}
