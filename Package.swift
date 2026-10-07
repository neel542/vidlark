// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Vidlark",
    platforms: [.macOS(.v15)],
    targets: [
        // The Mac app: camera, mic, screen, prompter.
        .executableTarget(
            name: "Vidlark",
            path: "Sources/Vidlark",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs after every recording: sync, transcript, chapters, retakes.
        .executableTarget(
            name: "vidlark-finish",
            path: "Sources/vidlark-finish",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
