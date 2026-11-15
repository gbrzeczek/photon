import AppKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonTestSupport
import Synchronization
import Testing

@testable import PhotonUI

/// Milestone 7b: Settings, the permission notice, the shortcut window and the acknowledgements.
@Suite("Polish")
@MainActor
struct PolishTests {
    private func until(_ seconds: Double = 30, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// A suite of its own for each test, removed afterwards.
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "app.photon.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: Settings

    @Test("Settings start at their defaults, and each one lasts to the next launch")
    func settingsPersist() throws {
        try withSuite { defaults in
            let first = AppSettings(defaults: defaults)
            #expect(first.playsVideoPreviews)
            #expect(!first.keepsAspectRatio)
            #expect(first.newSourceViewMode == .tiles)
            #expect(first.reopensViewer)
            #expect(first.thumbnailCacheLimit == 20)
            #expect(first.thumbnailCacheByteLimit == 20 << 30)

            first.playsVideoPreviews = false
            first.keepsAspectRatio = true
            first.newSourceViewMode = .list
            first.reopensViewer = false
            first.thumbnailCacheLimit = 5

            let second = AppSettings(defaults: defaults)
            #expect(!second.playsVideoPreviews)
            #expect(second.keepsAspectRatio)
            #expect(second.newSourceViewMode == .list)
            #expect(!second.reopensViewer)
            #expect(second.thumbnailCacheLimit == 5)
        }
    }

    @Test("A cache limit the window doesn't offer falls back to the default")
    func strangeCacheLimit() throws {
        try withSuite { defaults in
            defaults.set(7, forKey: "ThumbnailCacheLimitGB")
            #expect(AppSettings(defaults: defaults).thumbnailCacheLimit == AppSettings.defaultCacheLimit)
        }
    }

    @Test("Tests and measurements never use the user's own settings")
    func launchDomains() throws {
        #expect(AppSettings.launchDefaults(environment: [:]) == .standard)
        let development = AppSettings.launchDefaults(environment: ["PHOTON_LIBRARY": "/tmp/x"])
        #expect(development != .standard)
        #expect(AppSettings.launchDefaults(environment: ["XCTestConfigurationFilePath": "x"]) != .standard)

        development.set(false, forKey: "PlaysVideoPreviews")
        #expect(AppSettings(defaults: development).playsVideoPreviews == false)
        let reset = AppSettings.launchDefaults(environment: ["PHOTON_LIBRARY": "/tmp/x", "PHOTON_RESET_SETTINGS": "1"])
        #expect(AppSettings(defaults: reset).playsVideoPreviews)
        // The package's own tests keep everything in memory.
        #expect(Bundle.main.bundleIdentifier != AppSettings.appIdentifier)
    }

    @Test("Keep Aspect Ratio comes from Settings at launch, and the View menu's toggle goes back to it")
    func aspectRatioSetting() async throws {
        let fixture = try await BrowserFixture(count: 20)
        defer { fixture.tearDown() }
        let settings = AppSettings(defaults: nil)
        settings.keepsAspectRatio = true
        #expect(BrowserModel(library: fixture.library, settings: settings).layoutMode == .aspect)

        let model = BrowserModel(library: fixture.library, settings: AppSettings(defaults: nil))
        #expect(model.layoutMode == .square)
        model.setLayoutMode(.aspect)
        #expect(model.settings.keepsAspectRatio)
        model.setLayoutMode(.square)
        #expect(!model.settings.keepsAspectRatio)
    }

    @Test("A source opened for the first time takes the view chosen in Settings, and keeps its own after")
    func newSourceView() async throws {
        let fixture = try await BrowserFixture(count: 20)
        defer { fixture.tearDown() }
        fixture.model.settings.newSourceViewMode = .list

        await fixture.waitForResult { fixture.model.open(.favorites) }
        #expect(fixture.model.viewMode == .list)

        fixture.model.setViewMode(.tiles)
        fixture.model.flushSession()
        await fixture.waitForResult { fixture.model.open(.allItems) }
        #expect(fixture.model.viewMode == .list)
        await fixture.waitForResult { fixture.model.open(.favorites) }
        #expect(fixture.model.viewMode == .tiles)
    }

    // MARK: Permission

    @Test("A folder macOS won't let Photon list says so in the status bar, until it lists again")
    func deniedFolder() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "photon-denied-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: media.appending(path: "a.jpg"))

        final class Denial: Sendable { let isOn = Mutex(true) }
        let denial = Denial()
        var options = BrowserLibrary.defaultOptions
        options.faults = { operation, _ in
            operation == .list && denial.isOn.withLock({ $0 }) ? .fail(code: EPERM) : nil
        }
        let url = directory.appending(path: "library/Library.sqlite")
        let handle = try await Task.detached { try BrowserLibrary.open(url: url) }.value
        let library = BrowserLibrary(handle, options: options)
        defer { library.loader.stop() }
        await library.start()

        library.addFolder(media)
        #expect(try await until { !library.isIndexing })
        let volume = try #require(library.onlineVolumes.first)
        #expect(library.deniedVolumes == [volume])

        denial.isOn.withLock { $0 = false }
        library.addFolder(media)
        #expect(try await until { !library.isIndexing })
        #expect(library.deniedVolumes.isEmpty)
    }

