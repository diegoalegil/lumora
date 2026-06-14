// swift-tools-version: 6.0
// License posture: MIT — clean-room spine. ZERO third-party dependencies (keep it that way).
import PackageDescription

// NOTE on testing: this environment has Command Line Tools only (no Xcode), so neither XCTest
// nor the swift-testing `Testing` library is importable, and `swift test` cannot run. We verify
// with a lightweight executable `WECoreChecks` (run: `swift run WECoreChecks`). When full Xcode
// is available, these checks migrate 1:1 to XCTest/swift-testing test targets.
let package = Package(
    name: "WECore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WECore", targets: ["WECore"]),
    ],
    targets: [
        .target(name: "WECore"),
        .executableTarget(name: "WECoreChecks", dependencies: ["WECore"]),
    ]
)
