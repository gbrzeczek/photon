// swift-tools-version: 6.0
import PackageDescription

// Milestone 0, Spike 1. Throwaway comparison, not part of PhotonKit.
let package = Package(
    name: "Grid",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "grid-spike")]
)
