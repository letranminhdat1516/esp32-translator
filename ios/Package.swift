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
            // SwiftUI screens and iOS-only pieces are built by the app target only; the design system, the router,
            // the demo data and the Features logic compile here so their values are tested on the Mac.
            exclude: ["Info.plist", "Resources", "UI/UISamples.swift", "BLE/ESPLink.swift", "App/ESPTranslatorApp.swift",
                      "Translate/Translator.swift", "Engine/AudioSession.swift", "Engine/Speaker.swift",
                      "Engine/TranslationSheet.swift", "Engine/AppleVoiceEngine+Live.swift",
                      "UI/Root/RootView.swift", "UI/Onboarding/WelcomeView.swift", "UI/Onboarding/PermissionsView.swift",
                      "UI/Onboarding/PairView.swift", "UI/Onboarding/LanguageView.swift", "UI/Live",
                      "UI/History/HistoryView.swift", "UI/History/HistoryDetailView.swift", "UI/Glossary",
                      "UI/Settings", "UI/Sharing", "Shared/TranslatorIntents.swift", "Shared/ActivityViews.swift"],
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
