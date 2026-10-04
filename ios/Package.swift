// swift-tools-version: 6.0
// Unit tests for the app's platform-independent pieces, run on the Mac with `swift test` (from ios/).
// The app itself is built from ESPTranslator.xcodeproj; this package only compiles the listed files.
import PackageDescription

let package = Package(
    name: "TranslatorCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    targets: [
        .target(
            name: "TranslatorCore",
            path: "Sources",
            exclude: ["Info.plist", "UI", "BLE", "Relay", "App/ESPTranslatorApp.swift", "App/ConversationEngine.swift",
                      "Audio/AudioSources.swift", "Audio/ADPCMDecoder.swift", "Speech/Speaker.swift",
                      "Translate/Translator.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranslatorCoreTests",
            dependencies: ["TranslatorCore"],
            path: "Tests/TranslatorCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
