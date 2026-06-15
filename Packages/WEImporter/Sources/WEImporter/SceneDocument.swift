// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Parses a Wallpaper Engine scene graph (scene.json + the model/material JSON
// it references, structure observed in the user's OWN packages) into a flat list of renderable image
// layers, resolving each object's image → model → material → ".tex" texture path. No GPL source used.
import Foundation

/// A 3-component vector parsed from WE's space-separated string encoding (e.g. `"1920.000 1080.000 0"`).
public struct SceneVec3: Sendable, Equatable {
    public let x: Double, y: Double, z: Double

    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }

    /// Parse `"x y z"` (missing components default to 0). Non-finite components (`nan`, `inf`, an
    /// overflowing literal) parse to 0 — a NaN/Inf would silently make a layer's quad vanish.
    public init(parsing string: String) {
        let parts = string.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { part -> Double in
            let value = Double(part) ?? 0
            return value.isFinite ? value : 0
        }
        x = parts.count > 0 ? parts[0] : 0
        y = parts.count > 1 ? parts[1] : 0
        z = parts.count > 2 ? parts[2] : 0
    }
}

/// One keyframe of an animated property: a value at a frame number.
public struct AlphaKeyframe: Sendable, Equatable {
    public let frame: Double
    public let value: Double
    public init(frame: Double, value: Double) { self.frame = frame; self.value = value }
}

/// A looping keyframe animation for a layer's alpha — what drives the cross-fading frame-by-frame
/// "sprite" scenes. Evaluated at a wall-clock time to the alpha for that instant.
public struct AlphaAnimation: Sendable, Equatable {
    public let keyframes: [AlphaKeyframe]   // sorted by frame
    public let fps: Double
    public let length: Double

    public init(keyframes: [AlphaKeyframe], fps: Double, length: Double) {
        self.keyframes = keyframes
        self.fps = fps
        self.length = length
    }

    /// The (linearly-interpolated, looping) alpha at `time` seconds.
    public func value(at time: Double) -> Double {
        guard let first = keyframes.first, let last = keyframes.last, fps > 0, length > 0 else { return 1 }
        let frame = (time * fps).truncatingRemainder(dividingBy: length)
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        for index in 0 ..< (keyframes.count - 1) {
            let a = keyframes[index], b = keyframes[index + 1]
            if frame >= a.frame, frame <= b.frame {
                let span = b.frame - a.frame
                let t = span > 0 ? (frame - a.frame) / span : 0
                return a.value + (b.value - a.value) * t
            }
        }
        return last.value
    }
}

/// A per-component (x/y/z) keyframe animation — e.g. an animated position. Each axis reuses the scalar
/// keyframe curve. The motion is reported relative to time 0, so a still frame is unchanged.
public struct Vec3Animation: Sendable, Equatable {
    public let x: AlphaAnimation?
    public let y: AlphaAnimation?
    public let z: AlphaAnimation?

    public init(x: AlphaAnimation?, y: AlphaAnimation?, z: AlphaAnimation?) {
        self.x = x; self.y = y; self.z = z
    }

    /// The (x, y) offset at `time` relative to time 0 (z ignored by the 2-D compositor).
    public func offset(at time: Double) -> (x: Double, y: Double) {
        ((x?.value(at: time) ?? 0) - (x?.value(at: 0) ?? 0),
         (y?.value(at: time) ?? 0) - (y?.value(at: 0) ?? 0))
    }
}

/// A post-process effect applied to a layer (pulse, blur, tint, water…): the shader to run and the
/// constant uniform values to feed it, keyed by the shader's `ui_editor_properties_*` annotation.
public struct LayerEffect: Sendable, Equatable {
    public let name: String
    public let fragmentShaderPath: String   // e.g. "shaders/effects/pulse.frag"
    public let vertexShaderPath: String     // e.g. "shaders/effects/pulse.vert"
    public let constants: [String: String]  // property key → value (number or space-separated vector)
    public let combos: [String: Int]        // combo selections (e.g. BLENDMODE) — override shader defaults

    public init(name: String, fragmentShaderPath: String, vertexShaderPath: String,
                constants: [String: String], combos: [String: Int] = [:]) {
        self.name = name
        self.fragmentShaderPath = fragmentShaderPath
        self.vertexShaderPath = vertexShaderPath
        self.constants = constants
        self.combos = combos
    }
}

