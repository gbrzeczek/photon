import CoreGraphics
import Foundation
import ImageIO
import PhotonCore
import PhotonIndex

/// Reads image properties from bytes in memory. A URL is never handed to `CGImageSource`, because it
/// could memory-map a file on removable media.
enum ImageMetadataReader {
    /// A prefix this long held the metadata for every non-HEIC file in Spike 4.
    static let prefixLength = 256 * 1024
    /// A second try for files whose metadata starts later, such as some RAW formats.
    static let longPrefixLength = 4 << 20
    /// Above this, a file isn't read in full just for metadata.
    static let fullReadLimit: Int64 = 512 << 20

    /// ImageIO can't read these from part of a file (Spike 4), so they need the full read straight away.
    private static let fullReadFormats: Set<String> = ["heic", "heif", "hif", "avif"]

    static func read(fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
        for length in readLengths(fileExtension: fileExtension, size: source.size) {
            let data = try source.read(offset: 0, length: length)
            if let metadata = parse(data, isComplete: Int64(data.count) >= source.size) { return metadata }
        }
        return nil
    }

    private static func readLengths(fileExtension: String, size: Int64) -> [Int] {
        let whole = size <= fullReadLimit ? [Int(size)] : []
        if fullReadFormats.contains(fileExtension) { return whole }
        return [prefixLength, longPrefixLength].filter { Int64($0) < size } + whole
    }

    /// Returns nil unless the bytes at least give the dimensions, so a longer read can be tried.
    static func parse(_ data: Data, isComplete: Bool) -> MediaMetadata? {
        guard !data.isEmpty else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = CGImageSourceCreateIncremental(options)
        CGImageSourceUpdateData(source, data as CFData, isComplete)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        return MediaMetadata(
            pixelWidth: width,
            pixelHeight: height,
            orientation: (properties[kCGImagePropertyOrientation] as? Int).flatMap { (1...8).contains($0) ? $0 : nil },
            captureDate: captureDate(properties))
    }

    private static func captureDate(_ properties: [CFString: Any]) -> CaptureDate? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates: [(String?, String?, String?)] = [
            (
                exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
            ),
            (
                exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                exif?[kCGImagePropertyExifSubsecTimeDigitized] as? String,
                exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String
            ),
            (tiff?[kCGImagePropertyTIFFDateTime] as? String, nil, nil),
        ]
        for (date, subseconds, offset) in candidates {
            if let date, let parsed = ExifDate.parse(date, subseconds: subseconds, offset: offset) { return parsed }
        }
        return nil
    }
}

/// EXIF's `YYYY:MM:DD HH:MM:SS`. Parsed by hand: this runs for every file, on several threads, and
/// cameras write invalid values such as all zeros.
enum ExifDate {
    static func parse(_ string: String, subseconds: String?, offset: String?) -> CaptureDate? {
        let digits = string.utf8.map { $0 }
        guard digits.count >= 19 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                guard (48...57).contains(digits[index]) else { return nil }
                value = value * 10 + Int(digits[index]) - 48
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
            let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
            (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
            hour < 24, minute < 60, second < 61
        else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        var milliseconds = Int64(days) * 86_400_000
        milliseconds += Int64(hour * 3600 + minute * 60 + second) * 1000
        if let subseconds {
            // "5" means 500 ms, not 5 ms.
            let fraction = (subseconds.filter(\.isNumber) + "000").prefix(3)
            milliseconds += Int64(fraction) ?? 0
        }
        return CaptureDate(wallClockMilliseconds: milliseconds, utcOffsetMinutes: offset.flatMap(parseOffset))
    }

    /// `+02:00`, `-05:30`.
    static func parseOffset(_ string: String) -> Int? {
        let bytes = Array(string.utf8)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
            let hours = Int(String(string.dropFirst().prefix(2))),
            let minutes = Int(String(string.suffix(2))),
            hours <= 14, minutes < 60
        else { return nil }
        return (bytes[0] == 45 ? -1 : 1) * (hours * 60 + minutes)
    }

    /// Days since 1970 in the proleptic Gregorian calendar, without allocating a `Calendar`.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
