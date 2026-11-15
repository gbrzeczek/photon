import AppKit
import PhotonCore
import SwiftUI

enum SettingsPane: Hashable {
    case general, storage
    /// Which pane opens first. Only `PHOTON_OPEN_WINDOW` changes it.
    @MainActor static var initial = SettingsPane.general
}

/// Photon → Settings, Command-Comma. Two panes, as small as the choices are.
public struct PhotonSettingsView: View {
    @State private var pane = SettingsPane.initial

    public init() {}

    public var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings(settings: .shared) }
            Tab("Storage", systemImage: "internaldrive", value: .storage) { StorageSettings(settings: .shared) }
        }
        .frame(width: 500)
        .scenePadding()
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        Form {
            Section("Browsing") {
                Picker("Show new folders as", selection: $settings.newSourceViewMode) {
                    Text("Tiles").tag(BrowserViewMode.tiles)
                    Text("List").tag(BrowserViewMode.list)
                }
                .help("How a folder, album or tag opens the first time. After that it keeps its own view.")
                Toggle(
                    "Keep aspect ratio in tiles",
                    isOn: Binding(
                        get: { settings.keepsAspectRatio },
                        set: { keeps in
                            settings.keepsAspectRatio = keeps
                            settings.browser?.setLayoutMode(keeps ? .aspect : .square)
                        }))
                Toggle("Reopen the viewer at launch if it was open", isOn: $settings.reopensViewer)
            }
            Section {
                Toggle("Play videos when the pointer rests on them", isOn: $settings.playsVideoPreviews)
                    .accessibilityIdentifier("photon.settings.previews")
            } header: {
                Text("Videos")
            } footer: {
                if reducesMotion {
                    Text("Reduce Motion is on in Accessibility settings, so previews don't play.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @Bindable var settings: AppSettings
    @State private var usedBytes: Int64?

    var body: some View {
        Form {
            Section {
                Picker(
                    "Thumbnail cache limit",
                    selection: Binding(
                        get: { settings.thumbnailCacheLimit },
                        set: { limit in
                            settings.thumbnailCacheLimit = limit
                            let bytes = settings.thumbnailCacheByteLimit
                            Task {
                                await settings.browser?.library.setThumbnailCacheByteLimit(bytes)
                                await measure()
                            }
                        })
                ) {
                    ForEach(AppSettings.cacheLimitChoices, id: \.self) { Text("\($0) GB").tag($0) }
                }
                LabeledContent("In use") {
                    Text(usedBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "—")
                        .monospacedDigit()
                        .accessibilityIdentifier("photon.settings.cacheUsed")
                }
            } header: {
                Text("Thumbnails")
            } footer: {
                Text(
                    "Small thumbnails are always kept, so every photo shows something while its drive is disconnected. Larger ones are removed when the cache is full, least recently used first and favorites last."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Library") {
                    Button("Show in Finder") {
                        guard let url = settings.browser?.library.store.databaseURL else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .disabled(settings.browser == nil)
                }
            } footer: {
                Text(
                    "The library and its thumbnails are on this Mac. Photon never writes its own files to your drives, and only reads your photos and videos."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: settings.browser == nil) { await measure() }
    }

    private func measure() async {
        guard let library = settings.browser?.library else { return }
        usedBytes = await library.thumbnailCacheByteCount()
    }
}
