// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AVARecorder",
    platforms: [.macOS(.v15)],
    targets: [
        // The Mac app: camera, mic, screen, prompter.
        .executableTarget(
            name: "AVARecorder",
            path: "Sources/AVARecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs after every recording: sync, transcript, chapters, retakes.
        .executableTarget(
            name: "ava-finish",
            path: "Sources/ava-finish",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
