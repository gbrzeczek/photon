import AppKit
import PhotonCore
import PhotonMedia

/// One tile. Overrides the action lookup, so that a change never starts an implicit animation.
final class TileLayer: CALayer {
    var row = 0
    var assetID: Int64 = 0
    var shownTier: ThumbnailTier?
    var isVideo = false
    var showsSelection = false
    /// The update pass that last saw this tile.
    var stamp = 0
    private var badge: CALayer?
    /// Favorite and stack symbols, at the bottom leading corner.
    private var mark: CALayer?
    private(set) var markKey = 0

    override func action(forKey event: String) -> (any CAAction)? { nil }

    func setBadge(_ image: CGImage?, scale: CGFloat) {
        guard let image else {
            badge?.isHidden = true
            return
        }
        let badge = badge ?? makeBadge()
        badge.contents = image
        badge.contentsScale = scale
        badge.isHidden = false
        badge.bounds.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        placeBadge()
    }

    func placeBadge() {
        if let mark, !mark.isHidden {
            mark.position = CGPoint(x: bounds.minX + mark.bounds.width / 2 + 4, y: bounds.maxY - mark.bounds.height / 2 - 4)
        }
        guard let badge, !badge.isHidden else { return }
        badge.position = CGPoint(
            x: bounds.maxX - badge.bounds.width / 2 - 4, y: bounds.maxY - badge.bounds.height / 2 - 4)
    }

    /// `key` says which image this is, so an unchanged mark costs nothing.
    func setMark(_ image: CGImage?, key: Int, scale: CGFloat) {
        guard key != markKey || image == nil else { return }
        markKey = image == nil ? 0 : key
        guard let image else {
            mark?.isHidden = true
            return
        }
        let layer = mark ?? {
            let layer = PlainLayer()
            addSublayer(layer)
            mark = layer
            return layer
        }()
        layer.contents = image
        layer.contentsScale = scale
        layer.isHidden = false
        layer.bounds.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        placeBadge()
    }

    private func makeBadge() -> CALayer {
        let layer = PlainLayer()
        addSublayer(layer)
        badge = layer
        return layer
    }
}

/// A layer that never animates on its own.
final class PlainLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

/// Small pre-rendered images, shared by every tile: the video symbol and duration labels.
@MainActor
final class TileArtwork {
    private var durations: [Int: CGImage] = [:]
    private var videoSymbol: CGImage?
    private var scale: CGFloat = 2

    func setScale(_ scale: CGFloat) {
        guard scale != self.scale else { return }
        self.scale = scale
        reset()
    }

    func reset() {
        durations.removeAll()
        videoSymbol = nil
        marks.removeAll()
    }

    private var marks: [Int: CGImage] = [:]

    /// Which mark a row needs: a favorite's heart and a collapsed stack's symbol. Zero for none.
    static func markKey(_ flags: BrowseResult.Flags) -> Int {
        (flags.contains(.favorite) ? 1 : 0) | (flags.contains(.livePhoto) ? 2 : 0) | (flags.contains(.rawPair) ? 4 : 0)
    }

    /// White symbols with a soft shadow, so that they read over any picture, as in Photos.
    func mark(key: Int) -> CGImage? {
        guard key != 0 else { return nil }
        if let existing = marks[key] { return existing }
        var names: [String] = []
        if key & 1 != 0 { names.append("heart.fill") }
        if key & 2 != 0 { names.append("livephoto") }
        if key & 4 != 0 { names.append("square.stack.fill") }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let symbols = names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        guard !symbols.isEmpty else { return nil }
        let gap: CGFloat = 4
        let inset: CGFloat = 3
        let width = symbols.reduce(0) { $0 + $1.size.width } + gap * CGFloat(symbols.count - 1) + inset * 2
        let height = (symbols.map(\.size.height).max() ?? 0) + inset * 2
        guard
            let context = CGContext(
                data: nil, width: Int(ceil(width * scale)), height: Int(ceil(height * scale)), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.7))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var x = inset
        for symbol in symbols {
            let rect = CGRect(x: x, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
            let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                NSColor.white.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            x += symbol.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()
        marks[key] = image
        return image
    }

    /// The film symbol, for a video with no frame yet, or none for its format.
    func videoPlaceholder(appearance: NSAppearance) -> CGImage? {
        if let videoSymbol { return videoSymbol }
        var result: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
            guard
                let symbol = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            else { return }
            let size = symbol.size
            guard
                let context = CGContext(
                    data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let rect = CGRect(origin: .zero, size: size)
            symbol.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
            result = context.makeImage()
        }
        videoSymbol = result
        return result
    }

    /// A duration label on a dark capsule, so that it reads over any picture.
    func durationBadge(seconds: Int) -> CGImage? {
        if let existing = durations[seconds] { return existing }
        if durations.count > 512 { durations.removeAll() }
        let text = Self.format(seconds)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let size = CGSize(width: ceil(textSize.width) + 10, height: ceil(textSize.height) + 4)
        guard
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0, alpha: 0.6))
        context.addPath(
            CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        string.draw(at: CGPoint(x: 5, y: 2))
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()
        durations[seconds] = image
        return image
    }

    static func format(_ seconds: Int) -> String {
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
