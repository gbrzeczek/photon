import PhotonTestSupport
import Testing

/// Runs a test, or every test in a suite, only while no other disk image test is running in the
/// process. See `DiskImageGate`.
struct DiskImageTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // A suite's own scope has no test case. Gating it too would hold the gate for the whole suite.
        guard testCase != nil else { return try await function() }
        try await DiskImageGate.shared.run { try await function() }
    }
}

extension Trait where Self == DiskImageTrait {
    /// Uses disk images, so it waits for any other test that does.
    static var usesDiskImages: Self { Self() }
}
