// swift-tools-version: 6.0
import PackageDescription

// Milestone 0, Spike 3. Throwaway measurement tool, not part of PhotonKit.
let package = Package(
    name: "VolumeProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "volume-probe",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
            ]
        )
    ]
)
