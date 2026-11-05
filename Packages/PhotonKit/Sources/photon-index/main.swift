import AppKit
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import PhotonTestSupport

// A development tool for measuring indexing outside the app. It prints counts only, never file names,
// so its output is safe to paste into a public repository.

let usage = """
    Usage:
      photon-index scan <folder> [--database <file>] [--json <file>]
      photon-index status [--database <file>]
      photon-index mount-info <folder>
      photon-index generate <folder> [--count <n>] [--average-bytes <n>] [--seed <n>]

    scan refuses an external volume unless it's mounted read-only.
    generate only writes to the internal disk or a disk image.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

func openStore() throws -> LibraryStore {
    let url = try option("--database").map { URL(fileURLWithPath: $0) } ?? LibraryStore.defaultURL()
    return try LibraryStore(url: url)
}

func format(_ value: Double) -> String { String(format: "%.2f", value) }

func describe(_ report: IndexReport) -> [(String, String)] {
    let scan = report.scan
    let filesPerSecond = report.processSeconds > 0 ? Double(report.processed) / report.processSeconds : 0
    return [
        ("outcome", report.outcome.rawValue),
        ("new volume", String(report.isNewVolume)),
        ("directories", String(scan.directories)),
        ("added", String(scan.added)),
        ("modified", String(scan.modified)),
        ("removed", String(scan.removed)),
        ("unchanged", String(scan.unchanged)),
        ("unreadable directories", String(scan.unreadableDirectories)),
        ("files read", String(report.processed)),
        ("failures", String(report.failed)),
        ("hashed", String(report.identity.hashed)),
        ("merged", String(report.identity.merged)),
        ("rehashed", String(report.identity.rehashed)),
        ("reassigned", String(report.identity.reassigned)),
        ("files opened", String(report.io.filesOpened)),
        ("bytes read", String(report.io.bytesRead)),
        ("enumerate seconds", format(report.scanSeconds)),
        ("read seconds", format(report.processSeconds)),
        ("files per second", format(filesPerSecond)),
    ]
}

func runScan(path: String) async throws {
    let mount = try MountedVolume.containing(path: path).volume
    if let reason = MountPolicy.refusalReason(for: mount) { fail("Refused: \(reason)") }
    print("Volume: \(mount.filesystem), \(mount.location.rawValue), read-only: \(mount.isReadOnly)")

    let store = try openStore()
    let indexer = LibraryIndexer(store: store, extractor: MediaMetadataReader())
    // Run on the main run loop, which async main keeps running, so an unmount stops the work.
    let monitor = VolumeEventMonitor(
        center: NSWorkspace.shared.notificationCenter,
        willUnmount: { indexer.volumeWillUnmount(mountPoint: $0) },
        didUnmount: { indexer.volumeDidUnmount(mountPoint: $0) })

    let run = Task { try await indexer.index(path: path) }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { run.cancel() }
    interrupt.resume()

    let report = try await run.value
    withExtendedLifetime(monitor) {}
    interrupt.cancel()

    let lines = describe(report)
    for (label, value) in lines { print("\(label): \(value)") }
    if let json = option("--json") {
        let object = Dictionary(lines, uniquingKeysWith: { first, _ in first })
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: json))
    }
}

func runStatus() async throws {
    for summary in try await openStore().volumeSummaries() {
        print(
            "\(summary.volume.id): \(summary.fileCount) files, \(summary.pendingCount) pending, "
                + "\(summary.failedCount) failed, \(summary.totalBytes) bytes, \(summary.roots.count) roots")
    }
}

func runMountInfo(path: String) throws {
    let mount = try MountedVolume.containing(path: path).volume
    print("filesystem: \(mount.filesystem)")
    print("location: \(mount.location.rawValue)")
    print("read-only: \(mount.isReadOnly)")
    print("policy: \(MountPolicy.refusalReason(for: mount) ?? "allowed")")
}

func runGenerate(path: String) throws {
    var options = SyntheticLibrary.Options()
    options.fileCount = option("--count").flatMap(Int.init) ?? options.fileCount
    options.averageBytes = option("--average-bytes").flatMap(Int.init) ?? options.averageBytes
    options.seed = option("--seed").flatMap(UInt64.init) ?? options.seed
    let manifest = try SyntheticLibrary(options: options).generate(at: URL(fileURLWithPath: path))
    print(
        "\(manifest.files.count) files, \(manifest.photos) photos, \(manifest.videos) videos, "
            + "\(manifest.duplicates) duplicates, \(manifest.bytes) bytes")
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail(usage) }
do {
    switch (arguments[1], arguments.count > 2 ? arguments[2] : nil) {
    case ("scan", let path?): try await runScan(path: path)
    case ("status", _): try await runStatus()
    case ("mount-info", let path?): try runMountInfo(path: path)
    case ("generate", let path?): try runGenerate(path: path)
    default: fail(usage)
    }
} catch {
    fail("Failed: \(error)")
}
