// swift-tools-version: 6.2
import PackageDescription

// Dependencies point downward, as AGENTS.md describes:
// PhotonUI -> PhotonVideo -> PhotonMedia -> PhotonIndex -> PhotonCore.
let package = Package(
    name: "PhotonKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotonCore", targets: ["PhotonCore"]),
        .library(name: "PhotonIndex", targets: ["PhotonIndex"]),
        .library(name: "PhotonMedia", targets: ["PhotonMedia"]),
        .library(name: "PhotonVideo", targets: ["PhotonVideo"]),
        .library(name: "PhotonUI", targets: ["PhotonUI"]),
        .executable(name: "photon-index", targets: ["photon-index"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.12.0"),
    ],
    targets: [
        .target(name: "PhotonCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "PhotonIndex", dependencies: ["PhotonCore"]),
        .target(name: "PhotonMedia", dependencies: ["PhotonCore", "PhotonIndex"]),
        .target(name: "PhotonVideo", dependencies: ["PhotonMedia"]),
        .target(name: "PhotonUI", dependencies: ["PhotonCore", "PhotonIndex", "PhotonMedia", "PhotonVideo"]),

        // Writes synthetic media for tests and for the development tool. Never part of the app.
        .target(name: "PhotonTestSupport", dependencies: ["PhotonCore", "PhotonIndex"]),
        .executableTarget(
            name: "photon-index",
            dependencies: ["PhotonCore", "PhotonIndex", "PhotonMedia", "PhotonVideo", "PhotonTestSupport"]),

        .testTarget(
            name: "PhotonCoreTests",
            dependencies: ["PhotonCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "PhotonIndexTests", dependencies: ["PhotonIndex", "PhotonTestSupport"]),
        .testTarget(name: "PhotonMediaTests", dependencies: ["PhotonMedia", "PhotonTestSupport"]),
        .testTarget(name: "PhotonVideoTests", dependencies: ["PhotonVideo", "PhotonTestSupport"]),
        .testTarget(name: "PhotonUITests", dependencies: ["PhotonUI", "PhotonTestSupport"]),
        .testTarget(
            name: "PhotonIntegrationTests",
            dependencies: ["PhotonCore", "PhotonIndex", "PhotonMedia", "PhotonVideo", "PhotonTestSupport"]),
    ]
)
