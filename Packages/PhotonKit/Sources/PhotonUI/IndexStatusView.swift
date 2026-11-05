import AppKit
import PhotonCore
import SwiftUI

/// A window that shows indexing working. The real shell arrives with the grid in Milestone 2.
public struct IndexStatusView: View {
    @State private var controller = IndexingController()

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if controller.summaries.isEmpty {
                    ContentUnavailableView(
                        "No Folders Yet", systemImage: "photo.on.rectangle",
                        description: Text("Add a folder to index its photos and videos."))
                } else {
                    List(controller.summaries) { summary in
                        LabeledContent {
                            Text(status(for: summary))
                        } label: {
                            Text(summary.volume.name)
                            Text(summary.totalBytes, format: .byteCount(style: .file))
                        }
                    }
                }
            }
            .navigationTitle("Photon")
            .toolbar {
                Button("Add Folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                    .disabled(controller.isIndexing)
            }
            .safeAreaInset(edge: .bottom) {
                if let message = controller.lastError ?? (controller.activity.isEmpty ? nil : controller.activity) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.bar)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .task { await controller.start() }
    }

    private func status(for summary: VolumeSummary) -> String {
        var parts = ["\(summary.fileCount) files"]
        if summary.pendingCount > 0 { parts.append("\(summary.pendingCount) pending") }
        if summary.failedCount > 0 { parts.append("\(summary.failedCount) failed") }
        return parts.joined(separator: ", ")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            controller.index(folder: url)
        }
    }
}
