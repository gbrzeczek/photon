import Foundation
import PhotonCore
import PhotonIndex
import PhotonTestSupport
import Testing

@testable import PhotonMedia

/// Counts reads, so tests can prove how much of a file was needed.
final class CountingSource: ByteSource {
    private let data: Data
    private(set) var reads: [(offset: Int64, length: Int)] = []
    var bytesRead: Int { reads.map(\.length).reduce(0, +) }
    init(_ data: Data) { self.data = data }
    var size: Int64 { Int64(data.count) }

    func read(offset: Int64, length: Int) throws -> Data {
        let start = Int(min(offset, Int64(data.count)))
        let end = min(start + length, data.count)
        reads.append((offset, end - start))
        return data.subdata(in: start..<end)
    }
}

/// Fails every read, as a removed drive would.
final class FailingSource: ByteSource {
    struct DriveGone: Error {}
    let size: Int64 = 1 << 20
    func read(offset: Int64, length: Int) throws -> Data { throw DriveGone() }
}

private let hasHEICEncoder = SyntheticMedia.heic() != nil

@Suite("Photo metadata")
struct ImageMetadataTests {
    private let reader = MediaMetadataReader()

    private func read(_ data: Data, extension fileExtension: String = "jpg") throws -> MediaMetadata? {
        try reader.metadata(kind: .photo, fileExtension: fileExtension, from: DataByteSource(data))
    }

    @Test("Reads dimensions, orientation and capture date from a JPEG")
    func jpeg() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 320
        options.height = 200
        options.captureDate = "2024:06:15 13:45:30"
        options.subseconds = "25"
        options.utcOffset = "+02:00"
        options.orientation = 6
        let bytes = try #require(SyntheticMedia.jpeg(options))
        let metadata = try #require(try read(bytes))

        #expect(metadata.pixelWidth == 320)
        #expect(metadata.pixelHeight == 200)
        #expect(metadata.orientation == 6)
        #expect(metadata.durationSeconds == nil)
        let date = try #require(metadata.captureDate)
        #expect(date.wallClockMilliseconds == 1_718_459_130_250)
        #expect(date.utcOffsetMinutes == 120)
    }

    @Test("A photo with no date has no capture date, rather than a made-up one")
    func noDate() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 100
        let bytes = try #require(SyntheticMedia.png(options))
        let metadata = try #require(try read(bytes, extension: "png"))
        #expect(metadata.pixelWidth == 100)
        #expect(metadata.captureDate == nil)
    }

    @Test("Reads HEIC", .enabled(if: hasHEICEncoder))
    func heic() throws {
        var options = SyntheticMedia.ImageOptions()
        options.width = 128
        options.height = 96
        options.captureDate = "2023:01:02 03:04:05"
        let bytes = try #require(SyntheticMedia.heic(options))
        let metadata = try #require(try read(bytes, extension: "heic"))
        #expect(metadata.pixelWidth == 128)
        #expect(metadata.pixelHeight == 96)
        #expect(metadata.captureDate != nil)
    }

    @Test("A JPEG needs only one prefix read, however large it is")
    func jpegReadsPrefixOnly() throws {
        var options = SyntheticMedia.ImageOptions()
        options.captureDate = "2024:01:01 00:00:00"
        var data = try #require(SyntheticMedia.jpeg(options))
        data.append(Data(count: 20 << 20))
        let source = CountingSource(data)

        let metadata = try reader.metadata(kind: .photo, fileExtension: "jpg", from: source)

        #expect(metadata?.captureDate != nil)
        #expect(source.reads.count == 1)
        #expect(source.bytesRead == ImageMetadataReader.prefixLength)
    }

    @Test("HEIC goes straight to a full read, because a partial one fails", .enabled(if: hasHEICEncoder))
    func heicReadsWholeFile() throws {
        let data = try #require(SyntheticMedia.heic())
        let source = CountingSource(data)
        _ = try reader.metadata(kind: .photo, fileExtension: "heic", from: source)
        #expect(source.reads.count == 1)
        #expect(source.bytesRead == data.count)
    }

    @Test("Metadata past the first prefix is found by the longer read")
    func longerPrefixFallback() throws {
        var options = SyntheticMedia.ImageOptions()
        options.captureDate = "2024:01:01 00:00:00"
        let jpeg = try #require(SyntheticMedia.jpeg(options))
        // A valid JPEG whose image data starts after 300 KB of comment segments.
        var padded = Data(jpeg.prefix(2))
        let block = Data([0xFF, 0xFE, 0xFF, 0xFF]) + Data(count: 0xFFFD)
        for _ in 0..<5 { padded.append(block) }
        padded.append(jpeg.dropFirst(2))
        padded.append(Data(count: 8 << 20))
        let source = CountingSource(padded)

        let metadata = try reader.metadata(kind: .photo, fileExtension: "jpg", from: source)

        #expect(metadata?.pixelWidth == 64)
        #expect(source.reads.count == 2)
    }

    @Test("A file that isn't an image gives no metadata, and it isn't an error")
    func garbage() throws {
        #expect(try read(Data(repeating: 0x41, count: 1000)) == nil)
        #expect(try read(Data()) == nil)
    }

    @Test("Truncated files never crash", arguments: [1, 2, 3, 10, 50, 100, 200, 500, 1000])
    func truncated(length: Int) throws {
        var options = SyntheticMedia.ImageOptions()
        options.captureDate = "2024:01:01 00:00:00"
        let data = try #require(SyntheticMedia.jpeg(options))
        _ = try read(data.prefix(length))
    }

    @Test("Random bytes after a valid header never crash")
    func corruptedJPEG() throws {
        var generator = SeededGenerator(seed: 7)
        let data = try #require(SyntheticMedia.jpeg())
        for _ in 0..<200 {
            var copy = data
            for _ in 0..<16 {
                copy[Int.random(in: 0..<copy.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try read(copy)
        }
    }

    @Test("A read error comes through, so a removed drive is never mistaken for a bad file")
    func readErrorsPropagate() {
        #expect(throws: FailingSource.DriveGone.self) {
            try reader.metadata(kind: .photo, fileExtension: "jpg", from: FailingSource())
        }
        #expect(throws: FailingSource.DriveGone.self) {
            try reader.metadata(kind: .video, fileExtension: "mp4", from: FailingSource())
        }
    }
}

