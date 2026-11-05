import AppKit

/// Option A: NSCollectionView with a custom layout on the shared geometry.
@MainActor final class SpikeLayout: NSCollectionViewLayout {
    let geometry: Geometry

    init(_ geometry: Geometry) {
        self.geometry = geometry
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var collectionViewContentSize: NSSize {
        NSSize(width: geometry.width, height: geometry.contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var out: [NSCollectionViewLayoutAttributes] = []
        geometry.forEach(in: rect) { index, frame in
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            attributes.frame = frame
            out.append(attributes)
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = geometry.frame(of: indexPath.item)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange bounds: NSRect) -> Bool {
        bounds.width != geometry.width
    }
}

@MainActor final class TileItem: NSCollectionViewItem {
    nonisolated static let identifier = NSUserInterfaceItemIdentifier("tile")
    var index = -1

    override func loadView() {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layerContentsRedrawPolicy = .never
        tile.layer?.contentsGravity = .resizeAspectFill
        tile.layer?.masksToBounds = true
        view = tile
    }

    func show(color: CGColor, image: AnyObject?, current: Bool) {
        let layer = view.layer!
        layer.backgroundColor = color
        layer.contents = image
        mark(current)
    }

    func mark(_ current: Bool) {
        view.layer!.borderWidth = current ? 3 : 0
        view.layer!.borderColor = NSColor.controlAccentColor.cgColor
    }
}

final class KeyCollectionView: NSCollectionView {
    var onKey: ((NSEvent) -> Bool)?
    /// Experiment: stop AppKit preparing items outside the visible rect.
    var tightPrepare = false
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: tightPrepare ? visibleRect : rect)
    }
}

@MainActor final class CollectionGrid: NSObject, GridBackend, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let state: GridState
    let scrollView = NSScrollView()
    let collection = KeyCollectionView()
    let layout: SpikeLayout
    var keyView: NSView { collection }

    init(state: GridState) {
        self.state = state
        layout = SpikeLayout(state.geometry)
        super.init()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = false
        collection.backgroundColors = [.windowBackgroundColor]
        collection.register(TileItem.self, forItemWithIdentifier: TileItem.identifier)
        collection.onKey = { [unowned state] in state.handle($0) }
        scrollView.documentView = collection
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
    }

    func reload() { collection.reloadData() }

    func relayout() {
        layout.invalidateLayout()
        collection.layoutSubtreeIfNeeded()
    }

    func deliver(_ index: Int, image: AnyObject) {
        guard let item = collection.item(at: IndexPath(item: index, section: 0)) as? TileItem, item.index == index else { return }
        item.view.layer?.contents = image
    }

    func currentChanged(from old: Int, to new: Int) {
        (collection.item(at: IndexPath(item: old, section: 0)) as? TileItem)?.mark(false)
        (collection.item(at: IndexPath(item: new, section: 0)) as? TileItem)?.mark(true)
    }

    var visibleTileCount: Int { collection.visibleItems().count }

    func collectionView(_ view: NSCollectionView, numberOfItemsInSection section: Int) -> Int { state.count }

    func collectionView(_ view: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let item = view.makeItem(withIdentifier: TileItem.identifier, for: path) as! TileItem
        item.index = path.item
        item.show(color: state.color(path.item), image: state.image(path.item), current: path.item == state.current)
        state.want(path.item)
        return item
    }

    func collectionView(_ view: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt path: IndexPath) {
        state.decoder.cancel(path.item)
    }
}
