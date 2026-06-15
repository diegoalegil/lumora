// swift-tools-version: 6.0
// License posture: MIT — clean-room. Players built on Apple frameworks (AVFoundation/AppKit now,
// WebKit later). Depends only on WECore. No GPL.
import PackageDescription

// NOTE on testing: Command Line Tools only (no Xcode), so no XCTest / swift-testing. The headless,
// AppKit-free logic is verified with the executable `WEPlayersChecks` (`swift run WEPlayersChecks`);
// the AVKit/AppKit rendering path is exercised by running LumoraApp.
let package = Package(
    name: "WEPlayers",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WEPlayers", targets: ["WEPlayers"]),
    ],
    dependencies: [
        .package(path: "../WECore"),
    ],
    targets: [
        .target(name: "WEPlayers", dependencies: ["WECore"]),
        .executableTarget(name: "WEPlayersChecks", dependencies: ["WEPlayers", "WECore"]),
    ]
)