@Suite("EXIF dates")
struct ExifDateTests {
    @Test func parsesTheStandardForm() {
        let date = ExifDate.parse("2001:09:09 01:46:40", subseconds: nil, offset: nil)
        #expect(date?.wallClockMilliseconds == 1_000_000_000_000)
        #expect(date?.utcOffsetMinutes == nil)
    }

    @Test("Also takes dashes, which some software writes")
    func acceptsDashes() {
        #expect(ExifDate.parse("2001-09-09 01:46:40", subseconds: nil, offset: nil)?.wallClockMilliseconds == 1_000_000_000_000)
    }

    @Test("Subseconds are a fraction", arguments: [("5", 500), ("25", 250), ("123", 123), ("1234", 123), ("007", 7)])
    func subseconds(input: String, expected: Int64) {
        let date = ExifDate.parse("1970:01:01 00:00:00", subseconds: input, offset: nil)
        #expect(date?.wallClockMilliseconds == expected)
    }

    @Test("Invalid dates give nil", arguments: [
        "0000:00:00 00:00:00", "    :  :     :  :  ", "2024:13:01 00:00:00", "2024:00:10 00:00:00",
        "2024:01:32 00:00:00", "2024:01:01 25:00:00", "2024:01:01", "", "not a date at all!!",
    ])
    func invalid(string: String) {
        #expect(ExifDate.parse(string, subseconds: nil, offset: nil) == nil)
    }

    @Test(arguments: [("+02:00", 120), ("-05:30", -330), ("+00:00", 0), ("+14:00", 840)])
    func offsets(string: String, minutes: Int) {
        #expect(ExifDate.parseOffset(string) == minutes)
    }

    @Test(arguments: ["0200", "+2:00", "+99:00", "Z", "", "+02:99"])
    func badOffsets(string: String) {
        #expect(ExifDate.parseOffset(string) == nil)
    }

    @Test("Days agree with Foundation's calendar across the range cameras use")
    func daysMatchCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for year in stride(from: 1900, through: 2100, by: 7) {
            for (month, day) in [(1, 1), (2, 28), (3, 1), (12, 31)] {
                let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
                #expect(ExifDate.daysFromCivil(year: year, month: month, day: day) == Int(date.timeIntervalSince1970 / 86_400))
            }
        }
        #expect(ExifDate.daysFromCivil(year: 2024, month: 2, day: 29) == 19_782)
    }
}
