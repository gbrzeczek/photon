import AppKit
import PhotonCore
import PhotonIndex
import SwiftUI

extension FocusedValues {
    @Entry public var browserModel: BrowserModel?
}

/// The app's window: folders in the sidebar, and the grid or list beside them.
public struct PhotonRootView: View {
    @State private var state: LoadState = .loading
    @State private var quitObserver: (any NSObjectProtocol)?
    private let launch: LaunchSettings

    private enum LoadState {
        case loading
        case failed(String)
        case ready(BrowserLibrary, BrowserModel)
    }

    public init() { launch = LaunchSettings() }

    public var body: some View {
        Group {
            switch state {
            case .loading:
                Color.clear
            case .failed(let message):
                ContentUnavailableView(
                    "Can't Open the Library", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready(let library, let model):
                BrowserShell(library: library, model: model)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .task { await load() }
    }

    private func load() async {
        guard case .loading = state else { return }
        DevelopmentHooks.applyAppearance()
        let url = launch.libraryURL
        do {
            let handle = try await Task.detached(priority: .userInitiated) { try BrowserLibrary.open(url: url) }.value
            let library = BrowserLibrary(handle, ejectScope: launch.ejectScope)
            let model = BrowserModel(library: library)
            model.setLayoutMode(launch.layoutMode)
            // The last session comes first: it's what launch is measured by, and it needs no volumes.
            let restored = await model.restoreLastSession(opensViewer: launch.restoresViewer)
            state = .ready(library, model)
            quitObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak model] _ in
                MainActor.assumeIsolated {
                    model?.saveSessionBeforeQuit()
                    library.pasteboard.applicationWillQuit()
                }
            }
            await library.start()
            if restored {
                model.leaveVanishedFolder()
            } else {
                model.openFirstFolder()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// What a launch can override. Tests and measurements use these to stay away from the real library.
struct LaunchSettings {
    var libraryURL: URL?
    var layoutMode = TileLayoutMode.square
    /// Disk images only, unless nothing about this launch says it's a test or a measurement. Whoever
    /// sets `PHOTON_LIBRARY` is running the app for a reason of their own, and a real drive mustn't be
    /// within its reach.
    var ejectScope = EjectScope.diskImagesOnly
    /// Tests and measurements start from the grid, whatever the last run ended on.
    var restoresViewer = true

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        libraryURL = environment["PHOTON_LIBRARY"].map { URL(fileURLWithPath: $0) }
        if environment["PHOTON_LAYOUT"] == "aspect" { layoutMode = .aspect }
        if environment["PHOTON_NO_VIEWER_RESTORE"] != nil || environment["PHOTON_PERF_OUT"] != nil {
            restoresViewer = false
        }
        if !environment.keys.contains(where: { $0.hasPrefix("PHOTON_") || $0.hasPrefix("XCTest") }) {
            ejectScope = .anyExternalVolume
        }
    }
}

private struct BrowserShell: View {
    let library: BrowserLibrary
    let model: BrowserModel
    @State private var isChoosingFolder = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: library, model: model) { model.smartAlbumRequest = SmartAlbumRequest(album: $0) }
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            detail
                .inspector(isPresented: Binding(get: { model.isInspectorShown }, set: { model.isInspectorShown = $0 })) {
                    InspectorView(library: library, model: model)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
                }
        }
        .focusedSceneValue(\.browserModel, model)
        .toolbar { toolbar }
        .modifier(SearchField(model: model))
        .modifier(WindowTitle(model: model, folder: title))
        .sheet(item: Binding(get: { model.smartAlbumRequest }, set: { model.smartAlbumRequest = $0 })) { request in
            SmartAlbumEditor(library: library, model: model, album: request.album)
        }
    }

    private var title: String {
        switch model.source {
        case nil: return "Photon"
        case .allItems: return "All Items"
        case .favorites: return "Favorites"
        case .album(let id): return library.albums.first { $0.id == id }?.name ?? "Album"
        case .tag(let id): return library.tags.first { $0.id == id }?.name ?? "Tag"
        case .folder(let scope):
            return scope.path.split(separator: "/").last.map(String.init)
                ?? library.volumes.first { $0.volume.id == scope.volume }?.volume.name ?? "Photon"
        }
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            BrowserContentRepresentable(model: model)
            if library.folders.isEmpty, !library.isIndexing {
                ContentUnavailableView {
                    Label("No Folders Yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Add a folder to browse its photos and videos.")
                } actions: {
                    Button("Add Folder…", action: chooseFolder)
                }
                .background(.background)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(library: library, model: model) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { BackButton(model: model) }
        ToolbarItemGroup {
            SizeControl(model: model)
            Picker(
                "View",
                selection: Binding(get: { model.viewMode }, set: { model.setViewMode($0) })
            ) {
                Label("Tiles", systemImage: "square.grid.2x2").tag(BrowserViewMode.tiles)
                Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Show as tiles or a list")

            Menu("Sort", systemImage: "arrow.up.arrow.down") { SortMenuItems(model: model) }
                .help("Sort order")

            Button("Add Folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                .disabled(library.isIndexing)
                .help("Add a folder to the library")
        }
        ToolbarItem { FavoriteButton(model: model) }
        ToolbarItem {
            Button("Inspector", systemImage: "info.circle") { model.toggleInspector() }
                .help("Show or hide the inspector")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            library.addFolder(url)
        }
    }
}

/// Its own view, like `SizeControl`, because these values change often. Reading them in `BrowserShell`
/// would rebuild the toolbar for every step of a pinch and every change of selection.
private struct StatusBar: View {
    let library: BrowserLibrary
    let model: BrowserModel

    var body: some View {
        HStack {
            VolumeBadge(model: model)
            Text(status)
            Spacer()
            if let message = model.notice ?? library.lastError ?? library.volumeNotice
                ?? (library.activity.isEmpty ? nil : library.activity)
            {
                Text(message).lineLimit(1)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .accessibilityIdentifier("photon.status")
    }

    private var status: String {
        if model.isViewerOpen, !model.viewerStatus.isEmpty { return model.viewerStatus }
        let items = model.itemCount.formatted()
        let noun = model.itemCount == 1 ? "item" : "items"
        return model.selectedCount > 0
            ? "\(model.selectedCount.formatted()) of \(items) selected" : "\(items) \(noun)"
    }
}

/// Says when the folder showing can't do everything. A disconnected drive is a normal state, so this is
/// quiet: everything but the original files keeps working.
private struct VolumeBadge: View {
    let model: BrowserModel

    var body: some View {
        if model.scope != nil {
            switch model.scopeAccess {
            case .offline:
                Label("\(model.volumeName ?? "Volume") is offline", systemImage: "externaldrive.badge.xmark")
                    .help("Browsing from stored thumbnails. Connect the drive to see the originals.")
            case .readOnly:
                Label("Read Only", systemImage: "lock")
                    .help("This volume can't be changed, so Rename and Move to Trash aren't available.")
            case .writable:
                EmptyView()
            }
        }
    }
}

/// Up a folder, or back out of the viewer. Its own view, so that opening the viewer doesn't rebuild the
/// toolbar during the transition.
private struct BackButton: View {
    let model: BrowserModel

    var body: some View {
        if model.isViewerOpen {
            Button("Back", systemImage: "chevron.backward") { model.closeViewer() }
                .help("Go back to the browser")
        } else {
            Button("Enclosing Folder", systemImage: "chevron.up") { model.openParent() }
                .disabled(!model.canOpenParent)
                .help("Go to the enclosing folder")
        }
    }
}

/// Tile size in the browser, and zoom in the viewer. Its own view, so that neither rebuilds the toolbar.
private struct SizeControl: View {
    let model: BrowserModel

    var body: some View {
        if model.isViewerOpen {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.stepZoom(larger: false) }
                    .help("Zoom out")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { model.stepZoom(larger: true) }
                    .help("Zoom in")
            }
            .disabled(model.viewerCaption?.isVideo == true)
        } else if model.viewMode == .tiles {
            Slider(
                value: Binding(get: { model.tileSize }, set: { model.setTileSizeFromSlider($0) }),
                in: Double(TileMetrics.minimumTile)...Double(TileMetrics.maximumTile)
            )
            .frame(width: 120)
            .accessibilityLabel("Tile size")
            .help("Tile size")
        }
    }
}

/// Favorite or unfavorite what the commands act on. Its own view, because its state follows the selection.
private struct FavoriteButton: View {
    let model: BrowserModel

    var body: some View {
        let isFavorite = model.actionStateToken >= 0 && model.actionItemsAreFavorites
        Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart") {
            model.toggleFavorite()
        }
        .disabled(!model.hasActionItems)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }
}

/// The search field in the toolbar. A modifier with its own text, so that typing doesn't run
/// `BrowserShell`'s body, and it filters after a short pause.
private struct SearchField: ViewModifier {
    let model: BrowserModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: "Search")
            .searchFocused($isFocused)
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                model.setSearch(text)
            }
            .onChange(of: model.source) { text = "" }
            .onChange(of: model.searchFocusRequest) { isFocused = true }
    }
}

