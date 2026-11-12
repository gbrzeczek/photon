import AppKit
import Foundation
import Observation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonVideo

/// The library and everything that works on it, for one app window. Everything it awaits runs off the
/// main thread.
@MainActor
@Observable
public final class BrowserLibrary {
    public private(set) var folders: [BrowseFolder] = []
    /// Manual and smart albums, by name, for the sidebar and the Add to Album menu.
    public private(set) var albums: [Album] = []
    public private(set) var tags: [Tag] = []
    /// Folders open in the sidebar's tree, kept in the library so the tree comes back as it was.
    public private(set) var expandedFolders: Set<BrowseScope> = []
    public private(set) var volumes: [VolumeSummary] = []
    public private(set) var onlineVolumes: Set<VolumeID> = []
    /// What can be done with each online volume's files. Anything not here is offline.
    public private(set) var volumeAccess: [VolumeID: VolumeAccess] = [:]
    /// Online volumes the Eject command can act on.
    public private(set) var ejectableVolumes: Set<VolumeID> = []
    /// Something about a connected drive that stays true for as long as it's connected.
    public private(set) var volumeNotice: String?
    public private(set) var isIndexing = false
    public private(set) var activity = ""
    public private(set) var lastError: String?

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let indexer: LibraryIndexer
    @ObservationIgnored let generator: ThumbnailGenerator
    @ObservationIgnored let loader: ThumbnailLoader
    @ObservationIgnored let originals: OriginalReader
    @ObservationIgnored let pasteboard: MediaPasteboard
    @ObservationIgnored let videoEngines = VideoEngines.standard
    @ObservationIgnored private var hasLoadedExpansion = false
    @ObservationIgnored private var packs: ThumbnailPackStore
    @ObservationIgnored private var monitor: VolumeEventMonitor?
    @ObservationIgnored private var backgroundTasks: [VolumeID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rescanTasks: [VolumeID: Task<Void, Never>] = [:]
    /// Rescans that stopped for Add Folder, to start again when it's done.
    @ObservationIgnored private var interruptedRescans: [VolumeID: MountedVolume] = [:]
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var connectsAgain = false
    @ObservationIgnored private let ejector: VolumeEjector
    /// Tells the browser that the library changed. It decides how often to look.
    @ObservationIgnored var onContentChanged: (() -> Void)?
    /// A volume came online or went away. The rows are the same, but what they can do isn't.
    @ObservationIgnored var onVolumesChanged: (() -> Void)?
    /// Something worth a line in the status bar for a moment.
    @ObservationIgnored var onNotice: ((String) -> Void)?

    /// Must run off the main thread, because it opens the database.
    public nonisolated static func open(url: URL?) throws -> LibraryHandle {
        LibraryHandle(store: try LibraryStore(url: url ?? LibraryStore.defaultURL()))
    }

    /// What the app reads with. A writable external drive is fine, because Photon writes nothing to it.
    public static var defaultOptions: IndexOptions {
        var options = IndexOptions()
        options.requiresReadOnlyExternal = false
        return options
    }

    /// - Parameters:
    ///   - ejectScope: Stays at disk images unless this is the app using its real library, so that
    ///     nothing but the user's own click can reach a real drive.
    ///   - options: For tests, which inject failures here.
    public init(
        _ handle: LibraryHandle, ejectScope: EjectScope = .diskImagesOnly, options: IndexOptions = defaultOptions
    ) {
        let store = handle.store
        self.store = store
        ejector = VolumeEjector(scope: ejectScope)
        let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader(), options: options)
        self.indexer = indexer
        let packs = ThumbnailPackStore(store: store)
        self.packs = packs
        let generator = ThumbnailGenerator(
            store: store, packs: packs, scheduler: { indexer.scheduler(for: $0) }, video: AVFoundationThumbnailer())
        self.generator = generator
        let loader = ThumbnailLoader(store: store, packs: packs, generator: generator, cache: ThumbnailMemoryCache())
        self.loader = loader
        let originals = OriginalReader(store: store, scheduler: { indexer.scheduler(for: $0) })
        self.originals = originals
        pasteboard = MediaPasteboard { file, type in
            // An offline photo still has its stored thumbnail, which is better than nothing to paste.
            let bytes = try? await originals.read(file.instance, priority: .visible)
            return await PasteboardImage.offPool {
                guard let data = bytes ?? loader.storedThumbnailBlocking(asset: file.asset) else { return nil }
                return PasteboardImage.encode(data, as: type)
            }
        }
        indexer.setChangeHandler { [weak self] in
            Task { @MainActor in await self?.connectVolumes() }
        }
        monitor = VolumeEventMonitor(
            center: NSWorkspace.shared.notificationCenter,
            willUnmount: { indexer.volumeWillUnmount(mountPoint: $0) },
            didUnmount: { [weak self] path in
                indexer.volumeDidUnmount(mountPoint: path)
                // A clone isn't connected, so its unmount reaches nothing else.
                Task { @MainActor in await self?.connectVolumes() }
            },
            didMount: { [weak self] _ in
                Task { @MainActor in await self?.connectVolumes() }
            },
            didRename: { [weak self] old, _ in
                indexer.volumeDidRename(from: old)
                Task { @MainActor in await self?.connectVolumes() }
            })
    }

