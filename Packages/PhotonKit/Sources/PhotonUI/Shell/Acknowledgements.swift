import AppKit
import SwiftUI

/// The open-source code inside Photon, and each one's license, for Help → Acknowledgements and the
/// About panel. The libmpv build's licenses are read from the app's Resources, where its build phase
/// puts them, so a build without the fallback lists only what it really contains.
struct Acknowledgement: Identifiable, Hashable, Sendable {
    let name: String
    let license: String
    let text: String
    var id: String { name }

    static let grdb = Acknowledgement(
        name: "GRDB", license: "MIT",
        text: """
            Copyright (C) 2015-2025 Gwendal Roué

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """)

    /// Where the libmpv build phase copies its licenses.
    static var libmpvDirectory: URL? {
        Bundle.main.resourceURL?.appending(path: "Licenses/libmpv", directoryHint: .isDirectory)
    }

    /// Everything in the app, GRDB first, then the fallback's libraries by name. Reads files, so it runs
    /// off the main thread. The files are named `<Library>-<License>.txt`, as `scripts/mpv/build.sh`
    /// writes them, and `manifest.txt` gives the versions and commits.
    static func load(libmpvDirectory: URL? = libmpvDirectory) -> [Acknowledgement] {
        var result = [grdb]
        guard let directory = libmpvDirectory,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return result }
        for file in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where file.hasSuffix(".txt") && file != "manifest.txt" {
            guard let text = try? String(contentsOf: directory.appending(path: file), encoding: .utf8) else { continue }
            let stem = String(file.dropLast(4))
            let split = stem.firstIndex(of: "-")
            let name = split.map { String(stem[..<$0]) } ?? stem
            let license = split.map { String(stem[stem.index(after: $0)...]).replacingOccurrences(of: "-", with: " ") } ?? ""
            result.append(Acknowledgement(name: name, license: license, text: text))
        }
        if let manifest = try? String(contentsOf: directory.appending(path: "manifest.txt"), encoding: .utf8) {
            result.append(Acknowledgement(name: "Versions of the video fallback", license: "", text: manifest))
        }
        return result
    }
}

/// Help → Acknowledgements.
public struct AcknowledgementsView: View {
    @State private var items: [Acknowledgement] = []
    @State private var selection: Acknowledgement.ID?

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    if !item.license.isEmpty {
                        Text(item.license).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let item = items.first(where: { $0.id == selection }) {
                ScrollView {
                    Text(item.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            items = await Task.detached(priority: .userInitiated) { Acknowledgement.load() }.value
            selection = selection ?? items.first?.id
        }
    }
}

/// Photon → About Photon: the standard panel, with what Photon promises and what it includes.
enum AboutPanel {
    static let repository = URL(string: "https://github.com/gbrzeczek/photon")!

    @MainActor
    static func show() {
        let body = """
            A fast browser for the photos and videos in your own folders and on external drives. Photon only reads your files, and never writes its own to your drives.

            Includes GRDB under the MIT license, and the video fallback's mpv, FFmpeg and their libraries under the LGPL and other open-source licenses. Help → Acknowledgements has each license.
            """
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: body + "\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ])
        credits.append(
            NSAttributedString(
                string: "github.com/gbrzeczek/photon",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: repository,
                    .paragraphStyle: paragraph,
                ]))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }
}