/// The folder in the browser, and the photo's name and date in the viewer, as Preview shows a file's.
/// A modifier, so that a new photo changes the title without running `BrowserShell`'s body.
private struct WindowTitle: ViewModifier {
    let model: BrowserModel
    let folder: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(model.viewerCaption?.name ?? folder)
            .navigationSubtitle(model.viewerCaption?.detail ?? "")
    }
}

struct SortMenuItems: View {
    let model: BrowserModel

    var body: some View {
        ForEach(SortKey.allCases, id: \.self) { key in
            Toggle(
                title(key),
                isOn: Binding(get: { model.sort.key == key }, set: { _ in model.chooseSort(key) }))
        }
        Divider()
        Picker(
            "Order",
            selection: Binding(
                get: { model.sort.ascending },
                set: { model.setSort(BrowseSort(key: model.sort.key, ascending: $0)) })
        ) {
            Text("Ascending").tag(true)
            Text("Descending").tag(false)
        }
        .pickerStyle(.inline)
    }

    private func title(_ key: SortKey) -> String {
        switch key {
        case .date: "Date"
        case .name: "Name"
        case .size: "Size"
        case .type: "Kind"
        case .duration: "Duration"
        }
    }
}

/// The app's menus, with their shortcuts. Each one acts on the focused window's browser.
public struct PhotonCommands: Commands {
    @FocusedValue(\.browserModel) private var model

