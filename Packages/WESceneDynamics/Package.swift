// swift-tools-version: 6.0
// License posture: MIT — clean-room. Dynamics drivers (audio reactivity now; particles/scenescript
// helpers later) built on Apple frameworks (ScreenCaptureKit, Accelerate/vDSP) + public WE docs.
import PackageDescription

// CLT-only env: no XCTest. Verify with the executable `WESceneDynamicsChecks` (swift run).
let package = Package(
    name: "WESceneDynamics",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WESceneDynamics", targets: ["WESceneDynamics"]),
    ],
    dependencies: [
        .package(path: "../WECore"),
    ],
    targets: [
        // C shim exposing JavaScriptCore's execution-time-limit watchdog (private-header symbol) to Swift.
        .target(name: "CJSWatchdog", linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .target(name: "WESceneDynamics", dependencies: ["WECore", "CJSWatchdog"]),
        .executableTarget(name: "WESceneDynamicsChecks", dependencies: ["WESceneDynamics", "WECore"]),
    ]
)
