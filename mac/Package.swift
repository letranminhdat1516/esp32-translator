// swift-tools-version: 6.0
import PackageDescription

// Embedded into the daemon binary (__TEXT,__info_plist) so TCC can attribute and prompt for Bluetooth
// when it runs under launchd without an app bundle.
let daemonInfoPlist = Context.packageDirectory + "/Sources/claude-board/Info.plist"

let package = Package(
    name: "ClaudeBoard",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../relay")],
    targets: [
        .target(name: "ClaudeBoardCore", dependencies: [.product(name: "ClaudeRelay", package: "relay")]),
        .executableTarget(name: "claude-board-hook", dependencies: ["ClaudeBoardCore"]),
        .executableTarget(
            name: "claude-board",
            dependencies: ["ClaudeBoardCore", .product(name: "ClaudeRelay", package: "relay")],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", daemonInfoPlist]),
            ]
        ),
        .testTarget(name: "ClaudeBoardCoreTests",
                    dependencies: ["ClaudeBoardCore", .product(name: "ClaudeRelay", package: "relay")]),
    ]
)
