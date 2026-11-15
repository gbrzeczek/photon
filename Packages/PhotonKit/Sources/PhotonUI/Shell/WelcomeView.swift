import SwiftUI
import UniformTypeIdentifiers

/// What an empty library shows: what Photon does with your files, and the one step to start. It goes
/// as soon as a folder is in the library, so it needs no state of its own.
struct WelcomeView: View {
    let addFolder: () -> Void
    let addDropped: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Welcome to Photon")
                    .font(.largeTitle.weight(.semibold))
                Text("Browse the photos and videos in your own folders and on external drives.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                Point(
                    symbol: "folder",
                    title: "Your files stay where they are",
                    detail: "Nothing is imported or moved. Photon only reads your photos and videos.")
                Point(
                    symbol: "externaldrive",
                    title: "Drives can come and go",
                    detail: "Disconnect a drive and keep browsing its thumbnails, favorites and albums.")
                Point(
                    symbol: "lock.shield",
                    title: "Nothing is written to your drives",
                    detail: "The library and thumbnails live on this Mac. When you add a folder on an external drive, macOS asks whether Photon may read it. Click Allow.")
            }
            .frame(maxWidth: 440)
            VStack(spacing: 8) {
                Button(action: addFolder) {
                    Label("Add Folder…", systemImage: "folder.badge.plus").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("photon.welcome.add")
                Text("Or drag a folder here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            addDropped(folder)
            return true
        } isTargeted: { isTargeted = $0 }
        // A container, so that its identifier doesn't replace the button's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photon.welcome")
    }
}

private struct Point: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
