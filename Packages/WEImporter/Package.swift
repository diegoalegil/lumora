// swift-tools-version: 6.0
// License posture: Apache-2.0 — the only package that touches disk (Steam discovery, file
// formats). Depends only on WECore (MIT). No GPL, no network, no steamcmd/downloads.
import PackageDescription

// NOTE on testing: this environment has Command Line Tools only (no Xcode), so neither XCTest
// nor the swift-testing `Testing` library is importable, and `swift test` cannot run. We verify
// with a lightweight executable `WEImporterChecks` (run: `swift run WEImporterChecks`). When full
// Xcode is available, these checks migrate 1:1 to XCTest/swift-testing test targets.
let package = Package(
    name: "WEImporter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WEImporter", targets: ["WEImporter"]),
    ],
    dependencies: [
        .package(path: "../WECore"),
    ],
    targets: [
        .target(name: "WEImporter", dependencies: ["WECore"]),
        // CLT-only env: verified via an executable rather than XCTest (see WECore/Package.swift).
        .executableTarget(name: "WEImporterChecks", dependencies: ["WEImporter", "WECore"]),
    ]
)