    // MARK: Help

    /// The rows of the shortcut table in docs/PLAN.md, as context, keys and action.
    private func planRows() throws -> [(String, String)] {
        let plan = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/PLAN.md")
        let text = try String(contentsOf: plan, encoding: .utf8)
        let section = try #require(text.components(separatedBy: "**Shortcuts.**").dropFirst().first)
        let table = section.components(separatedBy: "\n\n").dropFirst().first ?? ""
        return table.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 5, cells[1] != "Context", !cells[1].hasPrefix("---") else { return nil }
            return (cells[1], cells[2])
        }
    }

    @Test("Help's shortcut window lists exactly the plan's table, leaving out what isn't built")
    func shortcutsMatchPlan() throws {
        let plan = try planRows()
        #expect(plan.count > 20)
        let window = ShortcutTable.rows.map { "\($0.context) | \($0.keys)" }
        #expect(Set(window) == Set(plan.map { "\($0.0) | \($0.1)" }))
        #expect(window.count == plan.count)
        let hidden = ShortcutTable.rows.filter { !$0.isBuilt }.map(\.keys)
        #expect(hidden == ["Cmd-Shift-R", "Cmd-Delete"])
        let shown = ShortcutTable.sections.flatMap(\.rows)
        #expect(shown.count == ShortcutTable.rows.count - hidden.count)
    }

    @Test("Keys are written as the menus write them")
    func shortcutSymbols() {
        #expect(ShortcutTable.symbols("Cmd-Shift-A") == "⇧⌘A")
        #expect(ShortcutTable.symbols("Ctrl-Cmd-F") == "⌃⌘F")
        #expect(ShortcutTable.symbols("Cmd-Equals, Cmd-Minus, Cmd-0") == "⌘=, ⌘−, ⌘0")
        #expect(ShortcutTable.symbols("Cmd-R, Cmd-Option-R") == "⌘R, ⌥⌘R")
        #expect(ShortcutTable.symbols("Option-Left, Option-Right") == "⌥←, ⌥→")
        #expect(ShortcutTable.symbols("Escape, Space, Cmd-Up") == "esc, Space, ⌘↑")
        #expect(ShortcutTable.symbols("`[`, `]`, `=`") == "[, ], =")
        #expect(ShortcutTable.symbols("Shift-arrow keys") == "⇧ Arrow Keys")
        #expect(ShortcutTable.symbols("Type a name") == "Type a name")
        #expect(ShortcutTable.symbols("Period") == ".")
    }

    @Test("Acknowledgements list GRDB, then each license the libmpv build wrote, then its versions")
    func acknowledgements() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "photon-licenses-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "LGPL".write(to: folder.appending(path: "FFmpeg-LGPL-2.1.txt"), atomically: true, encoding: .utf8)
        try "BSD".write(to: folder.appending(path: "dav1d-BSD-2-Clause.txt"), atomically: true, encoding: .utf8)
        try "mpv 0.41.0".write(to: folder.appending(path: "manifest.txt"), atomically: true, encoding: .utf8)

        let items = Acknowledgement.load(libmpvDirectory: folder)
        #expect(items.map(\.name) == ["GRDB", "dav1d", "FFmpeg", "Versions of the video fallback"])
        #expect(items[1].license == "BSD 2 Clause")
        #expect(items[2].license == "LGPL 2.1")
        #expect(items[2].text == "LGPL")
        #expect(items[0].text.contains("Gwendal Roué"))

        let none = Acknowledgement.load(libmpvDirectory: folder.appending(path: "missing"))
        #expect(none.map(\.name) == ["GRDB"])
    }
}
