import AppKit
import SwiftUI

/// Holds the grid and the list. Neither is torn down when the other shows, so the grid keeps its tiles.
final class BrowserContainerView: NSView {
    let grid: TileGridView
    let list: BrowserListView
    private let model: BrowserModel
    private var hasLaidOut = false

    init(model: BrowserModel) {
        self.model = model
        grid = TileGridView(model: model)
        list = BrowserListView(model: model)
        super.init(frame: .zero)
        grid.autoresizingMask = [.width, .height]
        list.autoresizingMask = [.width, .height]
        addSubview(grid)
        addSubview(list)
        model.attach(grid: grid, list: list) { [weak self] in self?.show($0) }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    override func layout() {
        super.layout()
        guard !hasLaidOut, bounds.width > 1 else { return }
        hasLaidOut = true
        // After this pass, once the grid and the list have laid out too.
        DispatchQueue.main.async { [model] in model.contentDidLayOut() }
    }

    func show(_ mode: BrowserViewMode) {
        grid.isHidden = mode != .tiles
        list.isHidden = mode != .list
        if mode == .list { list.didBecomeVisible() }
    }
}

struct BrowserContentRepresentable: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> BrowserContainerView {
        let view = BrowserContainerView(model: model)
        DispatchQueue.main.async { [weak view] in
            view?.grid.focus()
        }
        DevelopmentHooks.placeWindow(of: view)
        PerformanceHarness.attachIfRequested(to: view, model: model)
        DevelopmentHooks.scheduleSnapshot(of: view)
        return view
    }

    func updateNSView(_ view: BrowserContainerView, context: Context) {}
}
