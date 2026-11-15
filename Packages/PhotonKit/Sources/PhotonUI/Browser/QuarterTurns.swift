import AppKit
import CoreImage
import QuartzCore

/// Non-destructive rotation, applied where a picture is shown. Thumbnails and decoded images stay as
/// they were made, upright by their own orientation, and a layer turns them. So a rotation costs no
/// decoding, and changing it shows at once. See docs/PLAN.md, under Rotation.
///
/// Every layer here lives in a flipped view, with y pointing down, where a positive angle is clockwise.
enum QuarterTurns {
    static func normalized(_ turns: Int) -> Int { (turns % 4 + 4) % 4 }

    static func transform(_ turns: Int) -> CATransform3D {
        let turns = normalized(turns)
        return turns == 0 ? CATransform3DIdentity : CATransform3DMakeRotation(CGFloat(turns) * .pi / 2, 0, 0, 1)
    }

    /// The size a picture of `size` shows at, turned.
    static func turned(_ size: CGSize, _ turns: Int) -> CGSize { unturned(size, turns) }

    /// The size of the picture before turning, for one that shows at `size` after.
    static func unturned(_ size: CGSize, _ turns: Int) -> CGSize {
        normalized(turns) % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    /// Places `layer`, turned, so that it covers `rect` in its superlayer. A turned layer's frame can't
    /// be assigned, so this sets bounds and position. A frame read back afterwards is `rect`.
    static func place(_ layer: CALayer, in rect: CGRect, turns: Int) {
        layer.transform = transform(turns)
        layer.bounds = CGRect(origin: .zero, size: unturned(rect.size, turns))
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// An image of `contents` turned, for a drag image, which AppKit draws without layer transforms.
    /// Nil when it can't be made, and `contents` itself when nothing is turned.
    @MainActor
    static func image(_ contents: Any?, turns: Int) -> Any? {
        let turns = normalized(turns)
        guard turns != 0, let contents else { return contents }
        let image: CIImage
        if CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            image = CIImage(ioSurface: unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self))
        } else if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            image = CIImage(cgImage: unsafeBitCast(contents as AnyObject, to: CGImage.self))
        } else {
            return nil
        }
        // Core Image's y points up, so clockwise there is a negative angle.
        let turned = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        let moved = turned.transformed(
            by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
        let representation = NSCIImageRep(ciImage: moved)
        let result = NSImage(size: representation.size)
        result.addRepresentation(representation)
        return result
    }
}
