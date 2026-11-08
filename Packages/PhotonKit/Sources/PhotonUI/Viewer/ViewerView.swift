import AppKit
import PhotonCore
import PhotonIndex
import PhotonMedia
import QuartzCore
import os

/// An `IOSurface` is safe to hand between threads, but isn't marked as such.
private struct UncheckedSurface: @unchecked Sendable {
    let surface: IOSurface
}

/// What the viewer asks of the browser beneath it.
@MainActor
protocol ViewerHost: AnyObject {
    /// The row under the viewer, in the browser's current result.
    var viewerRow: Int? { get }
    var viewerResult: BrowseResult { get }
    /// Where a row is on screen, in the viewer's coordinates. Nil if it isn't showing.
    func viewerRect(row: Int) -> CGRect?
    /// Hides a tile while its photo flies to or from it. Nil shows it again.
    func viewerHideTile(row: Int?)
    func viewerDidFinishClosing()
    func viewerStatusDidChange(_ status: String)
    /// The photo showing has stayed long enough to name, which a held key's skipped photos don't.
    func viewerDidSettle(row: Int)
    func viewerKey(_ event: NSEvent) -> Bool
    func viewerContextMenu() -> NSMenu
    func viewerBeginDrag(event: NSEvent, frame: CGRect, contents: Any?)
    func viewerPrepareDrag()
    func viewerSwipe(_ direction: Int)
    /// What the status bar says while a slow read is under way.
    var viewerWaitingText: String { get }
}

/// The photo viewer: an overlay above the grid and list, which stay alive underneath.
///
/// The picture is one layer, whose contents move through the thumbnail, the preview and full resolution
/// without changing its geometry. Everything that moves here moves by assigning a frame, and the two
/// transitions run in Core Animation, so they don't depend on the main thread.
@MainActor
final class ViewerView: NSView, NSDraggingSource {
    private let thumbnails: ThumbnailLoader
    private let images: ViewerImageLoader
    private let artwork = TileArtwork()
    private let backdrop = PlainLayer()
    private let picture = CALayer()
    private let videoSymbol = PlainLayer()
    private let flightClip = PlainLayer()
    private let flightPicture = PlainLayer()

    private(set) var isOpen = false
    /// Between Escape and the last frame of the flight back.
    private var isClosing = false
    private var isFlying = false
    /// Tells a flight that was replaced from the one in the air.
    private var flightID = 0
    private var item: ViewerItem?
    private var row = 0
    private var isVideo = false
    private var geometry = ViewerGeometry(viewport: .zero, imageSize: .zero, backingScale: 2)
    private var shownSurface: IOSurface?
    private var shownTier: ShownTier = .none
    private var neighborDirection = 1
    private var settleTask: Task<Void, Never>?
    private var fullTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var isWaitingLong = false
    /// How long a read can take before it's worth saying so.
    private static let waitDelay: Duration = .seconds(1)
    private var pan: (start: CGPoint, last: CGPoint)?
    private var dragPress: CGPoint?
    private var scrollSwipe: CGFloat = 0
    /// Where a scroll is zooming to. Each frame moves part of the way, around the same point.
    private var scrollZoom: (target: CGFloat, anchor: CGPoint, lastFrame: TimeInterval?)?
    private lazy var zoomTicker = FrameTicker { [weak self] time in self?.stepScrollZoom(at: time) ?? false }

    weak var host: (any ViewerHost)?

    private enum ShownTier: Int, Comparable {
        case none, thumbnail, preview, full
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How long a held arrow key must rest before the disk is touched. A long enough gap between
    /// repeats counts as resting, and the default repeat is 83 ms.
    private static let settleDelay: Duration = .milliseconds(120)
    /// A photo that stays this long goes on to full resolution, so that zooming in finds it ready.
    private static let fullDelay: Duration = .milliseconds(300)
    private static let flightDuration: CFTimeInterval = 0.26
    private static let fadeDuration: CFTimeInterval = 0.16
    private static let panStep: CGFloat = 96
    private static let swipeDistance: CGFloat = 60
    private static let flightTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    nonisolated private static let signposter = OSSignposter(subsystem: "app.photon", category: "Viewer")

