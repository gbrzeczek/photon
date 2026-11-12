import AppKit
import Foundation
import Testing

/// A misspelled or made-up SF Symbol gives no image and no error, only an empty button. This reads
/// PhotonUI's sources for symbol names and checks that each one exists on this system.
@Suite("SF Symbols")
struct SymbolNameTests {
    @Test("Every symbol PhotonUI names exists")
    func symbolsExist() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PhotonUI")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let literal = /"([a-z0-9]+(?:\.[a-z0-9]+)+)"/
        var names = Set<String>()
        for case let url as URL in files where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                // Lines that name a symbol, and the ternaries that choose between two.
                let lower = line.lowercased()
                guard lower.contains("symbol") || lower.contains("systemimage") || line.contains(".fill\"")
                else { continue }
                for match in line.matches(of: literal) { names.insert(String(match.output.1)) }
            }
        }
        #expect(names.count > 20)
        let missing = names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        #expect(missing.isEmpty, "Not SF Symbols: \(missing.sorted())")
    }
}
