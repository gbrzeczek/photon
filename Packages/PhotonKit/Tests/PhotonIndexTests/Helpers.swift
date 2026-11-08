import Foundation
import PhotonCore
import PhotonTestSupport
import Synchronization
import Testing

@testable import PhotonIndex

/// A temporary folder, removed when the value goes away.
final class TemporaryFolder: Sendable {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "photon-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath rather than resolvingSymlinksInPath, which strips /private and so doesn't match
        // what the system reports.
        let resolved = realpath(base.path, nil)
        defer { free(resolved) }
        url = URL(fileURLWithPath: String(cString: resolved!), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relativePath: String, _ data: Data = Data("content".utf8)) throws -> URL {
        let file = url.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url.appending(path: relativePath))
    }

    func move(_ from: String, to destination: String) throws {
        let target = url.appending(path: destination, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url.appending(path: from), to: target)
    }
}

/// A file source that counts what's read, and can fail on demand.
final class CountingSource: ByteSource {
    private let data: Data
    private(set) var reads: [(offset: Int64, length: Int)] = []
    var bytesRead: Int { reads.map(\.length).reduce(0, +) }
    var shortReadAfter: Int?

    init(_ data: Data) { self.data = data }
    var size: Int64 { Int64(data.count) }

    func read(offset: Int64, length: Int) throws -> Data {
        reads.append((offset, length))
        let start = Int(min(offset, Int64(data.count)))
        var end = min(start + length, data.count)
        if let shortReadAfter, reads.count > shortReadAfter { end = start }
        return data.subdata(in: start..<end)
    }
}

/// Reads a little of each file, so that pipeline tests exercise the path without needing real media.
struct StubExtractor: MetadataExtracting {
    func metadata(kind: MediaKind, fileExtension: String, from source: any ByteSource) throws -> MediaMetadata? {
        _ = try source.read(offset: 0, length: 16)
        return MediaMetadata(pixelWidth: 1, pixelHeight: 1)
    }
}

/// Collects the paths the I/O layer opens.
final class PathLog: Sendable {
    let observe: @Sendable (String) -> Void

    init() {
        let storage = Storage()
        self.storage = storage
        observe = { path in storage.paths.withLock { $0.append(path) } }
    }

    private final class Storage: Sendable { let paths = Mutex<[String]>([]) }
    private let storage: Storage

    /// Files opened since the last call. Directory listings end in a slash, and aren't included.
    func takeFiles() -> Set<String> {
        storage.paths.withLock { paths in
            defer { paths.removeAll() }
            return Set(paths.filter { !$0.hasSuffix("/") })
        }
    }
}

// Local `Atomic` and `Mutex` values can't be captured by concurrent closures on every supported
// compiler, because they aren't copyable. These classes give tests something shareable instead.

final class SharedFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .sequentiallyConsistent) }
    func set() { value.store(true, ordering: .sequentiallyConsistent) }
}

final class SharedList: Sendable {
    private let items = Mutex<[String]>([])
    var values: [String] { items.withLock { $0 } }
    func append(_ item: String) { items.withLock { $0.append(item) } }
}

/// Tracks how many jobs ran at once.
final class ConcurrencyMeter: Sendable {
    private let running = Atomic<Int>(0)
    private let highest = Atomic<Int>(0)
    var peak: Int { highest.load(ordering: .sequentiallyConsistent) }

    func enter() {
        let now = running.add(1, ordering: .sequentiallyConsistent).newValue
        highest.max(now, ordering: .sequentiallyConsistent)
    }

    func leave() { running.subtract(1, ordering: .sequentiallyConsistent) }
}

/// A condition to wait for from a test, with a limit so that a bug fails rather than hangs.
func eventually(
    timeout: Duration = .seconds(10), _ condition: @Sendable () async throws -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

func randomData(_ count: Int, seed: UInt64 = 1) -> Data {
    var generator = SeededGenerator(seed: seed)
    var data = Data(capacity: count + 8)
    while data.count < count { withUnsafeBytes(of: generator.next()) { data.append(contentsOf: $0) } }
    return data.prefix(count)
}

enum LibraryStoreFixture {
    static func make(in folder: TemporaryFolder) throws -> LibraryStore {
        try LibraryStore(url: folder.url.appending(path: "Library.sqlite"))
    }
}
