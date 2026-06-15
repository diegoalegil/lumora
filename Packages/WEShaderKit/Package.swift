// swift-tools-version: 6.0
// License posture: Apache-2.0 — clean-room front-end for Wallpaper Engine's shader dialect. Starts with
// uniform/annotation extraction (which also drives the per-wallpaper property panel) and grows into a
// WE-GLSL → MSL transpiler. Foundation only. No GPL.
import PackageDescription

let package = Package(
    name: "WEShaderKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WEShaderKit", targets: ["WEShaderKit"]),
    ],
    targets: [
        .target(name: "WEShaderKit"),
        .executableTarget(name: "WEShaderKitChecks", dependencies: ["WEShaderKit"]),
    ]
)