    public init() {}

    private var isViewing: Bool { model?.isViewerOpen == true }

    private var ejectTitle: String {
        guard model?.canEjectVolume == true, let name = model?.volumeName else { return "Eject" }
        return "Eject “\(name)”"
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Album…") {
                if let name = NamePrompt.ask("New Album", message: "", initial: "Untitled Album", action: "Create") {
                    model?.newAlbum(named: name, addingItems: false)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model == nil)
            Button("New Smart Album…") { model?.smartAlbumRequest = SmartAlbumRequest(album: nil) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
            Button(ejectTitle) { model?.ejectVolume() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model?.canEjectVolume != true)
        }
        CommandGroup(before: .toolbar) {
            Button("as Tiles") { model?.setViewMode(.tiles) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(model == nil)
            Button("as List") { model?.setViewMode(.list) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button(isViewing ? "Zoom In" : "Increase Tile Size") { model?.stepZoom(larger: true) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!isViewing && model?.viewMode != .tiles)
            Button(isViewing ? "Zoom Out" : "Decrease Tile Size") { model?.stepZoom(larger: false) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!isViewing && model?.viewMode != .tiles)
            Button("Zoom to Fit") { model?.zoomViewerToFit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!isViewing)
            Toggle(
                "Keep Aspect Ratio",
                isOn: Binding(
                    get: { model?.layoutMode == .aspect },
                    set: { model?.setLayoutMode($0 ? .aspect : .square) })
            )
            .disabled(model == nil)
            Divider()
            Button("Open in Viewer") { model?.openViewer() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model?.canOpenViewer != true)
            Button("Close Viewer") { model?.closeViewer() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!isViewing)
            Divider()
            if let model {
                Menu("Sort By") { SortMenuItems(model: model) }
            }
            Toggle(
                "Expand Stacks",
                isOn: Binding(get: { model?.expandsStacks == true }, set: { model?.setExpandsStacks($0) })
            )
            .disabled(model == nil)
            Button(model?.isInspectorShown == true ? "Hide Inspector" : "Show Inspector") { model?.toggleInspector() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model == nil)
            Button("Enclosing Folder") { model?.openParent() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model?.canOpenParent != true)
            Divider()
        }
        CommandGroup(after: .pasteboard) {
            Button("Select None") { model?.selectNone() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model == nil)
            Divider()
            Button("Find") { model?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model == nil)
        }
        CommandMenu("Image") {
            if let model { ImageMenuItems(model: model) }
        }
        SidebarCommands()
    }
}

/// The Image menu: favorites, albums and tags for what the commands act on.
private struct ImageMenuItems: View {
    let model: BrowserModel

    var body: some View {
        let hasItems = model.actionStateToken >= 0 && model.hasActionItems
        // Period and Delete aren't bound here: a menu takes a key before a text field does, so typing a
        // period or deleting in the search field would change the library. Grid, list and viewer handle
        // them, and the context menu shows them.
        Button(model.actionItemsAreFavorites ? "Unfavorite" : "Favorite") { model.toggleFavorite() }
            .disabled(!hasItems)
        Menu("Add to Album") {
            ForEach(model.library.albums.filter { !$0.isSmart }) { album in
                Button(album.name) { model.addToAlbum(album.id) }
            }
            Divider()
            Button("New Album…") {
                if let name = NamePrompt.ask(
                    "New Album", message: "Add the selected items to a new album.", initial: "Untitled Album",
                    action: "Create")
                {
                    model.newAlbum(named: name, addingItems: true)
                }
            }
        }
        .disabled(!hasItems)
        if let album = model.currentManualAlbum {
            Button("Remove from “\(album.name)”") { model.removeFromAlbum() }
                .disabled(!hasItems)
        }
        Button("Add Tag…") {
            if let name = NamePrompt.ask("Add Tag", message: "Tag the selected items.", initial: "", action: "Add") {
                model.addTag(named: name)
            }
        }
        .disabled(!hasItems)
    }
}
