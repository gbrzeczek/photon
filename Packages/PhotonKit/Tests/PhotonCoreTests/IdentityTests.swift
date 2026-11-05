import Foundation
import Testing

@testable import PhotonCore

@Suite("Identity rules from docs/PLAN.md")
struct IdentityTests {
    @Test("A new file gets a provisional asset with no hash")
    func provisionalAsset() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        let asset = try await library.asset(instance)
        #expect(asset.contentHash == nil)
        #expect(instance.indexState == .pending)
    }

    @Test("The first hash goes onto the provisional asset")
    func firstHash() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        let counts = try await library.index(instance, hash: TestLibrary.hash(1), metadata: photoA)
        #expect(counts.hashed == 1)
        let asset = try await library.asset(instance)
        #expect(asset.id == instance.assetID)
        #expect(asset.contentHash == TestLibrary.hash(1))
        #expect(asset.metadata == photoA)
        #expect(try await library.reload(instance).indexState == .complete)
    }

    @Test("An exact duplicate is two instances of one asset")
    func duplicatesShareAnAsset() async throws {
        let library = try await TestLibrary()
        let first = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        let copy = try await library.add("copy.jpg")
        let counts = try await library.index(copy, hash: TestLibrary.hash(1), metadata: photoA)

        #expect(counts.merged == 1)
        let merged = try await library.reload(copy)
        #expect(merged.assetID == first.assetID)
        #expect(try await library.store.instances(of: first.assetID).count == 2)
        #expect(try await library.store.assetCount() == 1)
    }

    @Test("Merging keeps organization data from both sides, in one step")
    func mergeKeepsOrganizationData() async throws {
        let library = try await TestLibrary()
        let existing = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1))
        try await library.tag(existing.assetID, tagID: 1)
        try await library.addToAlbum(existing.assetID, albumID: 1)

        // Favoriting or tagging a provisional asset is allowed, so its data has to survive the merge.
        let provisional = try await library.add("b.jpg")
        try await library.favorite(provisional.assetID)
        try await library.rotate(provisional.assetID, 2)
        try await library.tag(provisional.assetID, tagID: 2)
        try await library.tag(provisional.assetID, tagID: 1)
        try await library.addToAlbum(provisional.assetID, albumID: 2)
        try await library.addToAlbum(provisional.assetID, albumID: 1)
        try await library.execute(
            "INSERT INTO sessions (volume_id, relative_path, sort_key, anchor_asset_id, updated_at) VALUES (?, 'DCIM', 'name', ?, 0)",
            [library.volume.rawValue, provisional.assetID.rawValue])
        try await library.execute("INSERT INTO stacks (id, kind, cover_asset_id, created_at) VALUES (1, 1, ?, 0)", [provisional.assetID.rawValue])
        try await library.execute("INSERT INTO stack_members (stack_id, asset_id) VALUES (1, ?)", [provisional.assetID.rawValue])

        try await library.index(provisional, hash: TestLibrary.hash(1))

        let merged = try await library.asset(existing)
        #expect(merged.isFavorite)
        #expect(merged.rotation == 2)
        #expect(try await library.count("SELECT count(*) FROM asset_tags WHERE asset_id = \(merged.id.rawValue)") == 2)
        #expect(try await library.count("SELECT count(*) FROM album_assets WHERE asset_id = \(merged.id.rawValue)") == 2)
        #expect(try await library.count("SELECT count(*) FROM sessions WHERE anchor_asset_id = \(merged.id.rawValue)") == 1)
        #expect(try await library.count("SELECT count(*) FROM stacks WHERE cover_asset_id = \(merged.id.rawValue)") == 1)
        #expect(try await library.count("SELECT count(*) FROM stack_members WHERE asset_id = \(merged.id.rawValue)") == 1)
        #expect(try await library.store.asset(provisional.assetID) == nil)
    }

    @Test("A rotation on the existing asset wins in a merge")
    func mergeKeepsTargetRotation() async throws {
        let library = try await TestLibrary()
        let existing = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1))
        try await library.rotate(existing.assetID, 1)
        let provisional = try await library.add("b.jpg")
        try await library.rotate(provisional.assetID, 3)
        try await library.index(provisional, hash: TestLibrary.hash(1))
        #expect(try await library.asset(existing).rotation == 1)
    }

    @Test("Metadata from a merge only fills what's missing or newer")
    func mergeFillsMetadata() async throws {
        let library = try await TestLibrary()
        let existing = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: MediaMetadata(pixelWidth: 10))
        let copy = try await library.add("b.jpg")
        try await library.index(copy, hash: TestLibrary.hash(1), metadata: MediaMetadata(pixelHeight: 20))
        let asset = try await library.asset(existing)
        #expect(asset.metadata.pixelWidth == 10)
        #expect(asset.metadata.pixelHeight == 20)
    }

    @Test("A file edited in place stays the same asset and takes the new hash")
    func editedFileKeepsAsset() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        try await library.favorite(original.assetID)

        let changed = try await library.add("a.jpg", size: 200, modified: 2000)
        #expect(changed.indexState == .pending)
        let counts = try await library.index(changed, hash: TestLibrary.hash(2), metadata: photoA)

        #expect(counts.rehashed == 1)
        let asset = try await library.asset(changed)
        #expect(asset.id == original.assetID)
        #expect(asset.contentHash == TestLibrary.hash(2))
        #expect(asset.isFavorite)
    }

    @Test("Rotating a file on disk swaps width and height, and it's still the same asset")
    func rotatedFileKeepsAsset() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        var rotated = photoA
        rotated.pixelWidth = photoA.pixelHeight
        rotated.pixelHeight = photoA.pixelWidth

        let changed = try await library.add("a.jpg", size: 200)
        try await library.index(changed, hash: TestLibrary.hash(2), metadata: rotated)
        #expect(try await library.asset(changed).id == original.assetID)
        #expect(try await library.asset(changed).metadata.pixelWidth == 3000)
    }

    @Test("Different content at the same path is a different asset, and the favorite stays with the old one")
    func replacedFileGetsNewAsset() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        try await library.favorite(original.assetID)

        var other = photoA
        other.captureDate = CaptureDate(wallClockMilliseconds: 9)
        let changed = try await library.add("a.jpg", size: 200)
        let counts = try await library.index(changed, hash: TestLibrary.hash(2), metadata: other)

        #expect(counts.reassigned == 1)
        let replacement = try await library.asset(changed)
        #expect(replacement.id != original.assetID)
        #expect(!replacement.isFavorite)
        #expect(try await library.store.asset(hash: TestLibrary.hash(1))?.isFavorite == true)
    }

    @Test("Without a capture date a changed file can't prove it's the same picture")
    func missingDateGetsNewAsset() async throws {
        let library = try await TestLibrary()
        let noDate = MediaMetadata(pixelWidth: 100, pixelHeight: 100)
        let original = try await library.addIndexed("a.png", hash: TestLibrary.hash(1), metadata: noDate)
        let changed = try await library.add("a.png", size: 200)
        try await library.index(changed, hash: TestLibrary.hash(2), metadata: noDate)
        #expect(try await library.asset(changed).id != original.assetID)
    }

    @Test("An unreferenced old asset is cleaned up when its content is replaced")
    func replacedAssetIsDeletedWhenUnreferenced() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        let changed = try await library.add("a.jpg", size: 200)
        try await library.index(changed, hash: TestLibrary.hash(2), metadata: nil)
        #expect(try await library.store.asset(original.assetID) == nil)
        #expect(try await library.store.assetCount() == 1)
    }

    @Test("Editing one of two copies leaves the other copy's asset alone, and the edit keeps the organization data")
    func editingOneCopyForksTheAsset() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        let copy = try await library.addIndexed("b.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        #expect(copy.assetID == original.assetID)
        try await library.favorite(original.assetID)
        try await library.tag(original.assetID)

        let edited = try await library.add("b.jpg", size: 200)
        let counts = try await library.index(edited, hash: TestLibrary.hash(2), metadata: photoA)

        #expect(counts.rehashed == 1)
        let fork = try await library.asset(edited)
        let untouched = try await library.asset(original)
        #expect(fork.id != untouched.id)
        #expect(untouched.contentHash == TestLibrary.hash(1))
        #expect(fork.contentHash == TestLibrary.hash(2))
        #expect(fork.isFavorite && untouched.isFavorite)
        #expect(try await library.count("SELECT count(*) FROM asset_tags") == 2)
    }

    @Test("A file edited into a copy of another asset merges into it, when it's the same picture")
    func editIntoExistingContentMerges() async throws {
        let library = try await TestLibrary()
        let target = try await library.addIndexed("target.jpg", hash: TestLibrary.hash(2), metadata: photoA)
        let source = try await library.addIndexed("source.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        try await library.favorite(source.assetID)

        let changed = try await library.add("source.jpg", size: 200)
        try await library.index(changed, hash: TestLibrary.hash(2), metadata: photoA)

        #expect(try await library.asset(changed).id == target.assetID)
        #expect(try await library.asset(target).isFavorite)
        #expect(try await library.store.asset(source.assetID) == nil)
    }

    @Test("A file replaced by a different picture's content moves to that asset, and the favorite doesn't follow")
    func replacementWithExistingContentMoves() async throws {
        let library = try await TestLibrary()
        var other = photoA
        other.captureDate = CaptureDate(wallClockMilliseconds: 9)
        let target = try await library.addIndexed("target.jpg", hash: TestLibrary.hash(2), metadata: other)
        let source = try await library.addIndexed("source.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        try await library.favorite(source.assetID)

        let changed = try await library.add("source.jpg", size: 200)
        try await library.index(changed, hash: TestLibrary.hash(2), metadata: other)

        #expect(try await library.asset(changed).id == target.assetID)
        #expect(try await library.asset(target).isFavorite == false)
        #expect(try await library.store.asset(hash: TestLibrary.hash(1))?.isFavorite == true)
    }

    @Test("A result for a file that has since changed is dropped")
    func staleResultIsDropped() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        try await library.add("a.jpg", size: 999)

        let counts = try await library.index(instance, hash: TestLibrary.hash(1))

        #expect(counts.stale == 1)
        let current = try await library.reload(instance)
        #expect(current.indexState == .pending)
        #expect(try await library.asset(current).contentHash == nil)
    }

    @Test("A result for a deleted file is dropped")
    func resultForDeletedFile() async throws {
        let library = try await TestLibrary()
        let instance = try await library.add("a.jpg")
        _ = try await library.store.applyDirectory(volume: library.volume, directory: "DCIM", files: [])
        let counts = try await library.index(instance, hash: TestLibrary.hash(1))
        #expect(counts.stale == 1)
    }

    @Test("Touching a file without changing its content keeps everything")
    func touchedFile() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        let touched = try await library.add("a.jpg", modified: 5000)
        let counts = try await library.index(touched, hash: TestLibrary.hash(1), metadata: photoA)
        #expect(counts == IdentityCounts())
        #expect(try await library.asset(touched).id == original.assetID)
        #expect(try await library.reload(touched).indexState == .complete)
    }

    @Test("A batch can hold several files with the same new content")
    func duplicatesInOneBatch() async throws {
        let library = try await TestLibrary()
        let first = try await library.add("a.jpg")
        let second = try await library.add("b.jpg")
        let third = try await library.add("c.jpg")
        let counts = try await library.store.applyIndexed(
            [first, second, third].map {
                IndexedFile(instanceID: $0.id, size: $0.size, modifiedTime: $0.modifiedTime, hash: TestLibrary.hash(7), metadata: nil)
            })
        #expect(counts.hashed == 1)
        #expect(counts.merged == 2)
        #expect(try await library.store.assetCount() == 1)
    }
}