/// One renderable image layer of a scene: the texture to draw and where/how to draw it.
public struct SceneLayer: Sendable, Equatable {
    public let name: String
    /// In-package path of the layer's base texture (e.g. `"materials/foo.tex"`), or nil if unresolved.
    public let texturePath: String?
    /// True for a built-in solid-colour fill (a `solidlayer` util model with no packed texture); the
    /// layer is drawn from `color` alone.
    public let isSolidLayer: Bool
    public let origin: SceneVec3
    public let scale: SceneVec3
    /// The layer's size in scene units (`"width height"`), or nil to fall back to the texture's size.
    public let size: SceneVec3?
    public let angles: SceneVec3
    public let alpha: Double
    /// The object's colour tint, multiplied into the texture (white = no tint; also the fill colour
    /// for a solid layer).
    public let color: SceneVec3
    /// A keyframe animation for the layer's alpha, if it has one (overrides `alpha` over time).
    public let alphaAnimation: AlphaAnimation?
    /// A keyframe animation for the layer's position, if it has one (a drift added to `origin`).
    public let originAnimation: Vec3Animation?
    public let parallaxDepth: SceneVec3
    public let visible: Bool
    public let blending: String?
    public let shader: String?
    /// Post-process effects applied to the layer, in order.
    public let effects: [LayerEffect]
}

/// A parsed scene: its orthographic size, clear colour and ordered image layers (painter's order).
public struct RenderableScene: Sendable, Equatable {
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

/// Builds a `RenderableScene` from a `ScenePackage` by reading scene.json and following each image
/// object through its model and material to the texture it draws.
public enum SceneGraph {
    public static func load(from package: ScenePackage) throws -> RenderableScene {
        guard let sceneEntry = package.sceneJSON else { throw SceneGraphError.missingSceneJSON }
        guard let root = (try? JSONSerialization.jsonObject(with: sceneEntry.data)) as? [String: Any]
        else { throw SceneGraphError.invalidSceneJSON }

        let general = root["general"] as? [String: Any] ?? [:]
        let ortho = general["orthogonalprojection"] as? [String: Any] ?? [:]
        let clearColor = SceneVec3(parsing: general["clearcolor"] as? String ?? "0 0 0")

        var layers: [SceneLayer] = []
        for object in root["objects"] as? [[String: Any]] ?? [] {
            guard let imagePath = object["image"] as? String, !imagePath.isEmpty else { continue }
            let material = resolveMaterial(imagePath: imagePath, in: package)
            layers.append(SceneLayer(
                name: object["name"] as? String ?? "",
                texturePath: material.texture,
                isSolidLayer: imagePath.contains("solidlayer"),
                origin: originVec(object["origin"]),
                scale: vec(object["scale"], default: SceneVec3(x: 1, y: 1, z: 1)),
                size: (object["size"] as? String).map(SceneVec3.init(parsing:)),
                angles: vec(object["angles"]),
                alpha: alphaValue(object["alpha"]),
                color: vec(object["color"], default: SceneVec3(x: 1, y: 1, z: 1)),
                alphaAnimation: alphaAnimation(object["alpha"]),
                originAnimation: vec3Animation(object["origin"]),
                parallaxDepth: vec(object["parallaxDepth"]),
                visible: object["visible"] as? Bool ?? true,
                blending: material.blending,
                shader: material.shader,
                effects: effects(of: object, in: package)
            ))
        }
        return RenderableScene(
            orthoWidth: int(ortho["width"]),
            orthoHeight: int(ortho["height"]),
            clearColor: clearColor,
            layers: layers
        )
    }

    /// image (model json) → material json → its first pass's texture, blending and shader. The texture
    /// name resolves to `materials/<name>.tex`.
    static func resolveMaterial(imagePath: String, in package: ScenePackage)
        -> (texture: String?, blending: String?, shader: String?) {
        guard let model = json(package.entry(named: imagePath)),
              let materialPath = model["material"] as? String,
              let material = json(package.entry(named: materialPath)),
              let pass = (material["passes"] as? [[String: Any]])?.first else { return (nil, nil, nil) }
        var texture: String?
        if let textures = pass["textures"] as? [Any] {
            for case let name as String in textures where !name.isEmpty {
                texture = "materials/\(name).tex"
                break
            }
        }
        return (texture, pass["blending"] as? String, pass["shader"] as? String)
    }

    /// Resolve a layer's post-process effects: each `object.effects[i].file` → effect.json → material →
    /// shader path, with the constant uniform values from the effect's `constantshadervalues`.
    static func effects(of object: [String: Any], in package: ScenePackage) -> [LayerEffect] {
        guard let entries = object["effects"] as? [[String: Any]] else { return [] }
        var result: [LayerEffect] = []
        for entry in entries {
            guard let file = entry["file"] as? String,
                  let effect = json(package.entry(named: file)),
                  let materialPath = (effect["passes"] as? [[String: Any]])?.first?["material"] as? String,
                  let material = json(package.entry(named: materialPath)),
                  let shader = (material["passes"] as? [[String: Any]])?.first?["shader"] as? String else { continue }
            var constants: [String: String] = [:]
            if let pass = (entry["passes"] as? [[String: Any]])?.first,
               let values = pass["constantshadervalues"] as? [String: Any] {
                for (key, value) in values where constantString(value) != nil {
                    constants[key] = constantString(value)
                }
            }
            // Combo selections (e.g. the blend mode): the material declares them, the scene's effect pass
            // overrides — so an effect renders the mode the wallpaper picked, not just the shader default.
            var combos: [String: Int] = [:]
            for source in [(material["passes"] as? [[String: Any]])?.first?["combos"] as? [String: Any],
                           (entry["passes"] as? [[String: Any]])?.first?["combos"] as? [String: Any]] {
                for (key, value) in source ?? [:] {
                    if let intValue = (value as? NSNumber)?.intValue { combos[key] = intValue }
                }
            }
            let name = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
            result.append(LayerEffect(
                name: name.isEmpty ? file : name,
                fragmentShaderPath: "shaders/\(shader).frag",
                vertexShaderPath: "shaders/\(shader).vert",
                constants: constants, combos: combos))
        }
        return result
    }

