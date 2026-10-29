// swift-tools-version: 6.0
// Term harness (P2.5, R10): the corpus in shared/fixtures/terms through the app's own TermProtector and Apple
// Translation, one run per placeholder shape. `swift run term-harness --fake` on the Mac; see README in
// shared/fixtures/terms. The app's sources are linked, not copied (Sources/*/Linked are symlinks into ios/Sources).
import PackageDescription

let package = Package(
    name: "term-harness",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "TermHarnessKit",
            path: "Sources/TermHarnessKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "term-harness",
            dependencies: ["TermHarnessKit"],
            path: "Sources/term-harness",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TermHarnessKitTests",
            dependencies: ["TermHarnessKit"],
            path: "Tests/TermHarnessKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
