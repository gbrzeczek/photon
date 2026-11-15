import AppKit
import PhotonCore
import PhotonVideo
import QuartzCore

/// Plays a video in its tile while the pointer rests on it, muted and looping, as Photos does.
///
/// Only one plays at a time, and only after the pointer has rested, so moving the mouse across the grid
/// opens nothing. It starts from the poster frame, which is what the tile already shows, and the player's
/// layer only appears once that frame is ready, so the tile never jumps or flashes. Anything that moves
/// the grid or the current item stops it. Reads go through the volume's scheduler, like the viewer's,
/// and an offline video simply doesn't play.
@MainActor
final class TileVideoPreview {
    private let engines: VideoEngines
    private let lookup: ViewerVideo.SourceLookup
    private(set) var asset: AssetID?
    private weak var tile: TileLayer?
    private(set) var playback: (any VideoPlayback)?
    private var startTask: Task<Void, Never>?
    private var hasStarted = false
    private var source: VideoSource?
    private var fallbacks: [any VideoEngine] = []

    /// How long the pointer must rest before anything is read.
    var delay: Duration = .milliseconds(600)
    /// Reduce Motion turns previews off. Tests set this rather than rely on the machine.
    var reducesMotionForTesting: Bool?
    private var reducesMotion: Bool {
        reducesMotionForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(engines: VideoEngines, lookup: @escaping ViewerVideo.SourceLookup) {
        self.engines = engines
        self.lookup = lookup
    }

    /// Whether a preview is showing frames in its tile.
    var isPlaying: Bool {
        guard let playback else { return false }
        return !playback.layer.isHidden && playback.rate != 0
    }

    /// The pointer is over `tile`, which shows a video. A pointer still on the same tile changes nothing.
    func hover(asset: AssetID, instance: FileInstanceID, tile: TileLayer) {
        guard asset != self.asset || tile !== self.tile else { return }
        stop()
        guard !reducesMotion else { return }
        self.asset = asset
        self.tile = tile
        let lookup = lookup
        let delay = delay
        startTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let source = await lookup(instance)
            guard !Task.isCancelled, let self, self.asset == asset, let source else { return }
            let candidates = self.engines.candidates(for: source.fileExtension)
            guard let engine = candidates.first else { return }
            self.startTask = nil
            self.source = source
            self.fallbacks = Array(candidates.dropFirst())
            self.attach(engine.makePlayback(for: source))
        }
    }

    private func attach(_ playback: any VideoPlayback) {
        guard let tile else {
            playback.close()
            return
        }
        self.playback = playback
        playback.isMuted = true
        playback.loops = true
        playback.fillsBounds = true
        let layer = playback.layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        layer.frame = tile.bounds
        layer.cornerRadius = tile.cornerRadius
        layer.masksToBounds = true
        // Under the badge and the marks, which are the tile's other sublayers.
        tile.insertSublayer(layer, at: 0)
        CATransaction.commit()
        playback.onChange = { [weak self] in self?.changed() }
    }

    private func changed() {
        guard let playback else { return }
        switch playback.status {
        case .loading:
            return
        case .unsupported:
            if let source, !fallbacks.isEmpty {
                let next = fallbacks.removeFirst()
                playback.onChange = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                playback.layer.isHidden = true
                playback.layer.removeFromSuperlayer()
                CATransaction.commit()
                playback.close()
                self.playback = nil
                attach(next.makePlayback(for: source))
                return
            }
            stop()
        case .unavailable:
            stop()
        case .ready:
            if !hasStarted {
                hasStarted = true
                playback.seek(to: VideoPoster.time(duration: playback.duration), exact: false) { [weak self] finished in
                    guard finished, let self, let playback = self.playback else { return }
                    self.landedAt = playback.currentTime
                    playback.play(rate: 1)
                }
            }
            revealIfShowingNewFrame()
        }
    }

    /// Where the seek to the poster frame landed, once it has.
    private var landedAt: Double?

    /// A finished seek doesn't mean its frame is on screen: the layer can still be empty, which draws
    /// black, or showing the first frame, which often is black. So the layer stays hidden over the
    /// thumbnail until a frame is ready and playback has moved past where the seek landed.
    private func revealIfShowingNewFrame() {
        guard let playback, playback.layer.isHidden, let landedAt, playback.isShowingFrame,
            playback.rate != 0, playback.currentTime != landedAt
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playback.layer.isHidden = false
        CATransaction.commit()
    }

    /// The tile moved, so the layer follows. Tiles change size only on zoom, which stops the preview,
    /// but a window resize can still reflow them.
    func tileDidResize() {
        guard let tile, let layer = playback?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = tile.bounds
        CATransaction.commit()
    }

    /// The grid reloaded, and the video is in `tile` now, or has gone.
    func reattach(to tile: TileLayer?) {
        guard asset != nil else { return }
        guard let tile else {
            stop()
            return
        }
        guard tile !== self.tile else { return }
        self.tile = tile
        guard let layer = playback?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.insertSublayer(layer, at: 0)
        layer.frame = tile.bounds
        CATransaction.commit()
    }

    /// Whether this tile is the one previewing, so that recycling it stops the preview.
    func owns(_ tile: TileLayer) -> Bool { self.tile === tile }

    func stop() {
        startTask?.cancel()
        startTask = nil
        if let playback {
            // Off the tile before the player lets go of it, so an emptied layer never shows.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playback.layer.isHidden = true
            playback.layer.removeFromSuperlayer()
            CATransaction.commit()
            playback.close()
        }
        playback = nil
        asset = nil
        tile = nil
        source = nil
        fallbacks = []
        hasStarted = false
        landedAt = nil
    }
}
