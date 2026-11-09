import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Testing

/// Milestone 5 is done when favorites survive moving a library to a new drive. Both drives are exFAT disk
/// images, never the user's real drive.
@Suite("Moving a library to a new drive", .serialized, .usesDiskImages, .timeLimit(.minutes(10)))
struct DriveMoveTests {
    final class Fixture: Sendable {
        let directory: URL
        let store: LibraryStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "photon-move-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try LibraryStore(url: directory.appending(path: "library/Library.sqlite"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func files(under root: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var found: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                MediaKind(fileExtension: url.pathExtension) != nil
            else { continue }
            found.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return found.sorted()
    }

    /// The content hashes of a source's assets, and the volumes its rows come from.
    private func contents(
        _ source: BrowseSource, store: LibraryStore, online: Set<VolumeID>
    ) async throws -> (hashes: Set<ContentHash>, volumes: Set<VolumeID>) {
        let result = try await store.browse(source, sort: .default, options: BrowseOptions(preferredVolumes: online))
        var hashes = Set<ContentHash>()
        for asset in result.assetIDs {
            if let hash = try await store.asset(AssetID(rawValue: asset))?.contentHash { hashes.insert(hash) }
        }
        let rows = try await store.browseRows(instances: result.instanceIDs)
        return (hashes, Set(rows.map(\.volumeID)))
    }

    @Test("Favorites, tags and albums follow the content to a new drive with another layout")
    func favoritesSurviveAMove() async throws {
        let fixture = try Fixture()
        let store = fixture.store

        // The old drive, indexed and organized.
        let old = try DiskImage.create(in: fixture.directory, name: "old", label: "PHOTONOLD", megabytes: 64)
        defer { old.ensureDetached() }
        var options = SyntheticLibrary.Options()
        options.fileCount = 40
        options.duplicateInterval = 0
        options.filesPerFolder = 10
        let writable = try old.attach()
        _ = try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: writable))
        try old.detach()

        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
        let oldMount = try old.attach(readOnly: true)
        let oldReport = try await indexer.index(path: oldMount)
        let oldVolume = try #require(oldReport.volumeID)
        #expect(oldReport.failed == 0)
        let all = try await store.browse(.allItems, sort: BrowseSort(key: .name, ascending: true))
        #expect(all.count == 40)
        let ids = all.assetIDs.map(AssetID.init(rawValue:))
        let favorites = Array(ids[0..<5])
        try await store.setFavorite(favorites, true)
        let tag = try await store.addTag(named: "Keep", to: Array(ids[3..<8]))
        let album = try await store.createAlbum(name: "Moved")
        try await store.addAssets(Array(ids[10..<14]), to: album)
        let smart = try await store.createAlbum(
            name: "Favorite photos", query: SmartQuery(rules: [.favorite(true), .tag(tag, matches: true)]))

        let before = (
            favorites: try await contents(.favorites, store: store, online: [oldVolume]),
            tag: try await contents(.tag(tag), store: store, online: [oldVolume]),
            album: try await contents(.album(album), store: store, online: [oldVolume]),
            smart: try await contents(.album(smart), store: store, online: [oldVolume]))
        #expect(before.favorites.hashes.count == 5)
        #expect(before.tag.hashes.count == 5)
        #expect(before.album.hashes.count == 4)
        #expect(before.smart.hashes.count == 2)

        // A new drive, with its own UUID, holding the same files in another layout, some renamed.
        let new = try DiskImage.create(in: fixture.directory, name: "new", label: "PHOTONNEW", megabytes: 64)
        defer { new.ensureDetached() }
        let newWritable = URL(fileURLWithPath: try new.attach())
        let oldFiles = try files(under: URL(fileURLWithPath: oldMount))
        #expect(oldFiles.count == 40)
        for (offset, path) in oldFiles.enumerated() {
            let source = URL(fileURLWithPath: oldMount).appending(path: path)
            let name = offset % 3 == 0 ? "renamed-\(offset).\(source.pathExtension)" : source.lastPathComponent
            let folder = newWritable.appending(path: "Archive/\(offset % 4 == 0 ? "Best" : "Rest")/\(offset / 7)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: folder.appending(path: name))
        }
        try new.detach()

        // The old drive goes away, as it would when replaced.
        try old.detach(force: true)
        indexer.volumeDidUnmount(mountPoint: oldMount)

        let newMount = try new.attach(readOnly: true)
        let newReport = try await indexer.index(path: newMount)
        let newVolume = try #require(newReport.volumeID)
        #expect(newVolume != oldVolume)
        #expect(newReport.failed == 0)
        #expect(newReport.identity.merged == 40)
        // No new content, so no new assets.
        #expect(try await store.assetCount() == 40)

        for (source, expected) in [
            (BrowseSource.favorites, before.favorites), (.tag(tag), before.tag), (.album(album), before.album),
            (.album(smart), before.smart),
        ] {
            let moved = try await contents(source, store: store, online: [newVolume])
            #expect(moved.hashes == expected.hashes, "\(source)")
            #expect(moved.volumes == [newVolume], "\(source) should show the new drive's files")
        }
        // The new drive's own folders show the favorites too.
        let folder = try await store.browse(.folder(BrowseScope(volume: newVolume, path: "")), sort: .default)
        #expect(folder.flags.filter { $0.contains(.favorite) }.count == 5)

        // With the old drive back as well, nothing changes, and the online one is still preferred.
        _ = try old.attach(readOnly: true)
        let reconnected = try await indexer.connectKnownVolumes()
        #expect(Set(reconnected.connections.map(\.volume)) == [oldVolume, newVolume])
        #expect(try await store.assetCount() == 40)
        let both = try await contents(.favorites, store: store, online: [newVolume, oldVolume])
        #expect(both.hashes == before.favorites.hashes)
        let details = try #require(try await store.details(of: favorites[0]))
        #expect(Set(details.locations.map(\.volume)) == [oldVolume, newVolume])
        #expect(details.asset.isFavorite)
    }
}
