// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudIO",
    // Core Audio process taps (CATapDescription) require macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "AudIO",
            path: "Sources/AudIO",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
