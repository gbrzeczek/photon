import PhotonCore
import PhotonIndex
import SwiftUI

/// The inspector column: what the library knows about the photo in the viewer, or else the current
/// item. It reads only the library, so it works the same offline.
struct InspectorView: View {
    let library: BrowserLibrary
    let model: BrowserModel
    @State private var details: AssetDetails?
    @State private var newTag = ""

    private struct Key: Equatable {
        var asset: AssetID?
        var version: Int
    }

    var body: some View {
        Group {
            if let details {
                Form { content(details) }
                    .formStyle(.grouped)
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle")
            }
        }
        .accessibilityIdentifier("photon.inspector")
        .task(id: Key(asset: model.inspectedAsset, version: model.organizationVersion)) {
            guard let asset = model.inspectedAsset else {
                details = nil
                return
            }
            let found = try? await library.store.details(of: asset)
            guard !Task.isCancelled else { return }
            details = found
        }
    }

    @ViewBuilder
    private func content(_ details: AssetDetails) -> some View {
        let asset = details.asset
        let first = details.locations.first
        Section {
            LabeledContent("Name", value: first?.path.name ?? "—")
            LabeledContent("Kind", value: kind(asset, first))
            if let width = asset.metadata.pixelWidth, let height = asset.metadata.pixelHeight {
                LabeledContent("Dimensions", value: "\(width) × \(height)")
            }
            if let first {
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: first.size, countStyle: .file))
            }
            LabeledContent("Captured", value: captured(asset))
            if let seconds = asset.metadata.durationSeconds {
                LabeledContent("Duration", value: TileArtwork.format(Int(seconds.rounded())))
            }
            Toggle(
                "Favorite",
                isOn: Binding(
                    get: { asset.isFavorite },
                    set: { _ in toggleFavorite(asset.id) }))
        }

        Section("Tags") {
            if !details.tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(details.tags) { tag in
                        Button {
                            model.removeTag(tag.id, from: [asset.id])
                        } label: {
                            Label(tag.name, systemImage: "xmark")
                                .labelStyle(TrailingIconLabelStyle())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Remove the tag “\(tag.name)”")
                    }
                }
            }
            TextField("Add Tag", text: $newTag)
                .textInputSuggestions {
                    ForEach(suggestions(excluding: details.tags)) { tag in
                        Text(tag.name).textInputCompletion(tag.name)
                    }
                }
                .onSubmit {
                    model.addTag(named: newTag, to: [asset.id])
                    newTag = ""
                }
                .accessibilityIdentifier("photon.inspector.addTag")
        }

        if !details.albums.isEmpty {
            Section("Albums") {
                ForEach(details.albums) { album in
                    Button(album.name, systemImage: "rectangle.stack") { model.open(.album(album.id)) }
                        .buttonStyle(.link)
                }
            }
        }

        if let kind = details.stackKind {
            Section(kind == .livePhoto ? "Live Photo" : "RAW+JPEG") {
                ForEach(details.stackMembers, id: \.asset) { member in
                    LabeledContent(member.name, value: member.isCover ? "Cover" : "")
                }
            }
        }

        Section(details.locations.count == 1 ? "File" : "Files") {
            ForEach(details.locations, id: \.instance) { location in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label(location.volumeName, systemImage: "externaldrive")
                        Spacer()
                        if let state = state(of: location.volume) {
                            Text(state).foregroundStyle(.secondary)
                        }
                    }
                    Text(location.path.string)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func toggleFavorite(_ asset: AssetID) {
        let store = library.store
        Task {
            try? await store.toggleFavorite([asset])
            model.organizationDidChange()
        }
    }

    private func suggestions(excluding tags: [Tag]) -> [Tag] {
        let typed = newTag.trimmingCharacters(in: .whitespaces)
        let taken = Set(tags.map(\.id))
        return library.tags.filter {
            !taken.contains($0.id) && (typed.isEmpty || $0.name.localizedCaseInsensitiveContains(typed))
        }
        .prefix(10).map { $0 }
    }

    private func state(of volume: VolumeID) -> String? {
        switch library.volumeAccess[volume] {
        case nil, .offline?: "Offline"
        case .readOnly?: "Read Only"
        case .writable?: nil
        }
    }

    private func kind(_ asset: Asset, _ location: AssetDetails.Location?) -> String {
        let format = location?.path.fileExtension.uppercased() ?? ""
        let kind = asset.kind == .video ? "Video" : "Photo"
        return format.isEmpty ? kind : "\(kind), \(format)"
    }

    private func captured(_ asset: Asset) -> String {
        guard let date = asset.metadata.captureDate else { return "Unknown" }
        // Wall-clock time read as UTC, so it's shown in UTC to read as the camera did.
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(date.wallClockMilliseconds) / 1000))
    }
}

/// A tag's name with its remove symbol after it.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small).foregroundStyle(.secondary)
        }
    }
}

/// Lays out views in rows, wrapping when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}