    private static func constantString(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// `alpha` is either a number or an animated `{ "value": Double, … }` object — take its base value
    /// (non-finite → 1).
    private static func alphaValue(_ value: Any?) -> Double {
        let raw: Double?
        if let number = value as? NSNumber { raw = number.doubleValue }
        else if let object = value as? [String: Any], let base = object["value"] as? NSNumber { raw = base.doubleValue }
        else { raw = nil }
        guard let raw, raw.isFinite else { return 1 }
        return raw
    }

    /// The keyframe animation under an `alpha` object's `animation.c0`, if present.
    private static func alphaAnimation(_ value: Any?) -> AlphaAnimation? {
        guard let object = value as? [String: Any],
              let animation = object["animation"] as? [String: Any],
              let curve = animation["c0"] as? [[String: Any]] else { return nil }
        let options = animation["options"] as? [String: Any] ?? [:]
        let fps = (options["fps"] as? NSNumber)?.doubleValue ?? 30
        let length = (options["length"] as? NSNumber)?.doubleValue ?? 0
        let keyframes = curve.compactMap { keyframe -> AlphaKeyframe? in
            guard let frame = (keyframe["frame"] as? NSNumber)?.doubleValue,
                  let value = (keyframe["value"] as? NSNumber)?.doubleValue,
                  frame.isFinite, value.isFinite else { return nil }
            return AlphaKeyframe(frame: frame, value: value)
        }.sorted { $0.frame < $1.frame }
        guard !keyframes.isEmpty, length > 0, length.isFinite, fps.isFinite else { return nil }
        return AlphaAnimation(keyframes: keyframes, fps: fps, length: length)
    }

    /// A position/scale value that may be a plain `"x y z"` string or an animated `{ "value": "x y z",
    /// "animation": … }` object — take the base value either way.
    private static func originVec(_ value: Any?) -> SceneVec3 {
        if let string = value as? String { return SceneVec3(parsing: string) }
        if let object = value as? [String: Any], let string = object["value"] as? String {
            return SceneVec3(parsing: string)
        }
        return SceneVec3(x: 0, y: 0, z: 0)
    }

    /// The per-axis keyframe animation under a value's `animation.c0/c1/c2`, if present.
    private static func vec3Animation(_ value: Any?) -> Vec3Animation? {
        guard let object = value as? [String: Any],
              let animation = object["animation"] as? [String: Any] else { return nil }
        let options = animation["options"] as? [String: Any] ?? [:]
        let fps = (options["fps"] as? NSNumber)?.doubleValue ?? 30
        let length = (options["length"] as? NSNumber)?.doubleValue ?? 0
        func curve(_ key: String) -> AlphaAnimation? {
            guard let frames = animation[key] as? [[String: Any]], length > 0, length.isFinite, fps.isFinite else { return nil }
            let keyframes = frames.compactMap { keyframe -> AlphaKeyframe? in
                guard let frame = (keyframe["frame"] as? NSNumber)?.doubleValue,
                      let value = (keyframe["value"] as? NSNumber)?.doubleValue,
                      frame.isFinite, value.isFinite else { return nil }
                return AlphaKeyframe(frame: frame, value: value)
            }.sorted { $0.frame < $1.frame }
            guard !keyframes.isEmpty else { return nil }
            return AlphaAnimation(keyframes: keyframes, fps: fps, length: length)
        }
        let x = curve("c0"), y = curve("c1"), z = curve("c2")
        guard x != nil || y != nil || z != nil else { return nil }
        return Vec3Animation(x: x, y: y, z: z)
    }

    // MARK: - Defensive JSON helpers

    private static func json(_ entry: ScenePackageEntry?) -> [String: Any]? {
        guard let entry else { return nil }
        return (try? JSONSerialization.jsonObject(with: entry.data)) as? [String: Any]
    }
    private static func vec(_ value: Any?, default fallback: SceneVec3 = SceneVec3(x: 0, y: 0, z: 0)) -> SceneVec3 {
        (value as? String).map(SceneVec3.init(parsing:)) ?? fallback
    }
    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
