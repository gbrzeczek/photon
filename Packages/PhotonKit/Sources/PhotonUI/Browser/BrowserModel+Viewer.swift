import AppKit
import PhotonCore
import PhotonIndex
import PhotonMedia

// The viewer shares the current item with the grid and list. While it's open, moving changes the
// selection model but tells neither of them, so that a held arrow key costs them nothing. They catch up
// when it closes, and that's when the grid moves to the photo you ended on.
extension BrowserModel: ViewerHost {
    public var canOpenViewer: Bool { !isViewerOpen && itemCount > 0 }

    public func openViewer() {
        guard !isViewerOpen, result.count > 0 else { return }
        let row = selection.currentRow ?? active?.captureAnchor()?.row ?? 0
        if selection.currentRow == nil { select(row: row) }
        // However the viewer was opened, a tile's preview shouldn't play on underneath it.
        (active as? TileGridView)?.stopVideoPreview()
        isViewerOpen = true
        viewer?.open(row: row)
        saveSessionSoon()
    }

    public func closeViewer(animated: Bool = true) {
        guard isViewerOpen else { return }
        isViewerOpen = false
        captionTask?.cancel()
        viewerCaption = nil
        selectionChanged()
        active?.revealCurrent()
        let tile = animated ? selection.currentRow.flatMap { row in viewer.flatMap { active?.tileRect(row: row, in: $0) } } : nil
        viewer?.close(to: tile, animated: animated)
        active?.focus()
    }

    func stepViewer(by delta: Int, isRepeat: Bool) {
        guard let row = selection.currentRow else { return }
        let target = min(max(row + delta, 0), result.count - 1)
        guard target != row else { return }
        moveViewer(to: target, isRepeat: isRepeat, direction: delta)
    }

    func stepViewer(to target: Int) {
        guard let row = selection.currentRow, target != row, target >= 0, target < result.count else { return }
        moveViewer(to: target, isRepeat: false, direction: target > row ? 1 : -1)
    }

    private func moveViewer(to row: Int, isRepeat: Bool, direction: Int) {
        selection.select(row, asset: AssetID(rawValue: result.assetIDs[row]))
        viewer?.show(row: row, isRepeat: isRepeat, direction: direction)
        saveSessionSoon()
    }

    func panViewer(dx: Int, dy: Int) -> Bool { viewer?.pan(dx: dx, dy: dy) ?? false }

    /// The video in the viewer, when it's showing one.
    var viewerVideo: ViewerVideo? { viewer?.isShowingVideo == true ? viewer?.video : nil }

    /// Command-Equals and Command-Minus: the viewer's zoom when it's open, the tile size otherwise.
    public func stepZoom(larger: Bool) {
        if isViewerOpen {
            viewer?.zoom(larger: larger)
        } else {
            stepTileSize(larger: larger)
        }
    }

    public func zoomViewerToFit() { viewer?.zoomToFit() }

    // MARK: ViewerHost

    var viewerRow: Int? { selection.currentRow }
    var viewerResult: BrowseResult { result }

    var viewerWaitingText: String { "Waiting for \(volumeName ?? "the drive")…" }

    func viewerRect(row: Int) -> CGRect? { viewer.flatMap { active?.tileRect(row: row, in: $0) } }
    func viewerHideTile(row: Int?) { active?.hideTile(row: row) }
    func viewerDidFinishClosing() {
        viewerStatus = ""
        viewerVideoDidChange(VideoMenuState(isMuted: videoMenu.isMuted))
    }

    func viewerStatusDidChange(_ status: String) {
        if status != viewerStatus { viewerStatus = status }
    }

    func viewerVideoDidChange(_ state: VideoMenuState) {
        if state != videoMenu { videoMenu = state }
    }

    // MARK: The Video menu

    /// Space, from the menu. Space itself can't be the menu's shortcut, because the menu would take it
    /// from the search field.
    public func togglePlayback() { viewerVideo?.togglePlay() }
    /// Shift-Left and Shift-Right, from the menu.
    public func skipVideo(forward: Bool) { viewerVideo?.seek(by: forward ? 5 : -5) }
    /// M, from the menu.
    public func toggleVideoMute() { viewerVideo?.toggleMute() }
    /// `[`, `]` and `=`, from the menu.
    public func stepVideoSpeed(faster: Bool) { viewerVideo?.stepSpeed(faster: faster) }
    public func resetVideoSpeed() { viewerVideo?.setSpeed(1) }

    /// The name comes from the library, so it needs no disk and works offline.
    func viewerDidSettle(row: Int) {
        guard row < result.count else { return }
        inspect(AssetID(rawValue: result.assetIDs[row]), immediately: true)
        let instance = result.instanceIDs[row]
        let store = library.store
        captionTask?.cancel()
        captionTask = Task {
            let found = try? await store.browseRows(instances: [instance]).first
            guard !Task.isCancelled, isViewerOpen, let found else { return }
            let caption = ViewerCaption(found)
            if caption != viewerCaption { viewerCaption = caption }
        }
    }