    /// Timings for the measuring harness. Nil unless it's running.
    var frameObserver: ((Double) -> Void)?
    /// Milliseconds from arriving at a photo to its preview showing, for the measuring harness.
    var sharpObserver: ((Double) -> Void)?
    private var arrivedAt: UInt64 = 0

    init(thumbnails: ThumbnailLoader, images: ViewerImageLoader) {
        self.thumbnails = thumbnails
        self.images = images
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        isHidden = true
        layer?.masksToBounds = true

        layer?.addSublayer(backdrop)
        picture.contentsGravity = .resize
        picture.magnificationFilter = .linear
        picture.minificationFilter = .linear
        picture.actions = ["contents": NSNull()]
        // Only contents tagged with headroom use it, so SDR photos look the same as anywhere else.
        picture.preferredDynamicRange = .high
        layer?.addSublayer(picture)
        videoSymbol.contentsGravity = .center
        layer?.addSublayer(videoSymbol)
        flightClip.masksToBounds = true
        flightClip.isHidden = true
        flightPicture.contentsGravity = .resize
        flightClip.addSublayer(flightPicture)
        layer?.addSublayer(flightClip)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("photon.viewer")

        images.onImage = { [weak self] asset in
            guard asset == self?.item?.asset else { return }
            self?.refreshPicture()
            self?.applyStatus()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }

    /// AppKit can ask from a worker thread while it sets up a drag.
    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var reducesMotion: Bool {
        reducesMotionForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isOpen && !isClosing ? super.hitTest(point) : nil
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            backdrop.frame = bounds
            geometry.viewport = bounds.size
            geometry.backingScale = scale
            geometry.clampCenter()
            placePicture()
        }
    }

    /// A larger viewer needs a larger preview, which keeps the bytes it was made from if it can.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        zoomTicker.invalidate()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard isOpen, !isClosing else { return }
        requestImages(wantsFull: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        artwork.reset()
        withoutAnimation {
            applyBackdropColor()
            if isOpen, isVideo { showVideoSymbol() }
        }
    }

    private func applyBackdropColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backdrop.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Opening and closing

    /// Starts showing `row`, flying from the tile when there is one.
    func open(row: Int) {
        guard let host else { return }
        finishFlight()
        isOpen = true
        isClosing = false
        isHidden = false
        artwork.setScale(scale)
        window?.makeFirstResponder(self)
        withoutAnimation {
            applyBackdropColor()
            backdrop.frame = bounds
            geometry = ViewerGeometry(viewport: bounds.size, imageSize: .zero, backingScale: scale)
        }
        show(row: row, isRepeat: false)
        startOpeningTransition(from: host.viewerRect(row: row))
    }

