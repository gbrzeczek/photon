import Foundation
import Testing

@testable import PhotonCore

@Suite struct RelativePathTests {
    @Test func splitsDirectoryAndName() throws {
        let path = try #require(RelativePath(string: "DCIM/100CANON/IMG_0001.JPG"))
        #expect(path.directory == "DCIM/100CANON")
        #expect(path.name == "IMG_0001.JPG")
        #expect(path.string == "DCIM/100CANON/IMG_0001.JPG")
        #expect(path.fileExtension == "JPG")
    }

    @Test func handlesFilesAtTheRoot() throws {
        let path = try #require(RelativePath(string: "photo.jpg"))
        #expect(path.directory == "")
        #expect(path.string == "photo.jpg")
    }

    @Test("Absolute paths and paths that climb out are never accepted", arguments: [
        "", "/Volumes/T7/a.jpg", "a/../../b.jpg", "../a.jpg", "a//b.jpg", "a/", "./a.jpg",
    ])
    func rejects(_ string: String) {
        #expect(RelativePath(string: string) == nil)
    }

    @Test func findsExtensions() {
        #expect(RelativePath(directory: "", name: "a.tar.gz").fileExtension == "gz")
        #expect(RelativePath(directory: "", name: "noextension").fileExtension == "")
        #expect(RelativePath(directory: "", name: ".hidden").fileExtension == "")
    }
}

@Suite struct MediaKindTests {
    @Test func recognizesCameraFilesInAnyCase() {
        #expect(MediaKind(fileExtension: "JPG") == .photo)
        #expect(MediaKind(fileExtension: "heic") == .photo)
        #expect(MediaKind(fileExtension: "CR3") == .photo)
        #expect(MediaKind(fileExtension: "MP4") == .video)
        #expect(MediaKind(fileExtension: "mkv") == .video)
    }

    @Test func ignoresEverythingElse() {
        #expect(MediaKind(fileExtension: "txt") == nil)
        #expect(MediaKind(fileExtension: "") == nil)
        #expect(MediaKind(fileExtension: "ts") == nil)
        #expect(MediaKind(fileExtension: "lrv") == nil)
        #expect(MediaKind(fileExtension: "thm") == nil)
    }
}

@Suite struct ContentHashTests {
    @Test func requiresThirtyTwoBytes() {
        #expect(ContentHash(bytes: Data(count: 31)) == nil)
        #expect(ContentHash(bytes: Data(count: 33)) == nil)
        #expect(ContentHash(bytes: Data(count: 32)) != nil)
    }

    @Test func printsHex() {
        #expect(ContentHash(bytes: Data(repeating: 0xAB, count: 32))?.hex == String(repeating: "ab", count: 32))
    }
}

@Suite struct SamePictureTests {
    let base = MediaMetadata(
        pixelWidth: 4000, pixelHeight: 3000, captureDate: CaptureDate(wallClockMilliseconds: 5))

    @Test func matchesSameDateAndDimensions() {
        #expect(base.isSamePicture(as: base))
    }

    @Test func allowsWidthAndHeightToSwap() {
        var rotated = base
        rotated.pixelWidth = 3000
        rotated.pixelHeight = 4000
        #expect(base.isSamePicture(as: rotated))
    }

    @Test func rejectsDifferentDimensions() {
        var other = base
        other.pixelWidth = 2000
        #expect(!base.isSamePicture(as: other))
    }

    @Test func rejectsDifferentDates() {
        var other = base
        other.captureDate = CaptureDate(wallClockMilliseconds: 6)
        #expect(!base.isSamePicture(as: other))
    }

    @Test("Missing data never counts as a match")
    func rejectsMissingData() {
        var noDate = base
        noDate.captureDate = nil
        #expect(!noDate.isSamePicture(as: noDate))
        var noSize = base
        noSize.pixelWidth = nil
        #expect(!noSize.isSamePicture(as: noSize))
    }

    @Test func aTimeZoneChangeDoesNotBreakTheMatch() {
        var other = base
        other.captureDate?.utcOffsetMinutes = 120
        #expect(base.isSamePicture(as: other))
    }
}
