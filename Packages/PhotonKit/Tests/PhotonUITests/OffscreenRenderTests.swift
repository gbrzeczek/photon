import AppKit
import SwiftUI
import CoreImage
import Foundation
import ImageIO
import Metal
import PhotonCore
import PhotonMedia
import QuartzCore
import Testing
import UniformTypeIdentifiers

@testable import PhotonUI

/// Renders the grid's real layer tree with `CARenderer` and saves PNGs, to see tiles with no display.
/// It only runs when asked, because CI's GPU can't be relied on: set `PHOTON_RENDER_LIBRARY` to a seeded
/// library and `PHOTON_RENDER_OUT` to a folder, or `PHOTON_RENDER_CHECKS` for the orientation check.
@Suite("Offscreen rendering", .serialized)
@MainActor
struct OffscreenRenderTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment

    @Test(
        "Render the sidebar and inspector in both appearances",
        .enabled(if: environment["PHOTON_RENDER_LIBRARY"] != nil))
    func renderShell() async throws {
        _ = NSApplication.shared
        let library = URL(fileURLWithPath: try #require(Self.environment["PHOTON_RENDER_LIBRARY"]))
        let output = URL(fileURLWithPath: try #require(Self.environment["PHOTON_RENDER_OUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let handle = try await Task.detached { try BrowserLibrary.open(url: library) }.value
        let browserLibrary = BrowserLibrary(handle)
        await browserLibrary.start()
        let model = BrowserModel(library: browserLibrary)
        _ = await model.restoreLastSession()
        let first = try await browserLibrary.store.browse(.favorites, sort: .default).assetIDs.first
        model.inspect(first.map(AssetID.init(rawValue:)), immediately: true)
        for dark in [false, true] {
            let root = HStack(spacing: 0) {
                LibrarySidebar(library: browserLibrary, model: model) { _ in }.frame(width: 240)
                Divider()
                InspectorView(library: browserLibrary, model: model).frame(width: 300)
            }
            .frame(width: 541, height: 760)
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 541, height: 760), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = view.appearance
            window.contentView = view
            for _ in 0..<20 {
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appending(path: dark ? "shell-dark.png" : "shell-light.png"))
            window.close()
        }
        browserLibrary.loader.stop()
    }

    @Test(
        "Render the grid in both appearances and layouts",
        .enabled(if: environment["PHOTON_RENDER_LIBRARY"] != nil))
    func render() async throws {
        _ = NSApplication.shared
        let library = URL(fileURLWithPath: try #require(Self.environment["PHOTON_RENDER_LIBRARY"]))
        let output = URL(fileURLWithPath: try #require(Self.environment["PHOTON_RENDER_OUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, dark, aspect, tile) in [
            ("square-light", false, false, 160.0), ("square-dark", true, false, 160.0),
            ("aspect-light", false, true, 200.0), ("aspect-dark", true, true, 200.0), ("large-dark", true, false, 380.0),
        ] {
            let handle = try await Task.detached { try BrowserLibrary.open(url: library) }.value
            let browserLibrary = BrowserLibrary(handle)
            await browserLibrary.start()
            let model = BrowserModel(library: browserLibrary)
            if aspect { model.setLayoutMode(.aspect) }
            let view = BrowserContainerView(model: model)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            view.layoutSubtreeIfNeeded()
            view.grid.needsLayout = true
            view.grid.layoutSubtreeIfNeeded()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                model.onResult = { _ in
                    model.onResult = nil
                    continuation.resume()
                }
                Task { _ = await model.restoreLastSession() }
            }
            model.setTileSizeFromSlider(tile)
            // Past the zoom's settling time, so that the full pass and larger thumbnails arrive.
            for _ in 0..<60 {
                _ = view.grid.tick()
                try await Task.sleep(for: .milliseconds(20))
            }
            let row = view.grid.captureAnchor()?.row ?? 0
            model.select(row: row)
            model.toggle(row: row + 2)
            _ = view.grid.tick()
            view.grid.focus()
            view.grid.focusChanged(true)
            try save(view.grid.host.layer!, size: CGSize(width: 1200, height: 800), to: output.appending(path: name + ".png"))
            browserLibrary.loader.stop()
        }
    }

    @Test(
        "A thumbnail keeps its top at the top, in flipped and unflipped layers",
        .enabled(if: environment["PHOTON_RENDER_CHECKS"] != nil), arguments: [true, false])
    func thumbnailIsUpright(flipped: Bool) throws {
        // Red above, blue below, as a JPEG the way a pack holds it.
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        CGImageDestinationFinalize(destination)
        let decoded = try #require(DecodedThumbnail.decodeForTesting(output as Data))
        let cgImage = try #require(context.makeImage())

        // The same picture as an image and as a surface, side by side. An image always lands the right
        // way up, so this stays true whichever way the renderer's own rows run.
        CATransaction.begin()
        let root = CALayer()
        root.isGeometryFlipped = flipped
        root.bounds = CGRect(x: 0, y: 0, width: 128, height: 64)
        for (index, contents) in [cgImage as Any, decoded.surface as Any].enumerated() {
            let tile = CALayer()
            tile.frame = CGRect(x: index * 64, y: 0, width: 64, height: 64)
            tile.contents = contents
            root.addSublayer(tile)
        }
        CATransaction.commit()
        let url = FileManager.default.temporaryDirectory.appending(path: "photon-upright-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try save(root, size: CGSize(width: 128, height: 64), to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let probe = try #require(
            CGContext(
                data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 128 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        probe.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 64))
        let bytes = try #require(probe.data).assumingMemoryBound(to: UInt8.self)
        func redIsHigher(_ row: Int, _ column: Int) -> Bool {
            let pixel = bytes + row * 128 * 4 + column * 4
            return pixel[0] > pixel[2]
        }
        #expect(redIsHigher(10, 32) == redIsHigher(10, 96), "The surface is upside down compared with the image")
        #expect(redIsHigher(54, 32) == redIsHigher(54, 96), "The surface is upside down compared with the image")
    }

    private func save(_ layer: CALayer, size: CGSize, to url: URL) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: space])
        layer.frame = CGRect(origin: .zero, size: size)
        renderer.layer = layer
        renderer.bounds = CGRect(origin: .zero, size: size)
        CATransaction.flush()
        // Twice, because a tree seen for the first time may not be drawn in its first frame.
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        renderer.layer = nil

        let bytesPerRow = Int(size.width) * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * Int(size.height))
        texture.getBytes(
            &pixels, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)), mipmapLevel: 0)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            let context = try #require(
                CGContext(
                    data: bytes.baseAddress, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: space, bitmapInfo: info))
            // Metal's rows run the other way from a `CGContext`'s.
            let copy = try #require(context.makeImage())
            let flipped = try #require(
                CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: info))
            flipped.translateBy(x: 0, y: size.height)
            flipped.scaleBy(x: 1, y: -1)
            flipped.draw(copy, in: CGRect(origin: .zero, size: size))
            return try #require(flipped.makeImage())
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
