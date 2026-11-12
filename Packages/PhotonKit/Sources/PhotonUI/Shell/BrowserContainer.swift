import AppKit
import PhotonMedia
import SwiftUI

/// Holds the grid, the list and the viewer over them. None of them is torn down when another shows, so
/// the grid keeps its tiles.
final class BrowserContainerView: NSView {
    let grid: TileGridView
    let list: BrowserListView
    let viewer: ViewerView
    let jumps = ScrollJumpOverlay()
    private let model: BrowserModel
    private let commands: BrowserCommandResponder
    private var hasLaidOut = false
    private var hasTakenFocus = false

    init(model: BrowserModel) {
        self.model = model
        grid = TileGridView(model: model)
        list = BrowserListView(model: model)
        let originals = model.library.originals
        let library = model.library
        viewer = ViewerView(
            thumbnails: library.loader,
            images: ViewerImageLoader(read: { try await originals.read($0, priority: $1) }),
            videos: library.videoEngines, videoSource: { await library.videoSource($0) })
        commands = BrowserCommandResponder(model: model)
        super.init(frame: .zero)
        grid.autoresizingMask = [.width, .height]
        list.autoresizingMask = [.width, .height]
        viewer.autoresizingMask = [.width, .height]
        addSubview(grid)
        addSubview(list)
        jumps.autoresizingMask = [.width, .height]
        addSubview(jumps)
        addSubview(viewer)
        jumps.onJump = { [weak model] bottom in model?.scrollToEdge(bottom: bottom) }
        jumps.onBack = { [weak model] in model?.goBack() }
        jumps.onBackExpired = { [weak model] in model?.forgetPlace() }
        model.onBackPlaceChange = { [weak self] canGoBack in self?.jumps.showBack(canGoBack) }
        for scrollView in [grid.scrollView, list.scrollView] {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(contentScrolled(_:)), name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
        }
        viewer.host = model
        model.viewer = viewer
        model.attach(grid: grid, list: list) { [weak self] in self?.show($0) }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        commands.install(in: window)
        guard window != nil, !hasTakenFocus else { return }
        hasTakenFocus = true
        DevelopmentHooks.placeWindow(of: self)
        // After this pass, or the window's own setup takes it back. Doing this any earlier can find no
        // window yet, and then the keyboard does nothing until the first click.
        DispatchQueue.main.async { [model] in model.active?.focus() }
    }

    override func layout() {
        super.layout()
        guard !hasLaidOut, bounds.width > 1 else { return }
        hasLaidOut = true
        // After this pass, once the grid and the list have laid out too.
        DispatchQueue.main.async { [model] in model.contentDidLayOut() }
    }

    /// Costs a comparison per scroll, never anything that grows with the library.
    @objc private func contentScrolled(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        let scrollView = model.viewMode == .tiles ? grid.scrollView : list.scrollView
        guard clip === scrollView.contentView, !model.isViewerOpen else { return }
        jumps.scrolled(
            top: clip.bounds.minY, height: clip.bounds.height, content: scrollView.documentView?.frame.height ?? 0)
    }

    func show(_ mode: BrowserViewMode) {
        jumps.hideAll()
        model.forgetPlace()
        grid.isHidden = mode != .tiles
        list.isHidden = mode != .list
        if mode == .list { list.didBecomeVisible() }
    }
}

struct BrowserContentRepresentable: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> BrowserContainerView {
        let view = BrowserContainerView(model: model)
        PerformanceHarness.attachIfRequested(to: view, model: model)
        DevelopmentHooks.scheduleSnapshot(of: view)
        DevelopmentHooks.scheduleViewer(model: model)
        DevelopmentHooks.scheduleInspector(model: model)
        DevelopmentHooks.scheduleHover(grid: view.grid)
        return view
    }

    func updateNSView(_ view: BrowserContainerView, context: Context) {}
}
