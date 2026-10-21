// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceMaster",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "VoiceMaster", targets: ["MediaVolumeApp"])],
    targets: [
        .target(name: "RealtimeDSP", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "AudioCore", dependencies: ["RealtimeDSP"], linkerSettings: [
            .linkedFramework("CoreAudio"), .linkedFramework("AppKit")
        ]),
        .executableTarget(name: "MediaVolumeApp", dependencies: ["AudioCore"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "RealtimeDSP"])
    ],
    swiftLanguageModes: [.v5]
)
