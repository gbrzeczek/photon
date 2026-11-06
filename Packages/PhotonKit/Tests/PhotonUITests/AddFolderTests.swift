import AppKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport
import Testing

@testable import PhotonUI

/// What Add Folder does, from the choice of a folder to tiles with thumbnails, on an exFAT image like
/// the real drive. Only the open panel itself is left out.
@Suite("Adding a folder", .serialized)
@MainActor
struct AddFolderTests {
    private func until(_ seconds: Double = 30, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func makeBrowser(_ directory: URL) async throws -> (BrowserLibrary, BrowserModel, BrowserContainerView, NSWindow) {
        _ = NSApplication.shared
        let url = directory.appending(path: "library/Library.sqlite")
        let handle = try await Task.detached { try BrowserLibrary.open(url: url) }.value
        let library = BrowserLibrary(handle)
        await library.start()
        let model = BrowserModel(library: library)
        let view = BrowserContainerView(model: model)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        view.grid.needsLayout = true
        view.grid.layoutSubtreeIfNeeded()
        return (library, model, view, window)
    }

    @Test("A folder on a read-only exFAT volume is indexed, browsed and gets thumbnails, and the image stays unchanged")
    func addFolderReadOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-add-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try DiskImage.create(in: directory, label: "PHOTONADD", megabytes: 64)
        var mount = try image.attach()
        defer { image.ensureDetached() }
        var options = SyntheticLibrary.Options()
        options.fileCount = 40
        options.duplicateInterval = 0
        let manifest = try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: mount).appending(path: "media"))
        try image.detach()
        mount = try image.attach(readOnly: true)
        let before = try Data(contentsOf: URL(fileURLWithPath: mount).appending(path: "media").appending(path: manifest.files[0]))

        let (library, model, view, window) = try await makeBrowser(directory)
        defer {
            library.loader.stop()
            window.close()
        }
        library.addFolder(URL(fileURLWithPath: mount).appending(path: "media"))

        #expect(try await until { !library.isIndexing && model.itemCount == 40 })
        #expect(library.lastError == nil)
        #expect(library.folders.first?.isRoot == true)
        #expect(library.onlineVolumes.count == 1)

        // The background stage ends with nothing left to do.
        let volume = try #require(library.onlineVolumes.first)
        #expect(try await until { try await library.store.thumbnailBacklog(volume: volume) == 0 })

        let shown = try await until {
            _ = view.grid.tick()
            return view.grid.visibleTileCount > 0 && view.grid.visibleThumbnailCount > 0
        }
        #expect(shown)

        // Nothing landed on the drive, and the file it read is as it was.
        let after = try Data(contentsOf: URL(fileURLWithPath: mount).appending(path: "media").appending(path: manifest.files[0]))
        #expect(after == before)
        let listed = try FileManager.default.contentsOfDirectory(atPath: mount).filter { !$0.hasPrefix(".") }
        #expect(listed == ["media"])
    }

    @Test("Offline, the stored thumbnails still show, and nothing fails")
    func offlineBrowsing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try DiskImage.create(in: directory, label: "PHOTONOFF", megabytes: 64)
        let mount = try image.attach()
        defer { image.ensureDetached() }
        var options = SyntheticLibrary.Options()
        options.fileCount = 12
        options.duplicateInterval = 0
        options.videoInterval = 0
        try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: mount).appending(path: "media"))

        let (library, model, view, window) = try await makeBrowser(directory)
        defer {
            library.loader.stop()
            window.close()
        }
        library.addFolder(URL(fileURLWithPath: mount).appending(path: "media"))
        #expect(try await until { !library.isIndexing && model.itemCount == 12 })
        let volume = try #require(library.onlineVolumes.first)
        #expect(try await until { try await library.store.thumbnailBacklog(volume: volume) == 0 })

        try image.detach()
        library.indexer.volumeDidUnmount(mountPoint: mount)
        library.loader.cache.remove(asset: AssetID(rawValue: model.result.assetIDs[0]))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            model.onResult = { _ in
                model.onResult = nil
                continuation.resume()
            }
            model.reload(keepPosition: true)
        }
        #expect(model.itemCount == 12)
        let shown = try await until {
            _ = view.grid.tick()
            return view.grid.visibleThumbnailCount == 12
        }
        #expect(shown)
    }
}
