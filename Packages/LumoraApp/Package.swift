// swift-tools-version: 6.0
// License posture: MIT (own code). Thin menu-bar shell; all logic lives in feature/core packages.
// Dependency direction: App -> feature packages (WallpaperShell/WEImporter/WEPlayers) -> WECore
// (one-directional, no GPL).
import PackageDescription

let package = Package(
    name: "LumoraApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../WECore"),
        .package(path: "../WallpaperShell"),
        .package(path: "../WEImporter"),
        .package(path: "../WEPlayers"),
    ],
    targets: [
        .executableTarget(
            name: "LumoraApp",
            dependencies: ["WECore", "WallpaperShell", "WEImporter", "WEPlayers"]
        ),
    ]
)
