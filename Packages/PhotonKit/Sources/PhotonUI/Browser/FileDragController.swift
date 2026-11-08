import AppKit
import PhotonMedia

/// Starts dragging files out, from the grid, the list or the viewer. A drag offers copying only, so a
/// drop can never move or delete an original.
@MainActor
final class FileDragController {
    /// A tile's part in the drag's image.
    struct Preview {
        var row: Int
        var frame: CGRect
        var contents: Any?
    }

    /// Files that are dragging items, which are the tiles with an image in the pile. A large selection
    /// can't have one item per file: AppKit walks them on worker threads, and each costs time at the
    /// start of the drag. The other files go straight onto the drag's pasteboard.
    static let shownItems = 16

    private var rows = IndexSet()
    private var files: [CopiedFile]?
    private var task: Task<Void, Never>?
    private var hasReportedOffline = false
    /// A drag started on files that are all offline. Called once per selection.
    var onOfflineDrag: (() -> Void)?

    /// Fetches the files for `rows`, once. Runs while the button is down, ahead of the drag.
    func prepare(rows: IndexSet, fetch: @escaping @Sendable () async -> [CopiedFile]) {
        guard rows != self.rows || (files == nil && task == nil) else { return }
        task?.cancel()
        self.rows = rows
        files = nil
        hasReportedOffline = false
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let found = await fetch()
            guard !Task.isCancelled else { return }
            await self?.landed(found, rows: rows)
        }
    }

    private func landed(_ found: [CopiedFile], rows: IndexSet) {
        guard rows == self.rows else { return }
        files = found
        task = nil
    }

    var hasFilesForTesting: Bool { files != nil }

    /// The URL for a row of the prepared selection, for the list, which asks row by row. Nil for an
    /// offline file, or if the URLs aren't here yet, and then there's nothing to drag for that row.
    func url(forRow row: Int) -> URL? {
        guard let files, rows.contains(row), let first = rows.first else { return nil }
        let position = rows.count(in: first..<row)
        return position < min(files.count, Self.shownItems) ? files[position].url : nil
    }

    /// Adds the files past the dragging items to a session. Writing is the slow part, so it happens off
    /// the main thread, and a drop in the first moments of a very large drag may carry only some.
    func addRemainingFiles(to session: NSDraggingSession) {
        guard let files, files.count > Self.shownItems else { return }
        let urls = files.dropFirst(Self.shownItems).compactMap(\.url)
        let pasteboard = SendablePasteboard(pasteboard: session.draggingPasteboard)
        DispatchQueue.global(qos: .userInitiated).async {
            pasteboard.pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
    }

    /// Starts the drag. Returns false if the files haven't arrived, and the next mouse event tries again.
    func begin(
        from view: NSView & NSDraggingSource, event: NSEvent, previews: [Preview], formation: NSDraggingFormation
    ) -> Bool {
        guard let files else { return false }
        let urls = files.compactMap(\.url)
        if urls.isEmpty, !files.isEmpty, !hasReportedOffline {
            hasReportedOffline = true
            onOfflineDrag?()
        }
        guard !urls.isEmpty, let first = previews.first else { return false }
        let items = files.prefix(Self.shownItems).compactMap(\.url).enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let preview = index < previews.count ? previews[index] : nil
            item.setDraggingFrame(preview?.frame ?? first.frame, contents: preview?.contents)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: view)
        session.draggingFormation = formation
        session.animatesToStartingPositionsOnCancelOrFail = true
        addRemainingFiles(to: session)
        return true
    }
}

/// `NSPasteboard` works from any thread, but isn't marked as such.
private struct SendablePasteboard: @unchecked Sendable {
    let pasteboard: NSPasteboard
}
