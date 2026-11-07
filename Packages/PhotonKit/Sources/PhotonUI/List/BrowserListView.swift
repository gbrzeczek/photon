import AppKit
import PhotonCore
import PhotonMedia

private enum ListColumn: String, CaseIterable {
    case name, date, size, type, duration

    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .size: "Size"
        case .type: "Kind"
        case .duration: "Duration"
        }
    }

    var sortKey: SortKey {
        switch self {
        case .name: .name
        case .date: .date
        case .size: .size
        case .type: .type
        case .duration: .duration
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 340
        case .date: 170
        case .size: 80
        case .type: 80
        case .duration: 80
        }
    }
}

final class BrowserTableView: NSTableView {
    weak var list: BrowserListView?

    override func mouseDown(with event: NSEvent) {
        list?.prepareDrag(at: event)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if list?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        list?.contextMenu(for: event)
    }

    /// Selection and the highlighted row come from the shared model, through `selectRowIndexes`.
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        list?.focusChanged()
        return result
    }
}

/// A row in the list: a small thumbnail, and a label filling the rest.
private final class ThumbnailView: NSView {
    override var isFlipped: Bool { true }
}

private final class ListCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let thumbnail = ThumbnailView()
    private(set) var assetID: Int64 = 0
    private(set) var shownTier: ThumbnailTier?

    init(hasThumbnail: Bool, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var constraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ]
        if hasThumbnail {
            thumbnail.wantsLayer = true
            thumbnail.layer?.contentsGravity = .resizeAspectFill
            thumbnail.layer?.masksToBounds = true
            thumbnail.layer?.cornerRadius = 3
            thumbnail.translatesAutoresizingMaskIntoConstraints = false
            addSubview(thumbnail)
            constraints += [
                thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
                thumbnail.widthAnchor.constraint(equalToConstant: 28),
                thumbnail.heightAnchor.constraint(equalToConstant: 28),
                label.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 8),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    func show(asset: Int64, thumbnail decoded: DecodedThumbnail?, placeholder: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        assetID = asset
        thumbnail.layer?.backgroundColor = placeholder
        thumbnail.layer?.contents = decoded?.surface
        shownTier = decoded?.tier
        CATransaction.commit()
    }
}

/// The list view: `NSTableView` over the same result and selection as the grid.
/// Rows load in pages, and the table asks only for what's visible.
@MainActor
final class BrowserListView: NSView, BrowserContent, NSTableViewDataSource, NSTableViewDelegate {
    let model: BrowserModel
    let scrollView = NSScrollView()
    let table = BrowserTableView()
    private let loader: ThumbnailLoader
    private var result = BrowseResult.empty
    private var isApplyingSelection = false
    private var needsSelectionSync = false
    /// The table hasn't seen the latest result, because it's hidden.
    private var needsReload = false
    private var pendingReveal = false
    private lazy var ticker = FrameTicker { [weak self] _ in self?.tick() ?? false }

