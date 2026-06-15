// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Parses a Wallpaper Engine scene graph (scene.json + the model/material JSON
// it references, structure observed in the user's OWN packages) into a flat list of renderable image
// layers, resolving each object's image → model → material → ".tex" texture path. No GPL source used.
import Foundation

/// A 3-component vector parsed from WE's space-separated string encoding (e.g. `"1920.000 1080.000 0"`).
public struct SceneVec3: Sendable, Equatable {
    public let x: Double, y: Double, z: Double

    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }

    /// Parse `"x y z"` (missing components default to 0).
    public init(parsing string: String) {
        let parts = string.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Double($0) ?? 0 }
        x = parts.count > 0 ? parts[0] : 0
        y = parts.count > 1 ? parts[1] : 0
        z = parts.count > 2 ? parts[2] : 0
    }
}

/// One renderable image layer of a scene: the texture to draw and where/how to draw it.
public struct SceneLayer: Sendable, Equatable {
    public let name: String
    /// In-package path of the layer's base texture (e.g. `"materials/foo.tex"`), or nil if unresolved.
    public let texturePath: String?
    public let origin: SceneVec3
    public let scale: SceneVec3
    public let angles: SceneVec3
    public let alpha: Double
    public let parallaxDepth: SceneVec3
    public let visible: Bool
    public let blending: String?
    public let shader: String?
}

/// A parsed scene: its orthographic size, clear colour and ordered image layers (painter's order).
public struct SceneDocument: Sendable, Equatable {
    public let orthoWidth: Int
    public let orthoHeight: Int
    public let clearColor: SceneVec3
    public let layers: [SceneLayer]
}

/// Why a scene graph could not be loaded.
public enum SceneGraphError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingSceneJSON
    case invalidSceneJSON

    public var description: String {
        switch self {
        case .missingSceneJSON: return "package has no scene.json"
        case .invalidSceneJSON: return "scene.json is not a valid scene object"
        }
    }
}

/// Builds a `SceneDocument` from a `ScenePackage` by reading scene.json and following each image
/// object through its model and material to the texture it draws.
public enum SceneGraph {
    public static func load(from package: ScenePackage) throws -> SceneDocument {
        guard let sceneEntry = package.sceneJSON else { throw SceneGraphError.missingSceneJSON }
        guard let root = (try? JSONSerialization.jsonObject(with: sceneEntry.data)) as? [String: Any]
        else { throw SceneGraphError.invalidSceneJSON }

        let general = root["general"] as? [String: Any] ?? [:]
        let ortho = general["orthogonalprojection"] as? [String: Any] ?? [:]
        let clearColor = SceneVec3(parsing: general["clearcolor"] as? String ?? "0 0 0")

        var layers: [SceneLayer] = []
        for object in root["objects"] as? [[String: Any]] ?? [] {
            guard let imagePath = object["image"] as? String, !imagePath.isEmpty else { continue }
            layers.append(SceneLayer(
                name: object["name"] as? String ?? "",
                texturePath: resolveTexture(imagePath: imagePath, in: package),
                origin: vec(object["origin"]),
                scale: vec(object["scale"], default: SceneVec3(x: 1, y: 1, z: 1)),
                angles: vec(object["angles"]),
                alpha: number(object["alpha"], default: 1),
                parallaxDepth: vec(object["parallaxDepth"]),
                visible: object["visible"] as? Bool ?? true,
                blending: object["blending"] as? String,
                shader: object["shader"] as? String
            ))
        }
        return SceneDocument(
            orthoWidth: int(ortho["width"]),
            orthoHeight: int(ortho["height"]),
            clearColor: clearColor,
            layers: layers
        )
    }

    /// image (model json) → material json → first texture name → `materials/<name>.tex`.
    static func resolveTexture(imagePath: String, in package: ScenePackage) -> String? {
        guard let model = json(package.entry(named: imagePath)),
              let materialPath = model["material"] as? String,
              let material = json(package.entry(named: materialPath)),
              let passes = material["passes"] as? [[String: Any]] else { return nil }
        for pass in passes {
            if let textures = pass["textures"] as? [Any] {
                for case let name as String in textures where !name.isEmpty {
                    return "materials/\(name).tex"
                }
            }
        }
        return nil
    }

    // MARK: - Defensive JSON helpers

    private static func json(_ entry: ScenePackageEntry?) -> [String: Any]? {
        guard let entry else { return nil }
        return (try? JSONSerialization.jsonObject(with: entry.data)) as? [String: Any]
    }
    private static func vec(_ value: Any?, default fallback: SceneVec3 = SceneVec3(x: 0, y: 0, z: 0)) -> SceneVec3 {
        (value as? String).map(SceneVec3.init(parsing:)) ?? fallback
    }
    private static func number(_ value: Any?, default fallback: Double) -> Double {
        (value as? NSNumber)?.doubleValue ?? fallback
    }
    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
