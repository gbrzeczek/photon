/// Lets one test that uses disk images run at a time, across every suite in the process.
///
/// `hdiutil` runs synchronously and can take seconds, so each image test holds a thread of the
/// cooperative pool. A hosted runner has about three, and parallel suites could hold every one,
/// starving unrelated tests or hanging the run. Tests waiting here are suspended, not blocked.
///
/// Each test target wraps this in a `DiskImageTests` trait, because this target also builds into
/// `photon-index` and must not import Testing.
public actor DiskImageGate {
    public static let shared = DiskImageGate()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
