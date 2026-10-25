// swift-tools-version: 6.0
// Runs the platform-independent part of the iOS VoiceEngine (app/ios/Runner/Native) with its XCTest cases on
// the Mac, without a simulator: `swift test` from app/ios/NativeTests.
//
// Sources/Runner and Tests/NativeTests hold symlinks to the real files, so the module is named Runner and the
// tests' `@testable import Runner` works unchanged. The generated pigeon file imports FlutterMacOS on macOS;
// Sources/FlutterMacOS is a test-only stand-in with the few types it names (no channel traffic happens here).
// iOS-only files (AVAudioSession, UIKit, the Flutter host) are not part of this package; they compile with
// `flutter build ios --no-codesign`.
import PackageDescription

let package = Package(
    name: "NativeTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "FlutterMacOS", path: "Sources/FlutterMacOS"),
        .target(
            name: "Runner",
            dependencies: ["FlutterMacOS"],
            path: "Sources/Runner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NativeTests",
            dependencies: ["Runner"],
            path: "Tests/NativeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
