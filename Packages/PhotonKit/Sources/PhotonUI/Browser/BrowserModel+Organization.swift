import AppKit
import PhotonCore

// Favorites, albums, tags, search, stacks and the inspector. Every change here writes only the library,
// so all of it works the same on offline and read-only volumes. See docs/PLAN.md, under Organization.
extension BrowserModel {
    /// What organization commands act on: the photo in the viewer, or else the selection, or else the
    /// current item, the same as Copy.
    var actionAssets: [AssetID] {
        actionRows.compactMap { $0 < result.count ? AssetID(rawValue: result.assetIDs[$0]) : nil }
    }

    public var hasActionItems: Bool { !actionRows.isEmpty }

    /// Reads what the action items and their state depend on, so a view that reads this updates when
    /// they change. The rows themselves aren't observed, because they change on every move.
    public var actionStateToken: Int {
        _ = (selectedCount, organizationVersion, isLoading, itemCount, viewerCaption, isViewerOpen, inspectedAsset)
        return 0
    }

    /// The manual album showing, which is what Remove from Album acts on.
    public var currentManualAlbum: Album? {
        guard case .album(let id) = source else { return nil }
        return library.albums.first { $0.id == id && !$0.isSmart }
    }

    // MARK: Search and stacks

    /// Filters what's showing. The search field waits for a pause in typing before calling this.
    public func setSearch(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text != search else { return }
        search = text
        reload(keepPosition: true)
    }

    /// Command-F.
    public func focusSearch() { searchFocusRequest += 1 }

    public func setExpandsStacks(_ expands: Bool) {
        guard expands != expandsStacks else { return }
        expandsStacks = expands
        reload(keepPosition: true)
    }

    // MARK: Inspector

    /// Command-I.
    public func toggleInspector() {
        isInspectorShown.toggle()
        if isInspectorShown { inspect(isViewerOpen ? viewerRow.flatMap(asset) : selection.currentAsset, immediately: true) }
    }

    private func asset(_ row: Int) -> AssetID? {
        row < result.count ? AssetID(rawValue: result.assetIDs[row]) : nil
    }

    /// Points the inspector at an asset once the current item has rested, like the status bar, so a
    /// held key reads nothing.
    func inspect(_ asset: AssetID?, immediately: Bool = false) {
        inspectTask?.cancel()
        guard asset != inspectedAsset else { return }
        guard !immediately else {
            inspectedAsset = asset
            return
        }
        inspectTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            inspectedAsset = asset
        }
    }

    // MARK: Favorites

    /// Period: makes them all favorites if any isn't, and otherwise none.
    public func toggleFavorite() {
        let assets = actionAssets
        guard !assets.isEmpty else { return }
        change { try await $0.toggleFavorite(assets) }
    }

    /// Whether everything the favorite command acts on is a favorite already, for the menu's title.
    public var actionItemsAreFavorites: Bool {
        let rows = actionRows
        guard !rows.isEmpty else { return false }
        // Bounded, so a huge selection doesn't walk every row each time the menu opens.
        return rows.prefix(4096).allSatisfy { $0 < result.count && result.flags[$0].contains(.favorite) }
    }

    // MARK: Albums

    public func addToAlbum(_ album: AlbumID) {
        let assets = actionAssets
        guard !assets.isEmpty else { return }
        change { try await $0.addAssets(assets, to: album) }
    }

    /// Makes an album holding what the commands act on, if anything, and shows it.
    public func newAlbum(named name: String, addingItems: Bool) {
        let assets = addingItems ? actionAssets : []
        let library = library
        Task {
            guard let album = try? await library.createAlbum(named: name) else { return }
            if !assets.isEmpty { try? await library.store.addAssets(assets, to: album) }
            organizationDidChange()
            open(.album(album))
        }
    }

    public func newSmartAlbum(named name: String, query: SmartQuery) {
        let library = library
        Task {
            guard let album = try? await library.createAlbum(named: name, query: query) else { return }
            organizationDidChange()
            open(.album(album))
        }
    }

    public func editSmartAlbum(_ album: AlbumID, name: String, query: SmartQuery) {
        change {
            try await $0.renameAlbum(album, to: name)
            try await $0.setSmartQuery(album, query)
        }
    }

    /// Delete, or the menu, in a manual album. Nothing happens to the files.
    public func removeFromAlbum() {
        guard let album = currentManualAlbum else { return }
        let assets = actionAssets
        guard !assets.isEmpty else { return }
        change { try await $0.removeAssets(assets, from: album.id) }
    }

    public func renameAlbum(_ album: AlbumID, to name: String) {
        change { try await $0.renameAlbum(album, to: name) }
    }

    public func deleteAlbum(_ album: AlbumID) {
        if source == .album(album) { openFirstFolder() }
        change { try await $0.deleteAlbum(album) }
    }

    // MARK: Tags

    /// Adds a tag by name to what the commands act on, or to `assets` when given, as the inspector does.
    public func addTag(named name: String, to assets: [AssetID]? = nil) {
        let assets = assets ?? actionAssets
        guard !assets.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        change { try await $0.addTag(named: name, to: assets) }
    }

    public func removeTag(_ tag: TagID, from assets: [AssetID]? = nil) {
        let assets = assets ?? actionAssets
        guard !assets.isEmpty else { return }
        change { try await $0.removeTag(tag, from: assets) }
    }

    /// The Tags menu: on for everything if any is missing it, otherwise off for all.
    public func toggleTag(_ tag: TagID) {
        let assets = actionAssets
        guard !assets.isEmpty else { return }
        change { store in
            let counts = try await store.tagCounts(of: assets)
            if counts[tag, default: 0] < assets.count {
                try await store.addTag(tag, to: assets)
            } else {
                try await store.removeTag(tag, from: assets)
            }
        }
    }

    /// How many of the action items have each tag, for the menu's check marks.
    public func actionTagCounts() async -> (counts: [TagID: Int], total: Int) {
        let assets = actionAssets
        return ((try? await library.store.tagCounts(of: assets)) ?? [:], assets.count)
    }

    public func renameTag(_ tag: TagID, to name: String) {
        change { try await $0.renameTag(tag, to: name) }
    }

    public func deleteTag(_ tag: TagID) {
        if source == .tag(tag) { openFirstFolder() }
        change { try await $0.deleteTag(tag) }
    }

    // MARK: Changes

    /// Writes, then shows the result. The query keeps the place, so a tile that leaves the source hands
    /// the current item to its neighbor.
    private func change(_ body: @escaping @Sendable (LibraryStore) async throws -> Void) {
        let store = library.store
        Task {
            do {
                try await body(store)
            } catch LibraryError.nameTaken {
                setNotice("Another tag already has that name.")
            } catch {
                setNotice(error.localizedDescription)
            }
            organizationDidChange()
        }
    }

    func organizationDidChange() {
        organizationVersion += 1
        Task { await library.refreshOrganization() }
        reload(keepPosition: true)
    }
}