    private func startOpeningTransition(from tile: CGRect?) {
        guard let tile, !reducesMotion, !isVideo, let surface = shownSurface else {
            fade(backdrop, from: 0, to: 1)
            fade(picture, from: 0, to: 1)
            fade(videoSymbol, from: 0, to: 1)
            return
        }
        host?.viewerHideTile(row: row)
        let target = geometry.frame
        isFlying = true
        withoutAnimation {
            picture.isHidden = true
            flightClip.isHidden = false
            flightPicture.contents = surface
            flightClip.frame = target
            flightPicture.frame = CGRect(origin: .zero, size: target.size)
        }
        let aspect = target.height > 0 ? target.width / target.height : 1
        let from = ViewerTransition.filled(tile, aspect: aspect)
        fade(backdrop, from: 0, to: 1, duration: Self.flightDuration)
        flightID += 1
        let id = flightID
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                if id == self?.flightID { self?.openingFlightEnded() }
            }
        }
        fly(
            clip: (tile, target),
            picture: (from.offsetBy(dx: -tile.minX, dy: -tile.minY), CGRect(origin: .zero, size: target.size)))
        CATransaction.commit()
    }

    private func openingFlightEnded() {
        guard isFlying, !isClosing else { return }
        finishFlight()
        host?.viewerHideTile(row: nil)
    }

    /// Stops any flight and shows what's underneath it.
    private func finishFlight() {
        isFlying = false
        flightID += 1
        withoutAnimation {
            flightClip.removeAllAnimations()
            flightPicture.removeAllAnimations()
            backdrop.removeAllAnimations()
            flightClip.isHidden = true
            flightPicture.contents = nil
            picture.isHidden = isVideo
        }
    }

    /// Goes back to the browser, which has already moved to `tile` if it could.
    func close(to tile: CGRect?, animated: Bool) {
        guard isOpen else { return }
        isOpen = false
        isClosing = true
        scrollZoom = nil
        settleTask?.cancel()
        fullTask?.cancel()
        images.focus(current: nil, neighbors: [], wantsFull: false)

        guard animated, !reducesMotion, !isVideo, shownSurface != nil, let tile else {
            guard animated else {
                finishClosing()
                return
            }
            startClosingFade()
            return
        }
        host?.viewerHideTile(row: row)
        let start = isFlying ? (flightClip.presentation()?.frame ?? flightClip.frame) : visiblePictureRect
        let startPicture = isFlying
            ? (flightPicture.presentation()?.frame ?? flightPicture.frame)
            : geometry.frame.offsetBy(dx: -start.minX, dy: -start.minY)
        let surface = shownSurface
        finishFlight()
        isFlying = true
        withoutAnimation {
            picture.isHidden = true
            flightClip.isHidden = false
            flightPicture.contents = surface
            flightClip.frame = tile
            let aspect = geometry.imageSize.height > 0 ? geometry.imageSize.width / geometry.imageSize.height : 1
            flightPicture.frame = ViewerTransition.filled(tile, aspect: aspect).offsetBy(dx: -tile.minX, dy: -tile.minY)
        }
        fade(backdrop, from: 1, to: 0, duration: Self.flightDuration)
        flightID += 1
        let id = flightID
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                if id == self?.flightID { self?.finishClosing() }
            }
        }
        fly(clip: (start, tile), picture: (startPicture, flightPicture.frame))
        CATransaction.commit()
    }

    private func startClosingFade() {
        withoutAnimation { videoSymbol.opacity = 0 }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finishClosing() }
        }
        fade(backdrop, from: 1, to: 0)
        fade(picture, from: 1, to: 0)
        CATransaction.commit()
    }

    /// The part of the photo that's in the viewport.
    private var visiblePictureRect: CGRect { geometry.frame.intersection(bounds) }

    private func finishClosing() {
        guard isClosing else { return }
        isClosing = false
        isFlying = false
        isHidden = true
        withoutAnimation {
            flightClip.removeAllAnimations()
            flightPicture.removeAllAnimations()
            flightClip.isHidden = true
            flightPicture.contents = nil
            backdrop.removeAllAnimations()
            backdrop.opacity = 1
            picture.removeAllAnimations()
            picture.opacity = 1
            picture.contents = nil
            picture.isHidden = false
            videoSymbol.contents = nil
            videoSymbol.opacity = 1
        }
        shownSurface = nil
        shownTier = .none
        item = nil
        images.reset()
        host?.viewerHideTile(row: nil)
        host?.viewerDidFinishClosing()
    }

    private func fly(clip: (from: CGRect, to: CGRect), picture: (from: CGRect, to: CGRect)) {
        move(flightClip, from: clip.from, to: clip.to)
        move(flightPicture, from: picture.from, to: picture.to)
    }

    private func move(_ layer: CALayer, from: CGRect, to: CGRect) {
        let group = CAAnimationGroup()
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        position.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: to.size))
        group.animations = [position, bounds]
        group.duration = Self.flightDuration
        group.timingFunction = Self.flightTiming
        layer.add(group, forKey: "flight")
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval = fadeDuration) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = to
        layer.add(animation, forKey: "fade")
    }

    // MARK: Showing a photo

    /// Moves to a row at once, with whatever's already in memory. The disk waits until a held key lets
    /// go, so that a skipped photo never costs a read.
    func show(row: Int, isRepeat: Bool, direction: Int = 1) {
        guard let host, row < host.viewerResult.count else { return }
        let interval = Self.signposter.beginInterval("Show")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            Self.signposter.endInterval("Show", interval)
            frameObserver?(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let result = host.viewerResult
        let next = viewerItem(row: row, in: result)
        let previous = item
        scrollZoom = nil
        if let shownSurface { ViewerImageLoader.releaseLater(UncheckedSurface(surface: shownSurface)) }
        self.row = row
        arrivedAt = start
        neighborDirection = direction >= 0 ? 1 : -1
        if let previous, previous != next { thumbnails.cancel(previous.asset) }
        isVideo = result.flags[row].contains(.video)
        item = next
        shownSurface = nil
        shownTier = .none

        withoutAnimation {
            geometry.zoom = 1
            geometry.center = CGPoint(x: 0.5, y: 0.5)
            geometry.imageSize = placeholderSize(row: row, result: result)
            if isVideo {
                showVideoSymbol()
            } else {
                videoSymbol.contents = nil
                picture.isHidden = isFlying
            }
            refreshPicture()
            if shownSurface == nil { picture.contents = nil }
            placePicture()
        }

        if !isVideo { requestThumbnail(next) }
        updateAccessibility()
        settleTask?.cancel()
        fullTask?.cancel()
        if isRepeat {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled else { return }
                self?.settled()
            }
        } else {
            settled()
        }
    }

    private func placeholderSize(row: Int, result: BrowseResult) -> CGSize {
        let aspect = CGFloat(result.aspects[row])
        return CGSize(width: aspect > 0 ? aspect * 1000 : 1000, height: 1000)
    }

    private func requestThumbnail(_ item: ViewerItem) {
        guard thumbnails.cache.thumbnail(asset: item.asset, tier: .large) == nil else { return }
        thumbnails.request(
            ThumbnailRequest(
                asset: item.asset, instance: item.instance, wanted: .large, priority: .visible,
                generatesMissing: false))
    }

    /// The key has come to rest, so this photo and its neighbors can have the disk.
    private func settled() {
        isWaitingLong = false
        startWaitingForDisk()
        host?.viewerStatusDidChange(statusText)
        host?.viewerDidSettle(row: row)
        requestImages(wantsFull: false)
        fullTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fullDelay)
            guard !Task.isCancelled else { return }
            self?.requestImages(wantsFull: true)
        }
    }

    /// A sleeping drive can take seconds to wake, and the photo stays on its thumbnail meanwhile. The
    /// status bar says why, but only once the wait is long enough to notice.
    private func startWaitingForDisk() {
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.waitDelay)
            while !Task.isCancelled, let self, self.isOpen, let asset = self.item?.asset {
                let isWaiting = self.images.isLoading(asset) && self.shownTier < .preview
                if isWaiting != self.isWaitingLong {
                    self.isWaitingLong = isWaiting
                    self.applyStatus()
                }
                if !isWaiting { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// A volume came or went. The picture stays either way, and anything sharper that couldn't be read
    /// gets another try.
    func volumesDidChange() {
        guard isOpen else { return }
        images.retryUnavailable()
        settled()
    }

    private func viewerItem(row: Int, in result: BrowseResult) -> ViewerItem {
        ViewerItem(
            asset: AssetID(rawValue: result.assetIDs[row]), instance: FileInstanceID(rawValue: result.instanceIDs[row]),
            previewEdge: ViewerGeometry.fitEdge(
                aspect: CGFloat(result.aspects[row]), viewport: bounds.size, backingScale: scale))
    }

    private func requestImages(wantsFull: Bool) {
        guard let host else { return }
        let result = host.viewerResult
        guard row < result.count else { return }
        item = viewerItem(row: row, in: result)
        images.focus(
            current: isVideo ? nil : item, neighbors: neighbors(of: row, in: result), wantsFull: wantsFull)
    }

    /// The next two photos in the direction of travel, and one behind.
    private func neighbors(of row: Int, in result: BrowseResult) -> [ViewerItem] {
        [neighborDirection, 2 * neighborDirection, -neighborDirection].compactMap { offset in
            let next = row + offset
            guard next >= 0, next < result.count, !result.flags[next].contains(.video) else { return nil }
            return viewerItem(row: next, in: result)
        }
    }

    func thumbnailsReady() {
        guard isOpen, !isVideo, shownTier < .preview else { return }
        refreshPicture()
    }

    /// Shows the best image in memory for this zoom. Assigning it is all the main thread does.
    private func refreshPicture() {
        guard let item, !isVideo else { return }
        let found = images.images(for: item.asset)
        var choice: (surface: IOSurface, tier: ShownTier, size: CGSize)?
        if let preview = found.preview {
            choice = (preview.surface, preview.isFullResolution ? .full : .preview, Self.originalSize(preview))
            if let full = found.full, geometry.pixelsNeeded > preview.longEdge {
                choice = (full.surface, .full, Self.originalSize(full))
            }
        } else if let thumbnail = thumbnails.cache.nearest(asset: item.asset, wanted: .large), shownTier <= .thumbnail {
            choice = (thumbnail.surface, .thumbnail, CGSize(width: thumbnail.width, height: thumbnail.height))
        }
        guard let choice, choice.surface !== shownSurface else { return }
        if choice.tier >= .preview, shownTier < .preview, let sharpObserver {
            sharpObserver(Double(DispatchTime.now().uptimeNanoseconds - arrivedAt) / 1e6)
        }
        withoutAnimation {
            if let shownSurface { ViewerImageLoader.releaseLater(UncheckedSurface(surface: shownSurface)) }
            picture.contents = choice.surface
            shownSurface = choice.surface
            shownTier = choice.tier
            let size = choice.size
            geometry.imageSize = size
            geometry.clampCenter()
            placePicture()
        }
    }

    /// The original's size, whichever decoded size is showing, so that actual size means the original.
    private static func originalSize(_ image: ViewerImage) -> CGSize {
        let scale = CGFloat(image.originalLongEdge) / CGFloat(max(image.longEdge, 1))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private func showVideoSymbol() {
        picture.isHidden = true
        videoSymbol.contents = artwork.videoPlaceholder(appearance: effectiveAppearance)
        videoSymbol.contentsScale = scale
        videoSymbol.frame = bounds
    }

    private func placePicture() {
        let frame = geometry.frame
        // On whole device pixels at fit, so that a preview made for this size lands pixel for pixel.
        let placed = geometry.isZoomedIn ? frame : backingAlignedRect(frame, options: .alignAllEdgesNearest)
        picture.frame = frame.width > 0 ? placed : .zero
        picture.backgroundColor = shownSurface == nil ? placeholderColor : nil
    }

    private var placeholderColor: CGColor? {
        guard let result = host?.viewerResult, row < result.count, result.flags[row].contains(.hasColor) else {
            return NSColor.quaternaryLabelColor.cgColor
        }
        let color = result.colors[row]
        return CGColor(
            srgbRed: CGFloat(color >> 16 & 255) / 255, green: CGFloat(color >> 8 & 255) / 255,
            blue: CGFloat(color & 255) / 255, alpha: 1)
    }

    /// The browser moved under the viewer, as a re-sort or a change on disk can do.
    func resultDidChange() {
        guard isOpen, let host, let row = host.viewerRow else { return }
        let result = host.viewerResult
        if result.assetIDs[row] != item?.asset.rawValue {
            show(row: row, isRepeat: false)
        } else {
            self.row = row
            updateAccessibility()
            applyStatus()
            host.viewerDidSettle(row: row)
        }
    }

    private func applyStatus() { host?.viewerStatusDidChange(statusText) }

    /// Reads the position for VoiceOver, and gives UI tests something to check.
    private func updateAccessibility() {
        guard let host else { return }
        setAccessibilityLabel(isVideo ? "Video" : "Photo")
        let percent = Int((geometry.zoom * 100).rounded())
        setAccessibilityValue("Item \(row + 1) of \(host.viewerResult.count), zoom \(percent)%")
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private var statusText: String {
        guard let host else { return "" }
        let position = "\(row + 1) of \(host.viewerResult.count)"
        if isVideo { return "\(position)  ·  \(TileArtwork.format(Int(host.viewerResult.durations[row])))" }
        if isWaitingLong { return "\(position)  ·  \(host.viewerWaitingText)" }
        guard !isVideo, geometry.imageSize != .zero, shownTier >= .preview else { return position }
        let found = item.map { images.images(for: $0.asset) }
        let image = found?.full ?? found?.preview
        return image?.isHDR == true ? "\(position)  ·  HDR" : position
    }

    // MARK: Zooming and panning

    private func animate(_ body: () -> Void) {
        guard !reducesMotion else {
            withoutAnimation(body)
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        body()
        CATransaction.commit()
    }

    func zoom(larger: Bool) {
        guard isOpen, !isVideo else { return }
        setZoom(geometry.steppedZoom(larger: larger), keeping: nil, animated: true)
    }

    func zoomToFit() {
        guard isOpen, !isVideo else { return }
        setZoom(1, keeping: nil, animated: true)
    }

    private func setZoom(_ zoom: CGFloat, keeping point: CGPoint?, animated: Bool) {
        scrollZoom = nil
        applyZoom(zoom, keeping: point, animated: animated)
    }

    private func applyZoom(_ zoom: CGFloat, keeping point: CGPoint?, animated: Bool) {
        let apply = { [self] in
            geometry.setZoom(zoom, keeping: point)
            placePicture()
            refreshPicture()
        }
        if animated { animate(apply) } else { withoutAnimation(apply) }
        // A step past the preview before the delay is up shouldn't have to wait for it.
        if geometry.isZoomedIn { requestImages(wantsFull: true) }
        updateAccessibility()
        updateCursor()
    }

    /// Starts or extends a scroll's zoom. Notches add to where it's heading, not to where it's got to.
    private func zoomByScroll(factor: CGFloat, keeping point: CGPoint) {
        let target = geometry.clampedZoom((scrollZoom?.target ?? geometry.zoom) * factor)
        guard !reducesMotion else {
            setZoom(target, keeping: point, animated: false)
            return
        }
        scrollZoom = (target, point, scrollZoom?.lastFrame)
        zoomTicker.start(in: self)
    }

    /// One frame of a scroll's zoom. Returns whether there's more to do.
    private func stepScrollZoom(at time: TimeInterval) -> Bool {
        guard let zoom = scrollZoom else { return false }
        let elapsed = zoom.lastFrame.map { time - $0 } ?? 1.0 / 120
        let next = ViewerGeometry.easedZoom(
            from: geometry.zoom, to: zoom.target, elapsed: min(elapsed, ViewerGeometry.longestEaseFrame))
        applyZoom(next, keeping: zoom.anchor, animated: false)
        guard next != zoom.target else {
            scrollZoom = nil
            return false
        }
        scrollZoom?.lastFrame = time
        return true
    }

    /// Moves with an arrow key. Returns false when there's no zoom to pan within.
    func pan(dx: Int, dy: Int) -> Bool {
        guard isOpen, geometry.isZoomedIn else { return false }
        animate {
            geometry.pan(by: CGSize(width: CGFloat(dx) * Self.panStep, height: CGFloat(dy) * Self.panStep))
            placePicture()
        }
        return true
    }

    private func updateCursor() { window?.invalidateCursorRects(for: self) }

    override func resetCursorRects() {
        guard isOpen, geometry.isZoomedIn else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        if host?.viewerKey(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        scrollZoom = nil
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            setZoom(geometry.toggledZoom, keeping: point, animated: true)
            return
        }
        if geometry.isZoomedIn {
            pan = (point, point)
            NSCursor.closedHand.push()
        } else if isVideo || geometry.frame.contains(point) {
            dragPress = point
            host?.viewerPrepareDrag()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let current = pan {
            withoutAnimation {
                geometry.pan(by: CGSize(width: point.x - current.last.x, height: point.y - current.last.y))
                placePicture()
            }
            pan?.last = point
        } else if let press = dragPress, hypot(point.x - press.x, point.y - press.y) >= 4 {
            let frame = isVideo ? CGRect(x: press.x - 32, y: press.y - 32, width: 64, height: 64) : geometry.frame
            host?.viewerBeginDrag(event: event, frame: frame, contents: shownSurface ?? videoSymbol.contents)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragPress = nil
        if pan != nil {
            pan = nil
            NSCursor.pop()
        }
    }

    func endDragTracking() { dragPress = nil }

    override func magnify(with event: NSEvent) {
        guard isOpen, !isVideo else { return }
        setZoom(
            geometry.zoom * (1 + event.magnification), keeping: convert(event.locationInWindow, from: nil),
            animated: false)
    }

    override func smartMagnify(with event: NSEvent) {
        guard isOpen, !isVideo else { return }
        setZoom(geometry.toggledZoom, keeping: convert(event.locationInWindow, from: nil), animated: true)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isOpen else { return }
        if Self.scrollZooms(event) {
            guard !isVideo, event.momentumPhase == [] else { return }
            let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            let factor = ViewerGeometry.scrollZoomFactor(delta: delta, isPrecise: event.hasPreciseScrollingDeltas)
            zoomByScroll(factor: factor, keeping: convert(event.locationInWindow, from: nil))
            return
        }
        if geometry.isZoomedIn {
            withoutAnimation {
                geometry.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                placePicture()
            }
            return
        }
        // A two-finger swipe moves between photos, once per swipe.
        if event.phase == .began { scrollSwipe = 0 }
        guard event.phase != [] else { return }
        if event.phase == .changed, scrollSwipe != .infinity {
            scrollSwipe += event.scrollingDeltaX
            if abs(scrollSwipe) >= Self.swipeDistance {
                let direction = scrollSwipe > 0 ? -1 : 1
                scrollSwipe = .infinity
                host?.viewerSwipe(direction)
            }
        }
    }

    /// A mouse wheel zooms, since a mouse has no pinch, and so does any scroll with Command or Option
    /// held. A trackpad's own scrolling pans and swipes. A wheel smoothed by a mouse utility is precise
    /// but has no phases, so it counts as a wheel too.
    private static func scrollZooms(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .option]).isEmpty { return true }
        return !event.hasPreciseScrollingDeltas || (event.phase == [] && event.momentumPhase == [])
    }

    override func menu(for event: NSEvent) -> NSMenu? { host?.viewerContextMenu() }

    // MARK: Measuring and testing

    func setZoomForMeasuring(_ zoom: CGFloat) { setZoom(zoom, keeping: nil, animated: false) }

    /// A wheel notch, by the same path a real one takes.
    func scrollForMeasuring(factor: CGFloat) {
        zoomByScroll(factor: factor, keeping: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func stepForMeasuring(pixelsPan: CGFloat) {
        withoutAnimation {
            geometry.pan(by: CGSize(width: pixelsPan, height: pixelsPan / 2))
            placePicture()
        }
    }

    var zoomForTesting: CGFloat { geometry.zoom }
    var isEasingZoomForTesting: Bool { scrollZoom != nil }
    /// Tests can't rely on the machine's setting. The hosted CI runners have Reduce Motion on.
    var reducesMotionForTesting: Bool?
    /// Runs a scroll's zoom out, since a test window has no display to drive it.
    func finishScrollZoomForTesting() {
        var time = 0.0
        while stepScrollZoom(at: time) { time += 1.0 / 120 }
    }
    var isShowingFullResolutionForTesting: Bool { shownTier == .full }
    var isShowingPreviewOrBetterForTesting: Bool { shownTier >= .preview }
    var hasPictureForTesting: Bool { shownSurface != nil }
    var pictureFrameForTesting: CGRect { picture.frame }
    var isFlyingForTesting: Bool { isFlying }
    var geometryForTesting: ViewerGeometry { geometry }
    func finishTransitionForTesting() {
        if isClosing {
            finishClosing()
        } else if isFlying {
            openingFlightEnded()
        }
    }
}
