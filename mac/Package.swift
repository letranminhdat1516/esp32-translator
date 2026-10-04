// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeBoardCore"),
        .executableTarget(name: "claude-board-hook", dependencies: ["ClaudeBoardCore"]),
        .executableTarget(name: "claude-board", dependencies: ["ClaudeBoardCore"]),
        .testTarget(name: "ClaudeBoardCoreTests", dependencies: ["ClaudeBoardCore"]),
    ]
)