    private static let rowHeight: CGFloat = 32
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        // Capture dates are the camera's wall clock, so they show as written.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(model: BrowserModel) {
        self.model = model
        loader = model.library.loader
        super.init(frame: .zero)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        table.list = self
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.setAccessibilityIdentifier("photon.list")
        table.target = self
        table.doubleAction = #selector(openClickedRow)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        for column in ListColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.sortKey.rawValue, ascending: column.sortKey.defaultAscending)
            table.addTableColumn(tableColumn)
        }

        model.pages.onLoaded = { [weak self] range in self?.rowsLoaded(range) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    private var isShowing: Bool { !isHidden }

    func tick() -> Bool {
        if needsSelectionSync {
            needsSelectionSync = false
            syncSelection()
        }
        if pendingReveal {
            pendingReveal = false
            if let row = model.selection.currentRow { table.scrollRowToVisible(row) }
        }
        drainThumbnails()
        return loader.hasFinishedThumbnails
    }

    private func drainThumbnails() {
        guard isShowing else { return }
        for (asset, thumbnail) in loader.drain(limit: 32) {
            let rows = table.rows(in: table.visibleRect)
            for row in rows.lowerBound..<rows.upperBound where row < result.count && result.assetIDs[row] == asset.rawValue {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ListCell {
                    cell.show(asset: asset.rawValue, thumbnail: thumbnail, placeholder: nil)
                }
            }
        }
    }

    private func requestTick() {
        guard window != nil else { return }
        ticker.start(in: self)
    }

    private func syncSelection() {
        isApplyingSelection = true
        table.selectRowIndexes(model.selection.rows, byExtendingSelection: false)
        isApplyingSelection = false
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        let selected = model.selection.count
        let position = model.selection.currentRow.map { "Item \($0 + 1) of \(result.count)" } ?? "\(result.count) items"
        table.setAccessibilityValueDescription("\(position), \(selected) selected")
        table.setAccessibilityHelp("\(position), \(selected) selected")
    }

    // MARK: BrowserContent

    func captureAnchor() -> ViewAnchor? {
        guard result.count > 0 else { return nil }
        let visible = table.visibleRect
        let height = table.rowHeight + table.intercellSpacing.height
        if let row = model.selection.currentRow, row < result.count {
            let rect = table.rect(ofRow: row)
            if rect.intersects(visible) { return ViewAnchor(row: row, screenY: rect.midY - visible.minY) }
        }
        let row = min(result.count - 1, max(0, Int((visible.midY) / height)))
        return ViewAnchor(row: row, screenY: table.rect(ofRow: row).midY - visible.minY)
    }

    func resultDidChange(_ result: BrowseResult, anchor: ViewAnchor?, rows: AspectRows?, prefix: [Double]) {
        self.result = result
        // A hidden table would still lay out rows and make cells, and the grid would pay for it.
        guard !isHidden else {
            needsReload = true
            return
        }
        table.reloadData()
        syncSelection()
        updateSortIndicator()
        if let anchor {
            let top = table.rect(ofRow: anchor.row).midY - anchor.screenY
            table.scroll(CGPoint(x: 0, y: max(0, top)))
        } else {
            table.scroll(.zero)
        }
    }

    func selectionDidChange() {
        guard !isHidden else { return }
        needsSelectionSync = true
        requestTick()
    }

    /// Catches up with what happened while the grid was showing.
    func didBecomeVisible() {
        if needsReload {
            needsReload = false
            table.reloadData()
            updateSortIndicator()
        }
        syncSelection()
    }

    func revealCurrent() {
        pendingReveal = true
        requestTick()
    }

    func row(after move: BrowserMove, from row: Int) -> Int? {
        let count = result.count
        guard count > 0 else { return nil }
        let page = max(1, Int(table.visibleRect.height / (table.rowHeight + table.intercellSpacing.height)) - 1)
        switch move {
        case .left, .right: return nil
        case .up: return max(row - 1, 0)
        case .down: return min(row + 1, count - 1)
        case .pageUp: return max(row - page, 0)
        case .pageDown: return min(row + page, count - 1)
        case .home: return 0
        case .end: return count - 1
        }
    }

    func focus() { window?.makeFirstResponder(table) }

    func tileRect(row: Int, in view: NSView) -> CGRect? {
        guard row < result.count, !isHidden else { return nil }
        // The viewer closes in one step, and a reveal would otherwise wait for the next frame.
        pendingReveal = false
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ListCell else { return nil }
        return cell.thumbnail.convert(cell.thumbnail.bounds, to: view)
    }

    func hideTile(row: Int?) {}
    func tileSizeDidChange() {}
    func steppedTileSize(from size: CGFloat, larger: Bool) -> CGFloat { size }
    func thumbnailsReady() { requestTick() }
    func layoutModeDidChange() {}
    func focusChanged() {}

    private func updateSortIndicator() {
        let descriptor = NSSortDescriptor(key: model.sort.key.rawValue, ascending: model.sort.ascending)
        if table.sortDescriptors.first != descriptor { table.sortDescriptors = [descriptor] }
    }

    // MARK: Input

    func handleKey(_ event: NSEvent) -> Bool {
        BrowserKeys.handle(event, model: model, typeToSelect: true)
    }

    @objc private func openClickedRow() {
        guard table.clickedRow >= 0 else { return }
        model.openViewer()
    }

    func prepareDrag(at event: NSEvent) {
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row >= 0, model.selection.isSelected(row) else { return }
        model.prepareDrag()
    }

    /// The table asks once per selected row, as the drag starts. The URLs were fetched when the button
    /// went down, because this has to answer at once.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        model.fileDrag.url(forRow: row).map { $0 as NSURL }
    }

    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .list
        model.fileDrag.addRemainingFiles(to: session)
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard row >= 0 else { return nil }
        if !model.selection.isSelected(row) { model.select(row: row) }
        return BrowserContextMenu.make(model: model)
    }

    private func rowsLoaded(_ range: Range<Int>) {
        guard isShowing else { return }
        let visible = table.rows(in: table.visibleRect)
        let lower = max(range.lowerBound, visible.lowerBound)
        let upper = min(range.upperBound, visible.upperBound)
        guard lower < upper else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: lower..<upper),
            columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { result.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ListCell)
            ?? makeCell(column, identifier: tableColumn.identifier)
        let loaded = model.pages.row(row)
        switch column {
        case .name:
            cell.label.stringValue = loaded?.path.name ?? ""
            configureThumbnail(cell, row: row)
        case .date:
            cell.label.stringValue = loaded.map(date) ?? ""
        case .size:
            cell.label.stringValue = loaded.map { sizeFormatter.string(fromByteCount: $0.size) } ?? ""
        case .type:
            cell.label.stringValue = loaded?.path.fileExtension.uppercased() ?? ""
        case .duration:
            let seconds = loaded?.durationSeconds
            cell.label.stringValue = seconds.map { TileArtwork.format(Int($0)) } ?? ""
        }
        return cell
    }

    private func makeCell(_ column: ListColumn, identifier: NSUserInterfaceItemIdentifier) -> ListCell {
        let isNumeric = column == .size || column == .duration
        let cell = ListCell(hasThumbnail: column == .name, alignment: isNumeric ? .right : .left)
        cell.identifier = identifier
        return cell
    }

    private func configureThumbnail(_ cell: ListCell, row: Int) {
        let asset = result.assetIDs[row]
        let assetID = AssetID(rawValue: asset)
        var color: CGColor?
        if result.flags[row].contains(.hasColor) {
            let value = result.colors[row]
            color = CGColor(
                srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let cached = loader.cache.nearest(asset: assetID, wanted: .small)
        cell.show(asset: asset, thumbnail: cached, placeholder: color)
        guard cached == nil, !result.flags[row].contains(.video) else { return }
        loader.request(
            ThumbnailRequest(
                asset: assetID, instance: FileInstanceID(rawValue: result.instanceIDs[row]), wanted: .small,
                priority: .visible))
        requestTick()
    }

    private func date(_ row: BrowseRow) -> String {
        let date = row.captureDate.map { Date(timeIntervalSince1970: Double($0.wallClockMilliseconds) / 1000) }
        return dateFormatter.string(
            from: date ?? Date(timeIntervalSince1970: Double(row.modifiedTime.nanoseconds) / 1e9))
    }

    /// A row scrolled away, so its thumbnail isn't needed. Holding an arrow key skips rows this way.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        if let cell = rowView.view(atColumn: 0) as? ListCell, cell.assetID != 0 {
            loader.cancel(AssetID(rawValue: cell.assetID))
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let rows = table.selectedRowIndexes
        // A click makes the clicked row current. Otherwise it's the last row selected.
        let clicked = table.clickedRow
        let current = clicked >= 0 && rows.contains(clicked) ? clicked : rows.last
        model.adoptSelection(rows: rows, current: current)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let raw = descriptor.key,
            let key = SortKey(rawValue: raw)
        else { return }
        model.setSort(BrowseSort(key: key, ascending: descriptor.ascending))
    }
}