    /// Connects known volumes that are mounted, rescans them, and carries on with any thumbnails they're
    /// missing.
    public func start() async {
        await refresh()
        await connectVolumes()
    }

    /// What the viewer plays a video from. Nil when its volume is offline. Reads the library only.
    nonisolated func videoSource(_ instance: FileInstanceID) async -> VideoSource? {
        guard let row = try? await store.browseRows(instances: [instance.rawValue]).first,
            let scheduler = indexer.scheduler(for: row.volumeID)
        else { return nil }
        return VideoSource(path: row.path, size: row.size, modifiedTime: row.modifiedTime, scheduler: scheduler)
    }

    /// Runs one at a time, however many mount events arrive. One that arrives during a run gets one more.
    private func connectVolumes() async {
        guard !isConnecting else {
            connectsAgain = true
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        repeat {
            connectsAgain = false
            if let report = try? await indexer.connectKnownVolumes() {
                setVolumeNotice(duplicates: report.duplicateNames)
                for connection in report.connections where indexer.access(to: connection.volume) != .offline {
                    if connection.isNew {
                        startRescan(connection.volume, mount: connection.mount)
                    } else if rescanTasks[connection.volume] == nil {
                        startThumbnails(connection.volume)
                    }
                }
            }
            refreshVolumes()
        } while connectsAgain
    }

    private func setVolumeNotice(duplicates: [String]) {
        let notice = duplicates.first.map { "A copy of “\($0)” is connected. Photon is using the original." }
        if notice != volumeNotice { volumeNotice = notice }
    }

    private func refreshVolumes() {
        var access: [VolumeID: VolumeAccess] = [:]
        var ejectable: Set<VolumeID> = []
        for volume in indexer.onlineVolumes().values {
            access[volume] = indexer.access(to: volume)
            if let mount = indexer.mount(of: volume), ejector.canEject(mount) { ejectable.insert(volume) }
        }
        guard access != volumeAccess || ejectable != ejectableVolumes else { return }
        volumeAccess = access
        ejectableVolumes = ejectable
        onlineVolumes = Set(access.keys)
        onVolumesChanged?()
    }

    /// What changed while a volume was away. An unchanged rescan lists directories and opens no files.
    private func startRescan(_ volume: VolumeID, mount: MountedVolume) {
        guard rescanTasks[volume] == nil else { return }
        let indexer = indexer
        rescanTasks[volume] = Task {
            let report = try? await indexer.rescan(mount: mount) { progress in
                guard case .processing(let processed) = progress else { return }
                Task { @MainActor in
                    guard !self.isIndexing else { return }
                    self.activity = "Read \(processed) files…"
                    self.onContentChanged?()
                }
            }
            rescanTasks[volume] = nil
            if !isIndexing { activity = "" }
            switch report?.outcome {
            case .cancelled:
                interruptedRescans[volume] = mount
                return
            case .volumeFailing:
                onNotice?("“\(mount.name)” isn't responding. Photon will try again when it's reconnected.")
                return
            case .volumeOffline, nil:
                return
            case .completed:
                break
            }
            await refresh()
            if let scan = report?.scan, scan.added + scan.modified + scan.removed > 0 || report?.processed != 0 {
                onContentChanged?()
            }
            startThumbnails(volume)
        }
    }

    // MARK: Eject

    /// The user's Eject command. Failing is normal, because another app may be using the volume, and then
    /// nothing has changed.
    public func eject(_ volume: VolumeID) {
        guard ejectableVolumes.contains(volume) else { return }
        let name = name(of: volume)
        let indexer = indexer
        let ejector = ejector
        Task {
            do {
                try await indexer.eject(volume, using: ejector)
                onNotice?("“\(name)” was ejected. It can be browsed from stored thumbnails.")
            } catch {
                onNotice?("“\(name)” couldn't be ejected. \(error.localizedDescription)")
            }
            refreshVolumes()
        }
    }

    public func name(of volume: VolumeID) -> String {
        volumes.first { $0.volume.id == volume }?.volume.name ?? "Volume"
    }

    private func refresh() async {
        do {
            // Assigned only when they differ, because each assignment rebuilds the sidebar.
            let summaries = try await store.volumeSummaries()
            if summaries != volumes { volumes = summaries }
            let found = try await store.folders()
            if found != folders { folders = found }
            if !hasLoadedExpansion {
                hasLoadedExpansion = true
                expandedFolders = try await store.expandedFolders()
            }
            await refreshOrganization()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Albums and tags, after a change to them.
    public func refreshOrganization() async {
        let foundAlbums = (try? await store.albums()) ?? albums
        if foundAlbums != albums { albums = foundAlbums }
        let foundTags = (try? await store.tags()) ?? tags
        if foundTags != tags { tags = foundTags }
    }

    /// Opens or closes a folder in the sidebar's tree. Shown at once, and saved behind it.
    public func setFolder(_ scope: BrowseScope, expanded: Bool) {
        guard expanded != expandedFolders.contains(scope) else { return }
        if expanded { expandedFolders.insert(scope) } else { expandedFolders.remove(scope) }
        let store = store
        Task { try? await store.setFolder(scope, expanded: expanded) }
    }

    /// Opens the folders above `scope`, from its library root down, so the tree shows it. The folder
    /// itself stays as it was.
    public func revealInTree(_ scope: BrowseScope) {
        let roots = folders.filter {
            $0.isRoot && $0.volume == scope.volume
                && ($0.path.isEmpty || scope.path == $0.path || scope.path.hasPrefix($0.path + "/"))
        }
        // The innermost, if one added folder is inside another.
        guard let root = roots.max(by: { $0.path.count < $1.path.count }) else { return }
        var path = root.path
        for component in scope.path.dropFirst(root.path.count).split(separator: "/") {
            setFolder(BrowseScope(volume: scope.volume, path: path), expanded: true)
            path = path.isEmpty ? String(component) : path + "/" + component
        }
    }

    /// Whether a source still exists. An offline folder is still in the library.
    public func contains(_ source: BrowseSource) -> Bool {
        switch source {
        case .folder(let scope): folders.contains { $0.volume == scope.volume && $0.path == scope.path }
        case .allItems, .favorites: true
        case .album(let id): albums.contains { $0.id == id }
        case .tag(let id): tags.contains { $0.id == id }
        }
    }

    public func createAlbum(named name: String, query: SmartQuery? = nil) async throws -> AlbumID {
        let album = try await store.createAlbum(name: name, query: query)
        await refreshOrganization()
        return album
    }

    public func addFolder(_ folder: URL) {
        guard !isIndexing else { return }
        isIndexing = true
        lastError = nil
        activity = "Reading folders…"
        Task {
            defer { isIndexing = false }
            // One run at a time on a volume. Pending work is stored, so the next run picks it up.
            for task in rescanTasks.values { task.cancel() }
            for task in rescanTasks.values { await task.value }
            do {
                // At most one update per directory or batch, so the hop to the main actor is bounded.
                let report = try await indexer.index(path: folder.path) { progress in
                    Task { @MainActor in self.show(progress) }
                }
                activity = Self.describe(report)
                await refresh()
                refreshVolumes()
                onContentChanged?()
                if let volume = report.volumeID { startThumbnails(volume) }
            } catch {
                activity = ""
                lastError = error.localizedDescription
                await refresh()
            }
            let interrupted = interruptedRescans
            interruptedRescans.removeAll()
            for (volume, mount) in interrupted { startRescan(volume, mount: mount) }
        }
    }

    private func show(_ progress: IndexProgress) {
        guard isIndexing else { return }
        switch progress {
        case .scanning(let report):
            activity = "Found \(report.added + report.modified + report.unchanged) files…"
        case .processing(let processed):
            activity = "Read \(processed) files…"
        }
        Task { await refresh() }
        onContentChanged?()
    }

    private func startThumbnails(_ volume: VolumeID) {
        guard backgroundTasks[volume] == nil else { return }
        let generator = generator
        backgroundTasks[volume] = Task {
            let total = (try? await store.thumbnailBacklog(volume: volume)) ?? 0
            _ = try? await generator.runBackground(volume: volume) { report in
                Task { @MainActor in
                    guard !self.isIndexing else { return }
                    let done = report.previews + report.full
                    self.activity = "Making thumbnails: \(min(done, total * 2) * 100 / max(1, total * 2))%"
                    self.onContentChanged?()
                }
            }
            backgroundTasks[volume] = nil
            if !isIndexing { activity = "" }
            onContentChanged?()
        }
    }

    private static func describe(_ report: IndexReport) -> String {
        switch report.outcome {
        case .completed:
            let changed = report.scan.added + report.scan.modified + report.scan.removed
            return "Done. \(changed) changed, \(report.scan.unchanged) unchanged, \(report.processed) read."
        case .cancelled:
            return "Stopped."
        case .volumeOffline:
            return "The volume went offline. Indexing continues when it's back."
        case .volumeFailing:
            return "The volume isn't responding. Indexing continues when it's reconnected."
        }
    }
}

/// An opened library, on its way from a background task to the main thread.
public struct LibraryHandle: Sendable {
    let store: LibraryStore
}
