// swift-tools-version: 6.0
// License posture: MIT — clean-room. Metal render-core for Wallpaper Engine scenes. Depends on WECore
// and WEImporter (the format decoders). Apple frameworks only (Metal). No GPL.
import PackageDescription

// NOTE on testing: Command Line Tools only (no Xcode), so the Metal shader is compiled at runtime via
// `device.makeLibrary(source:)` rather than an offline .metallib. The headless render path is verified
// by `WESceneChecks` (`swift run WESceneChecks`), which skips gracefully when no Metal device exists.
let package = Package(
    name: "WEScene",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WEScene", targets: ["WEScene"]),
    ],
    dependencies: [
        .package(path: "../WECore"),
        .package(path: "../WEImporter"),
        .package(path: "../WEShaderKit"),
        .package(path: "../WESceneDynamics"),
    ],
    targets: [
        .target(name: "WEScene", dependencies: ["WECore", "WEImporter", "WEShaderKit", "WESceneDynamics"]),
        .executableTarget(name: "WESceneChecks", dependencies: ["WEScene", "WEImporter", "WECore"]),
    ]
)
