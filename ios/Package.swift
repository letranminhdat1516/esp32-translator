// swift-tools-version: 6.0
// Unit tests for the app's platform-independent pieces, run on the Mac with `swift test` (from ios/).
// The app itself is built from ESPTranslator.xcodeproj; this package only compiles the listed files.
// Engine: the multi-language AppleVoiceEngine without its iOS-only parts (AVAudioSession, UIKit, speech output);
// EngineTests drive it with fakes.
import PackageDescription

let package = Package(
    name: "TranslatorCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    targets: [
        .target(
            name: "TranslatorCore",
            path: "Sources",
            exclude: ["Info.plist", "UI", "BLE/ESPLink.swift", "Relay", "App/ESPTranslatorApp.swift",
                      "App/ConversationEngine.swift", "Audio/ESPAudioSource.swift", "Audio/ADPCMDecoder.swift",
                      "Translate/Translator.swift", "Engine/AudioSession.swift", "Engine/Speaker.swift",
                      "Engine/TranslationSheet.swift", "Engine/AppleVoiceEngine+Live.swift"],
            // Language mode 5 as in the app; complete concurrency checking so data-race diagnostics show up here
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-strict-concurrency=complete"])]
        ),
        .testTarget(
            name: "TranslatorCoreTests",
            dependencies: ["TranslatorCore"],
            path: "Tests/TranslatorCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["TranslatorCore"],
            path: "Tests/EngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
