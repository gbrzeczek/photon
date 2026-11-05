// swift-tools-version: 6.0
import PackageDescription

// Milestone 0, Spike 2. Throwaway libmpv embedding test, not part of PhotonKit.
// Uses MPVKit's LGPL product only. Never depend on the "MPVKit-GPL" product here.
let package = Package(
    name: "Mpv",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "mpv-spike",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")]
        ),
    ]
)
