import Foundation
import Testing

@testable import PhotonCore

@Suite("Favorites, albums, tags, smart albums, search and stacks")
struct OrganizationTests {
    private func names(_ result: BrowseResult, _ library: TestLibrary) async throws -> [String] {
        try await library.store.browseRows(instances: result.instanceIDs).map(\.path.name).sorted()
    }

    private func browse(
        _ library: TestLibrary, _ source: BrowseSource, search: String = "", expands: Bool = false
    ) async throws -> [String] {
        let result = try await library.store.browse(
            source, sort: BrowseSort(key: .name, ascending: true),
            options: BrowseOptions(search: search, expandsStacks: expands))
        return try await names(result, library)
    }

    private static func utc(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return Int64(calendar.date(from: DateComponents(year: year, month: month, day: day))!.timeIntervalSince1970 * 1000)
    }

    /// Files of any kind in one directory, indexed with distinct hashes from `firstHash`.
    @discardableResult
    private func addFiles(
        _ library: TestLibrary, _ files: [(String, MediaKind, Double?)], directory: String = "DCIM",
        firstHash: UInt8 = 1, captured: Int64? = nil, volume: VolumeID? = nil
    ) async throws -> [AssetID] {
        let volume = volume ?? library.volume
        let scanned = files.map {
            ScannedFile(name: $0.0, kind: $0.1, size: 100, modifiedTime: FileTimestamp(nanoseconds: 1000))
        }
        _ = try await library.store.applyDirectory(volume: volume, directory: directory, files: scanned)
        var assets: [AssetID] = []
        for (offset, file) in files.enumerated() {
            let instance = try #require(
                try await library.store.instance(volume: volume, path: RelativePath(directory: directory, name: file.0)))
            try await library.index(
                instance, hash: TestLibrary.hash(firstHash + UInt8(offset)),
                metadata: MediaMetadata(
                    pixelWidth: 4, pixelHeight: 3,
                    captureDate: captured.map { CaptureDate(wallClockMilliseconds: $0) }, durationSeconds: file.2))
            assets.append(try await library.reload(instance).assetID)
        }
        return assets
    }

    // MARK: Favorites

    @Test("Period's toggle makes all favorites if any isn't, and none if all are")
    func favoriteToggle() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil), ("b.jpg", .photo, nil)])
        try await library.store.setFavorite([assets[0]], true)
        #expect(try await library.store.toggleFavorite(assets) == true)
        #expect(try await browse(library, .favorites) == ["a.jpg", "b.jpg"])
        #expect(try await library.store.toggleFavorite(assets) == false)
        #expect(try await browse(library, .favorites).isEmpty)
    }

    @Test("A favorite's row is flagged, so its tile can show a heart")
    func favoriteFlag() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil), ("b.jpg", .photo, nil)])
        try await library.store.setFavorite([assets[1]], true)
        let result = try await library.store.browse(.allItems, sort: BrowseSort(key: .name, ascending: true))
        #expect(result.flags.map { $0.contains(.favorite) } == [false, true])
    }

    @Test("A source across volumes shows one row per asset, preferring an online volume's file")
    func prefersOnlineVolume() async throws {
        let library = try await TestLibrary()
        let other = try await library.store.insertVolume(uuid: "VOLUME-B", name: "B", capacity: 1, filesystem: "exfat").id
        try await addFiles(library, [("a.jpg", .photo, nil)])
        try await addFiles(library, [("moved.jpg", .photo, nil)], directory: "Elsewhere", volume: other)
        #expect(try await library.store.assetCount() == 1)
        for (preferred, expected) in [(library.volume, "a.jpg"), (other, "moved.jpg")] {
            let result = try await library.store.browse(
                .allItems, sort: .default, options: BrowseOptions(preferredVolumes: [preferred]))
            #expect(try await names(result, library) == [expected])
        }
    }

    // MARK: Albums

    @Test("Albums hold assets, keep order of adding, and removing one touches nothing else")
    func manualAlbums() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil), ("b.jpg", .photo, nil), ("c.jpg", .photo, nil)])
        let album = try await library.store.createAlbum(name: "Trip")
        try await library.store.addAssets([assets[2], assets[0]], to: album)
        try await library.store.addAssets([assets[0]], to: album)
        #expect(try await browse(library, .album(album)) == ["a.jpg", "c.jpg"])
        try await library.store.removeAssets([assets[2]], from: album)
        #expect(try await browse(library, .album(album)) == ["a.jpg"])
        #expect(try await library.store.albums().map(\.name) == ["Trip"])
        try await library.store.deleteAlbum(album)
        #expect(try await library.store.albums().isEmpty)
        #expect(try await library.store.assetCount() == 3)
    }

    @Test("A smart album can't have assets added by hand")
    func smartAlbumsAreQueries() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil)])
        let smart = try await library.store.createAlbum(name: "Favs", query: SmartQuery(rules: [.favorite(true)]))
        await #expect(throws: LibraryError.notFound) { try await library.store.addAssets(assets, to: smart) }
    }

    // MARK: Tags

    @Test("Tags are unique ignoring case, and renaming onto another tag's name fails")
    func tags() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil), ("b.jpg", .photo, nil)])
        let beach = try await library.store.addTag(named: "Beach", to: [assets[0]])
        #expect(try await library.store.addTag(named: " beach ", to: [assets[1]]) == beach)
        #expect(try await library.store.tags().map(\.name) == ["Beach"])
        #expect(try await browse(library, .tag(beach)) == ["a.jpg", "b.jpg"])
        #expect(try await library.store.tagCounts(of: assets) == [beach: 2])
        try await library.store.removeTag(beach, from: [assets[0]])
        #expect(try await browse(library, .tag(beach)) == ["b.jpg"])

        let sea = try await library.store.addTag(named: "Sea", to: [])
        await #expect(throws: LibraryError.nameTaken) { try await library.store.renameTag(sea, to: "BEACH") }
        await #expect(throws: LibraryError.invalidName) { try await library.store.addTag(named: "  ", to: assets) }
        try await library.store.renameTag(beach, to: "Shore")
        #expect(try await library.store.tags().map(\.name) == ["Sea", "Shore"])
        try await library.store.deleteTag(sea)
        #expect(try await library.store.tags().map(\.name) == ["Shore"])
    }

    // MARK: Smart albums

    @Test("Smart album rules match all or any")
    func smartRules() async throws {
        let library = try await TestLibrary()
        let photos = try await addFiles(
            library, [("beach.jpg", .photo, nil), ("clip.mov", .video, 12), ("short.mp4", .video, 2)],
            captured: Self.utc(2023, 7, 1))
        let old = try await addFiles(library, [("old.png", .photo, nil)], directory: "Archive/2001", firstHash: 50,
            captured: Self.utc(2001, 3, 5))
        try await library.store.setFavorite([photos[0], old[0]], true)
        let tag = try await library.store.addTag(named: "Summer", to: [photos[0], photos[1]])
        let album = try await library.store.createAlbum(name: "Best")
        try await library.store.addAssets([photos[1]], to: album)

        func check(_ query: SmartQuery, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation)
            async throws
        {
            let smart = try await library.store.createAlbum(name: "Smart", query: query)
            #expect(try await browse(library, .album(smart)) == expected, sourceLocation: sourceLocation)
            try await library.store.deleteAlbum(smart)
        }
        try await check(SmartQuery(rules: [.favorite(true)]), ["beach.jpg", "old.png"])
        try await check(SmartQuery(rules: [.favorite(true), .kind(.photo), .capturedInYear(2023)]), ["beach.jpg"])
        try await check(SmartQuery(match: .any, rules: [.capturedInYear(2001), .durationLonger(seconds: 10)]),
            ["clip.mov", "old.png"])
        try await check(SmartQuery(rules: [.durationShorter(seconds: 10)]), ["short.mp4"])
        try await check(SmartQuery(rules: [.tag(tag, matches: true)]), ["beach.jpg", "clip.mov"])
        try await check(SmartQuery(rules: [.tag(tag, matches: false)]), ["old.png", "short.mp4"])
        try await check(SmartQuery(rules: [.album(album, contains: true)]), ["clip.mov"])
        try await check(SmartQuery(rules: [.name("EACH", contains: true)]), ["beach.jpg"])
        try await check(SmartQuery(rules: [.folder("archive", contains: false)]), ["beach.jpg", "clip.mov", "short.mp4"])
        try await check(SmartQuery(rules: [.fileType(".PNG")]), ["old.png"])
        let before = Date(timeIntervalSince1970: Double(Self.utc(2010, 1, 1)) / 1000)
        try await check(SmartQuery(rules: [.capturedBefore(before)]), ["old.png"])
        try await check(SmartQuery(rules: [.capturedAfter(before)]), ["beach.jpg", "clip.mov", "short.mp4"])
        try await check(SmartQuery(rules: []), ["beach.jpg", "clip.mov", "old.png", "short.mp4"])
    }

    @Test("In the last N days counts from now, in wall-clock time")
    func capturedWithin() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let filter = AssetFilter.rule(.capturedWithin(days: 1), now: now, timeZone: TimeZone(secondsFromGMT: 3600)!)
        #expect(filter.sql == "a.capture_date_ms >= ?")
        #expect(filter.arguments == [Int64((1_000_000 + 3600 - 86_400) * 1000).databaseValue])
    }

    @Test("A smart query round-trips through JSON, and an unknown rule makes it unreadable, not wrong")
    func smartQueryCoding() async throws {
        let query = SmartQuery(
            match: .any,
            rules: [
                .favorite(false), .kind(.video), .tag(TagID(rawValue: 3), matches: false),
                .album(AlbumID(rawValue: 4), contains: true), .name("a", contains: false), .folder("b", contains: true),
                .fileType("dng"), .capturedWithin(days: 30), .capturedBefore(Date(timeIntervalSince1970: 10)),
                .capturedAfter(Date(timeIntervalSince1970: 20)), .capturedInYear(1999),
                .durationLonger(seconds: 1.5), .durationShorter(seconds: 3),
            ])
        #expect(SmartQuery.decode(query.encoded()) == query)
        #expect(SmartQuery.decode(#"{"match":"all","rules":[{"field":"faces","value":1}]}"#) == nil)

        let library = try await TestLibrary()
        try await addFiles(library, [("a.jpg", .photo, nil)])
        let album = try await library.store.createAlbum(name: "From the future", query: query)
        try await library.store.pool.write { db in
            try db.execute(
                sql: "UPDATE albums SET smart_query = ? WHERE id = ?",
                arguments: [#"{"match":"all","rules":[{"field":"faces","value":1}]}"#, album.rawValue])
        }
        let stored = try #require(try await library.store.album(album))
        #expect(stored.isSmart && !stored.isReadable)
        #expect(try await browse(library, .album(album)).isEmpty)
    }

    // MARK: Search

    @Test("Search words must all match a name, folder, tag, album, kind, year or month")
    func search() async throws {
        let library = try await TestLibrary()
        let summer = try await addFiles(
            library, [("IMG_1.jpg", .photo, nil), ("IMG_2.mov", .video, 5)], directory: "Holidays/Greece",
            captured: Self.utc(2024, 8, 3))
        let winter = try await addFiles(
            library, [("snow.jpg", .photo, nil)], directory: "Winter", firstHash: 40, captured: Self.utc(2019, 1, 9))
        try await library.store.addTag(named: "Family", to: [summer[0]])
        let album = try await library.store.createAlbum(name: "Ski Trip")
        try await library.store.addAssets(winter, to: album)

        #expect(try await browse(library, .allItems, search: "greece") == ["IMG_1.jpg", "IMG_2.mov"])
        #expect(try await browse(library, .allItems, search: "img_2") == ["IMG_2.mov"])
        #expect(try await browse(library, .allItems, search: "fam") == ["IMG_1.jpg"])
        #expect(try await browse(library, .allItems, search: "ski") == ["snow.jpg"])
        #expect(try await browse(library, .allItems, search: "video") == ["IMG_2.mov"])
        #expect(try await browse(library, .allItems, search: "photos 2024") == ["IMG_1.jpg"])
        #expect(try await browse(library, .allItems, search: "January") == ["snow.jpg"])
        #expect(try await browse(library, .allItems, search: "aug greece") == ["IMG_1.jpg", "IMG_2.mov"])
        #expect(try await browse(library, .allItems, search: "100%").isEmpty)
        #expect(try await browse(library, .allItems, search: "  ").count == 3)
        // Search filters what's showing, not the whole library.
        let winterFolder = BrowseSource.folder(BrowseScope(volume: library.volume, path: "Winter"))
        #expect(try await browse(library, winterFolder, search: "img").isEmpty)
    }

    @Test("Search words are parsed into kinds, years and months")
    func searchParsing() {
        let query = SearchQuery("Photos 2024 march mar x", monthNames: [["January", "February", "March"], ["Jan", "Feb", "Mar"]])
        #expect(
            query.terms == [
                .kind(.photo, text: "Photos"), .year(2024, text: "2024"), .month(3, text: "march"),
                .month(3, text: "mar"), .text("x"),
            ])
    }

    // MARK: Stacks

    @Test("RAW+JPEG and Live Photo pairs become stacks, by name within a folder")
    func pairing() async throws {
        let library = try await TestLibrary()
        try await addFiles(
            library,
            [
                ("IMG_1.JPG", .photo, nil), ("img_1.CR3", .photo, nil),
                ("IMG_2.HEIC", .photo, nil), ("IMG_2.MOV", .video, 2.8),
                ("IMG_3.HEIC", .photo, nil), ("IMG_3.MOV", .video, 30),
                ("IMG_4.dng", .photo, nil),
            ])
        try await addFiles(library, [("IMG_4.jpg", .photo, nil)], directory: "Other", firstHash: 30)
        let report = try await library.store.pairStacks(volume: library.volume)
        #expect(report.added == 2)
        #expect(try await library.store.pairStacks(volume: library.volume) == PairingReport())

        let collapsed = try await library.store.browse(.allItems, sort: BrowseSort(key: .name, ascending: true))
        #expect(
            try await library.store.browseRows(instances: collapsed.instanceIDs).map(\.path.name)
                == ["IMG_1.JPG", "IMG_2.HEIC", "IMG_3.HEIC", "IMG_3.MOV", "IMG_4.dng", "IMG_4.jpg"])
        #expect(collapsed.flags[0].contains(.rawPair))
        #expect(collapsed.flags[1].contains(.livePhoto))
        #expect(!collapsed.flags[2].contains(.livePhoto))
        #expect(try await browse(library, .allItems, expands: true).count == 8)
    }

    @Test("A member shows when its cover isn't in the same result")
    func memberWithoutCover() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil), ("a.nef", .photo, nil)])
        try await library.store.pairStacks(volume: library.volume)
        try await library.store.setFavorite([assets[1]], true)
        #expect(try await browse(library, .favorites) == ["a.nef"])
        #expect(try await browse(library, .allItems) == ["a.jpg"])
        let details = try #require(try await library.store.details(of: assets[1]))
        #expect(details.stackKind == .rawAndJPEG)
        #expect(details.stackMembers.map(\.name) == ["a.jpg", "a.nef"])
        #expect(details.stackMembers.map(\.isCover) == [true, false])
    }

    @Test("A stack whose pair is gone is removed on the next pairing")
    func unpairing() async throws {
        let library = try await TestLibrary()
        try await addFiles(library, [("a.jpg", .photo, nil), ("a.nef", .photo, nil)])
        try await library.store.pairStacks(volume: library.volume)
        _ = try await library.store.applyDirectory(
            volume: library.volume, directory: "DCIM",
            files: [ScannedFile(name: "a.jpg", kind: .photo, size: 100, modifiedTime: FileTimestamp(nanoseconds: 1000))])
        let report = try await library.store.pairStacks(volume: library.volume)
        #expect(report.removed == 1 && report.added == 0)
        #expect(try await browse(library, .allItems) == ["a.jpg"])
    }

    // MARK: Inspector and sessions

    @Test("Details list every file, tag, album and stack, from the library alone")
    func details() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil)])
        try await addFiles(library, [("copy.jpg", .photo, nil)], directory: "Backup")
        try await library.store.addTag(named: "Zed", to: assets)
        try await library.store.addTag(named: "alpha", to: assets)
        let album = try await library.store.createAlbum(name: "Album")
        try await library.store.addAssets(assets, to: album)
        _ = try await library.store.createAlbum(name: "Smart", query: SmartQuery(rules: []))
        let details = try #require(try await library.store.details(of: assets[0]))
        #expect(details.locations.map(\.path.string) == ["Backup/copy.jpg", "DCIM/a.jpg"])
        #expect(details.locations.allSatisfy { $0.volumeName == "A" })
        #expect(details.tags.map(\.name) == ["alpha", "Zed"])
        #expect(details.albums.map(\.name) == ["Album"])
        #expect(details.stackKind == nil)
    }

    @Test("Sessions are saved for every source, and the latest one reopens")
    func sessions() async throws {
        let library = try await TestLibrary()
        let assets = try await addFiles(library, [("a.jpg", .photo, nil)])
        let album = try await library.store.createAlbum(name: "A")
        let tag = try await library.store.addTag(named: "T", to: assets)
        let sources: [BrowseSource] = [
            .folder(BrowseScope(volume: library.volume, path: "DCIM")), .allItems, .favorites, .album(album), .tag(tag),
        ]
        for (offset, source) in sources.enumerated() {
            let session = BrowseSession(
                source: source, sort: .default, viewMode: offset % 2, tileSize: Double(100 + offset), anchor: assets[0])
            try await library.store.saveSession(session, now: Date(timeIntervalSince1970: Double(offset)))
            try await library.store.saveSession(session, now: Date(timeIntervalSince1970: Double(offset)))
            #expect(try await library.store.session(for: source) == session)
            #expect(try await library.store.latestSession()?.source == source)
        }
        try await library.store.deleteTag(tag)
        #expect(try await library.store.session(for: .tag(tag)) == nil)
        #expect(try await library.store.latestSession()?.source == .album(album))
        // Saving against a deleted album does nothing, rather than failing.
        try await library.store.deleteAlbum(album)
        try await library.store.saveSession(
            BrowseSession(source: .album(album), sort: .default, viewMode: 0, tileSize: nil, anchor: nil))
        #expect(try await library.store.session(for: .album(album)) == nil)
    }

    @Test("Merging a provisional asset keeps tags and albums from both sides")
    func mergeKeepsOrganization() async throws {
        let library = try await TestLibrary()
        let original = try await addFiles(library, [("a.jpg", .photo, nil)])
        let album = try await library.store.createAlbum(name: "Kept")
        try await library.store.addAssets(original, to: album)
        // A copy, tagged while it was still provisional, then hashed to the same content.
        let copy = try await library.add("copy.jpg", directory: "Elsewhere")
        try await library.store.addTag(named: "Early", to: [copy.assetID])
        try await library.store.setFavorite([copy.assetID], true)
        try await library.index(copy, hash: TestLibrary.hash(1))
        #expect(try await library.store.assetCount() == 1)
        let details = try #require(try await library.store.details(of: original[0]))
        #expect(details.asset.isFavorite)
        #expect(details.tags.map(\.name) == ["Early"])
        #expect(details.albums.map(\.name) == ["Kept"])
    }
}
