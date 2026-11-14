// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mneme",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "mneme", targets: ["MnemeCLI"]),
        // The macOS app; Scripts/build-app.sh wraps it into Mneme.app.
        .executable(name: "MnemeApp", targets: ["MnemeApp"]),
        .library(name: "MnemeCore", targets: ["MnemeCore"]),
        .library(name: "MnemeSpeech", targets: ["MnemeSpeech"]),
        // State and audio for the Mac and iPhone apps (the iPhone app is the Xcode project in iOS/).
        .library(name: "MnemeAppSupport", targets: ["MnemeAppSupport"]),
    ],
    dependencies: [
        // WhisperKit (Argmax open-source SDK). 1.1.0 fixes empty transcriptions when prompt tokens are set.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Archive, validation, metrics and evaluation. No third-party dependencies.
        .target(
            name: "MnemeCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // On-device speech recognition with Whisper via WhisperKit (Core ML).
        .target(
            name: "MnemeSpeech",
            dependencies: [
                "MnemeCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "MnemeCLI",
            dependencies: [
                "MnemeCore",
                "MnemeSpeech",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Shared by the Mac and iPhone apps: app state, transcription queue, recording, playback, export.
        .target(
            name: "MnemeAppSupport",
            dependencies: ["MnemeCore", "MnemeSpeech"]
        ),
        // SwiftUI app for macOS: recording, playback, review of flagged passages, notes.
        .executableTarget(
            name: "MnemeApp",
            dependencies: ["MnemeCore", "MnemeSpeech", "MnemeAppSupport"]
        ),
        .testTarget(name: "MnemeCoreTests", dependencies: ["MnemeCore"]),
        .testTarget(name: "MnemeSpeechTests", dependencies: ["MnemeCore", "MnemeSpeech"]),
        .testTarget(name: "MnemeAppSupportTests", dependencies: ["MnemeCore", "MnemeSpeech", "MnemeAppSupport"]),
    ]
)
