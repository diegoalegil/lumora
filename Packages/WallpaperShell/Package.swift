// swift-tools-version: 6.0
// License posture: MIT — clean-room. Uses only AppKit / IOKit / ServiceManagement. No GPL.
import PackageDescription

let package = Package(
    name: "WallpaperShell",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallpaperShell", targets: ["WallpaperShell"]),
    ],
    dependencies: [
        .package(path: "../WECore"),
    ],
    targets: [
        .target(name: "WallpaperShell", dependencies: ["WECore"]),
        // CLT-only env: verified via an executable rather than XCTest (see WECore/Package.swift).
        .executableTarget(name: "WallpaperShellChecks", dependencies: ["WallpaperShell", "WECore"]),
    ]
)
