// swift-tools-version: 6.0
import PackageDescription

// Shared by the Mac daemon (mac/Package.swift) and the iPhone app (ios/project.yml): everything both ends of the
// iPhone relay must agree on. Tested on the Mac with `swift test`, without Tailscale (loopback only).
let package = Package(
    name: "ClaudeRelay",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [.library(name: "ClaudeRelay", targets: ["ClaudeRelay"])],
    targets: [
        .target(name: "ClaudeRelay"),
        .testTarget(name: "ClaudeRelayTests", dependencies: ["ClaudeRelay"]),
    ]
)