    func viewerKey(_ event: NSEvent) -> Bool { ViewerKeys.handle(event, model: self) }
    func viewerContextMenu() -> NSMenu { BrowserContextMenu.make(model: self) }
    func viewerSwipe(_ direction: Int) { stepViewer(by: direction, isRepeat: false) }
    func viewerPrepareDrag() { prepareDrag() }

    func viewerBeginDrag(event: NSEvent, frame: CGRect, contents: Any?) {
        guard let viewer, let row = selection.currentRow else { return }
        let preview = FileDragController.Preview(row: row, frame: frame, contents: contents)
        if fileDrag.begin(from: viewer, event: event, previews: [preview], formation: .none) {
            viewer.endDragTracking()
        }
    }

    // MARK: Copy and drag

    /// What copying or dragging acts on: the photo in the viewer, or else the selection, or else the
    /// current item.
    var actionRows: IndexSet {
        if !isViewerOpen, !selection.rows.isEmpty { return selection.rows }
        return selection.currentRow.map { IndexSet(integer: $0) } ?? IndexSet()
    }

    /// The one copy command, for grid, list and viewer. Returns at once, whatever the selection's size.
    public func copy() {
        let rows = actionRows
        guard !rows.isEmpty else { return }
        copyTask?.cancel()
        let result = result
        let store = library.store
        let indexer = library.indexer
        let pasteboard = library.pasteboard
        pasteboard.clear()
        // At about 150 µs per file, this is where the wait starts to show.
        if rows.count >= Self.slowCopyCount { setNotice("Copying \(rows.count.formatted()) items…", clears: false) }
        copyTask = Task.detached(priority: .userInitiated) { [weak self] in
            let files = await Self.files(rows: rows, result: result, store: store, indexer: indexer)
            guard !Task.isCancelled else { return }
            await pasteboard.write(files)
            let offline = files.count { $0.url == nil }
            guard !Task.isCancelled else { return }
            await self?.didCopy(count: files.count, offline: offline)
        }
    }

    private static var slowCopyCount: Int { 2_000 }

    private func didCopy(count: Int, offline: Int) {
        guard offline > 0 else {
            if count >= Self.slowCopyCount { setNotice("Copied \(count.formatted()) items.") }
            return
        }
        let names = offline == 1 ? "1 item is" : "\(offline.formatted()) items are"
        setNotice(
            count <= MediaPasteboard.imageDataLimit
                ? "\(names) offline, so only a thumbnail was copied." : "\(names) offline and weren't copied.")
    }

    func setNotice(_ text: String, clears: Bool = true) {
        notice = text
        noticeTask?.cancel()
        guard clears else { return }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    /// Fetches the files for a drag while the button is down, because a drag has to start at once.
    func prepareDrag() {
        let rows = actionRows
        guard !rows.isEmpty else { return }
        let result = result
        let store = library.store
        let indexer = library.indexer
        fileDrag.onOfflineDrag = { [weak self] in self?.setNotice("Offline items can't be dragged.") }
        fileDrag.prepare(rows: rows) {
            await Self.files(rows: rows, result: result, store: store, indexer: indexer)
        }
    }

    /// Everything about `rows` that the pasteboard needs, in row order. Off the main thread, and in
    /// batches, because a selection can be the whole library.
    nonisolated static func files(
        rows: IndexSet, result: BrowseResult, store: LibraryStore, indexer: LibraryIndexer
    ) async -> [CopiedFile] {
        let batchSize = 512
        var files: [CopiedFile] = []
        files.reserveCapacity(rows.count)
        var mounts: [VolumeID: String?] = [:]
        var batch: [Int64] = []
        batch.reserveCapacity(batchSize)

        func flush() async {
            let found = (try? await store.browseRows(instances: batch)) ?? []
            for row in found {
                let mount = mounts[row.volumeID] ?? {
                    let mount = indexer.mountPoint(of: row.volumeID)
                    mounts[row.volumeID] = mount
                    return mount
                }()
                let url = mount.map {
                    URL(fileURLWithPath: $0).appending(path: row.path.string, directoryHint: .notDirectory)
                }
                files.append(
                    CopiedFile(url: url, asset: row.assetID, instance: row.instanceID, isVideo: row.kind == .video))
            }
            batch.removeAll(keepingCapacity: true)
        }

        for row in rows {
            if Task.isCancelled { return [] }
            batch.append(result.instanceIDs[row])
            if batch.count == batchSize { await flush() }
        }
        if !batch.isEmpty { await flush() }
        return files
    }
}
