// swift-tools-version: 6.0
import PackageDescription

// Milestone 0, Spike 4. Throwaway measurement tool, not part of PhotonKit.
let package = Package(
    name: "Throughput",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "throughput")]
)