@Suite("Organization data survives files coming and going")
struct OrphanTests {
    @Test("Removing a favorite's last file keeps the asset")
    func favoriteOutlivesItsFile() async throws {
        let library = try await TestLibrary()
        let instance = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1))
        try await library.favorite(instance.assetID)
        _ = try await library.store.applyDirectory(volume: library.volume, directory: "DCIM", files: [])
        #expect(try await library.store.asset(instance.assetID)?.isFavorite == true)
        #expect(try await library.store.instances(of: instance.assetID).isEmpty)
    }

    @Test("Removing a file with no organization data removes its asset")
    func plainAssetGoesWithItsFile() async throws {
        let library = try await TestLibrary()
        let instance = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1))
        _ = try await library.store.applyDirectory(volume: library.volume, directory: "DCIM", files: [])
        #expect(try await library.store.asset(instance.assetID) == nil)
    }

    @Test("Removing one copy keeps the asset for the other")
    func assetStaysWhileACopyRemains() async throws {
        let library = try await TestLibrary()
        let first = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1))
        _ = try await library.addIndexed("b.jpg", directory: "Other", hash: TestLibrary.hash(1))
        _ = try await library.store.applyDirectory(volume: library.volume, directory: "DCIM", files: [])
        #expect(try await library.store.asset(first.assetID) != nil)
    }

    @Test(arguments: ["album", "tag", "rotation", "stack", "session"])
    func anyOrganizationDataKeepsAnAsset(kind: String) async throws {
        let library = try await TestLibrary()
        let instance = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1))
        let id = instance.assetID.rawValue
        switch kind {
        case "album": try await library.addToAlbum(instance.assetID)
        case "tag": try await library.tag(instance.assetID)
        case "rotation": try await library.rotate(instance.assetID, 1)
        case "stack":
            try await library.execute("INSERT INTO stacks (id, kind, created_at) VALUES (1, 1, 0)")
            try await library.execute("INSERT INTO stack_members (stack_id, asset_id) VALUES (1, ?)", [id])
        default:
            try await library.execute(
                "INSERT INTO sessions (volume_id, relative_path, sort_key, anchor_asset_id, updated_at) VALUES (?, '', 'name', ?, 0)",
                [library.volume.rawValue, id])
        }
        _ = try await library.store.applyDirectory(volume: library.volume, directory: "DCIM", files: [])
        #expect(try await library.store.asset(instance.assetID) != nil)
    }

    @Test("A moved favorite reattaches when its new location is hashed")
    func movedFavoriteReattaches() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", directory: "Old", hash: TestLibrary.hash(1), metadata: photoA)
        try await library.favorite(original.assetID)

        _ = try await library.store.applyDirectory(volume: library.volume, directory: "Old", files: [])
        let moved = try await library.add("renamed.jpg", directory: "New")
        #expect(moved.assetID != original.assetID)
        try await library.index(moved, hash: TestLibrary.hash(1))

        #expect(try await library.reload(moved).assetID == original.assetID)
        #expect(try await library.asset(moved).isFavorite)
    }

    @Test("Favorites survive moving a library to a new drive")
    func favoriteSurvivesNewDrive() async throws {
        let library = try await TestLibrary()
        let original = try await library.addIndexed("a.jpg", hash: TestLibrary.hash(1), metadata: photoA)
        try await library.favorite(original.assetID)
        try await library.tag(original.assetID)

        let newDrive = try await library.store.insertVolume(uuid: "VOLUME-B", name: "B", capacity: 1, filesystem: "exfat")
        let onNewDrive = try await library.add("a.jpg", directory: "Elsewhere", on: newDrive.id)
        try await library.index(onNewDrive, hash: TestLibrary.hash(1))

        let asset = try await library.asset(onNewDrive)
        #expect(asset.id == original.assetID)
        #expect(asset.isFavorite)
        #expect(try await library.store.instances(of: asset.id).count == 2)
    }
}
