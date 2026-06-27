// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Parses a Wallpaper Engine scene graph (scene.json + the model/material JSON
// it references, structure observed in the user's OWN packages) into a flat list of renderable image
// layers, resolving each object's image → model → material → ".tex" texture path. No GPL source used.
import Foundation
import WECore

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
    /// WE's `single` mode plays the curve once and HOLDS the last keyframe; `loop` mode wraps. A non-looping
    /// animation must not wrap, or a finished intro fade snaps back to its first value at every multiple of
    /// `length` (a one-shot 0→1 fade-in would blink invisible forever).
    public let isLooping: Bool

    public init(keyframes: [AlphaKeyframe], fps: Double, length: Double, isLooping: Bool = true) {
        self.keyframes = keyframes
        self.fps = fps
        self.length = length
        self.isLooping = isLooping
    }

    /// The linearly-interpolated alpha at `time` seconds — wrapping for a loop animation, holding the last
    /// keyframe past `length` for a single (play-once) one.
    public func value(at time: Double) -> Double {
        guard let first = keyframes.first, let last = keyframes.last, fps > 0, length > 0 else { return 1 }
        let frame = isLooping ? (time * fps).truncatingRemainder(dividingBy: length) : (time * fps)
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
/// One render pass of a (possibly multi-pass) effect: a shader, its combos and aux sampler bindings, the
/// named render target it writes (nil = the effect's output), and which input each sampler reads.
public struct EffectPass: Sendable, Equatable {
    public let fragmentShaderPath: String
    public let vertexShaderPath: String
    public let combos: [String: Int]
    public let textures: [String?]      // material's sampler bindings (aux), by index
    public let target: String?          // named FBO this pass renders into; nil = the effect output (full size)
    public let binds: [EffectBind]      // input name (`previous` = the effect input, or an FBO) → sampler index

    public init(fragmentShaderPath: String, vertexShaderPath: String, combos: [String: Int] = [:],
                textures: [String?] = [], target: String? = nil, binds: [EffectBind] = []) {
        self.fragmentShaderPath = fragmentShaderPath
        self.vertexShaderPath = vertexShaderPath
        self.combos = combos
        self.textures = textures
        self.target = target
        self.binds = binds
    }
}

/// A pass input binding: which named texture feeds which sampler slot (g_Texture<index>).
public struct EffectBind: Sendable, Equatable {
    public let name: String   // `previous` = the effect's input, or a named FBO
    public let index: Int     // g_Texture<index>
    public init(name: String, index: Int) { self.name = name; self.index = index }
}

/// An intermediate render target an effect declares: a name, a downscale factor (1 = full, 4 = quarter),
/// and a pixel format token (`rgba_backbuffer`, `rgb161616f`, …).
public struct EffectFBO: Sendable, Equatable {
    public let name: String
    public let scale: Int
    public let format: String
    public init(name: String, scale: Int, format: String) { self.name = name; self.scale = scale; self.format = format }
}

public struct LayerEffect: Sendable, Equatable {
    public let name: String
    public let fragmentShaderPath: String   // e.g. "shaders/effects/pulse.frag" — the first pass's shader
    public let vertexShaderPath: String     // e.g. "shaders/effects/pulse.vert"
    public let constants: [String: String]  // property key → value (number or space-separated vector)
    public let combos: [String: Int]        // combo selections (e.g. BLENDMODE) — override shader defaults
    public let textures: [String?]          // material's sampler bindings by index (g_Texture0 = nil/framebuffer)
    public let passes: [EffectPass]          // the full pass graph (single-pass effects have one)
    public let fbos: [EffectFBO]             // the intermediate render targets the passes wire together

    public init(name: String, fragmentShaderPath: String, vertexShaderPath: String,
                constants: [String: String], combos: [String: Int] = [:], textures: [String?] = [],
                passes: [EffectPass] = [], fbos: [EffectFBO] = []) {
        self.name = name
        self.fragmentShaderPath = fragmentShaderPath
        self.vertexShaderPath = vertexShaderPath
        self.constants = constants
        self.combos = combos
        self.textures = textures
        self.passes = passes
        self.fbos = fbos
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
    /// Which point of the layer sits at `origin`: "center" (default), or an edge/corner like "bottomleft",
    /// "topright", "left", "bottom"… WE anchors the layer there; the renderer shifts the quad accordingly.
    public let alignment: String?
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
    /// Keyframe animations for the layer's scale / rotation / colour tint, if present. Parsed into the IR and
    /// IR-tested here; the renderer applies the alpha + origin animations today and will consume these once the
    /// per-property animation path lands (their exact relative-vs-absolute semantics want a visual check first).
    public let scaleAnimation: Vec3Animation?
    public let anglesAnimation: Vec3Animation?
    public let colorAnimation: Vec3Animation?
    public let parallaxDepth: SceneVec3
    public let visible: Bool
    public let blending: String?
    /// Wallpaper Engine's per-object `colorBlendMode` (a Photoshop-style blend enum) as its raw value, 0 when
    /// absent. 0 = Normal (fall through to the material's own blend); 31 = Additive (also surfaced via
    /// `blending == "additive"` for the fast path). Other values (2 = Multiply, 6 = Lighten, 7 = Screen,
    /// 11 = Overlay, 12 = SoftLight, 21 = Reflect, 22 = Glow, 23 = Phoenix, 30 = Tint, …) select a per-channel
    /// composite the renderer applies against the destination, overriding the material blend.
    public let colorBlendMode: Int
    public let shader: String?
    /// Post-process effects applied to the layer, in order.
    public let effects: [LayerEffect]
    /// In-package path of the layer's puppet mesh (`…_puppet.mdl`), if the object is puppet-rigged. The
    /// renderer draws this skeletal mesh (assembled from the sprite atlas) instead of a flat quad.
    public let puppetPath: String?
    /// A text layer's content/styling, if this object is text (a clock, label, …) rather than an image.
    /// `textValue` is the static string; `textScript` is the SceneScript that drives it per frame (a clock).
    public let textValue: String?
    public let textScript: String?
    public let fontPath: String?          // in-package path of the .ttf (e.g. "fonts/RobotoMono-Regular.ttf")
    public let pointSize: Double          // font point size in scene units
    public let horizontalAlign: String?   // "left" | "center" | "right"
    public let verticalAlign: String?     // "top" | "center" | "bottom"
    /// True when this object is a text layer (drawn from rendered glyphs, not a packed texture).
    public var isTextLayer: Bool { textValue != nil || textScript != nil }
    /// A SceneScript bound to one of this object's properties (visible / scale / origin) that manipulates the
    /// scene graph rather than returning a value — an audio visualiser clones this layer into N bars and drives
    /// each bar's height from the spectrum. The renderer runs it per frame and draws the layers it produces.
    public let driverScript: String?
    /// The Wallpaper Engine object id, when known. Composition layers reference other layers by this id through
    /// their `dependencies`, so the renderer needs it to find which layers a composition layer consumes.
    public let objectID: Int?
    /// True when this object is a WE built-in composition layer (`models/util/{project,compose,fullscreen,effect}layer.json`):
    /// it has no image of its own and instead processes the scene composited so far (or its `dependencies`) through
    /// its effect chain and recomposites the result. Drawn specially by the renderer, never as a plain quad.
    public let isCompositionLayer: Bool
    /// For a composition layer, the object ids it consumes as input (its `dependencies`). Those layers feed this
    /// layer's effect chain instead of being drawn directly. Empty when the layer reads the whole scene composite.
    public let dependencyIDs: [Int]

    public init(name: String, texturePath: String?, isSolidLayer: Bool, origin: SceneVec3, scale: SceneVec3,
                size: SceneVec3?, angles: SceneVec3, alpha: Double, color: SceneVec3,
                alphaAnimation: AlphaAnimation?, originAnimation: Vec3Animation?,
                scaleAnimation: Vec3Animation? = nil, anglesAnimation: Vec3Animation? = nil,
                colorAnimation: Vec3Animation? = nil, parallaxDepth: SceneVec3,
                visible: Bool, blending: String?, colorBlendMode: Int = 0, shader: String?, effects: [LayerEffect], puppetPath: String? = nil,
                textValue: String? = nil, textScript: String? = nil, fontPath: String? = nil,
                pointSize: Double = 32, horizontalAlign: String? = nil, verticalAlign: String? = nil,
                driverScript: String? = nil, alignment: String? = nil,
                objectID: Int? = nil, isCompositionLayer: Bool = false, dependencyIDs: [Int] = []) {
        self.name = name
        self.texturePath = texturePath
        self.isSolidLayer = isSolidLayer
        self.origin = origin
        self.scale = scale
        self.size = size
        self.angles = angles
        self.alpha = alpha
        self.color = color
        self.alphaAnimation = alphaAnimation
        self.originAnimation = originAnimation
        self.scaleAnimation = scaleAnimation
        self.anglesAnimation = anglesAnimation
        self.colorAnimation = colorAnimation
        self.parallaxDepth = parallaxDepth
        self.visible = visible
        self.blending = blending
        self.colorBlendMode = colorBlendMode
        self.shader = shader
        self.effects = effects
        self.puppetPath = puppetPath
        self.textValue = textValue
        self.textScript = textScript
        self.fontPath = fontPath
        self.pointSize = pointSize
        self.horizontalAlign = horizontalAlign
        self.verticalAlign = verticalAlign
        self.driverScript = driverScript
        self.alignment = alignment
        self.objectID = objectID
        self.isCompositionLayer = isCompositionLayer
        self.dependencyIDs = dependencyIDs
    }
}

/// A parsed scene: its orthographic size, clear colour and ordered image layers (painter's order).
public struct RenderableScene: Sendable, Equatable {
    public let orthoWidth: Int
    public let orthoHeight: Int
    public let clearColor: SceneVec3
    public let layers: [SceneLayer]
    public let particleSystems: [ParticleSystem]
    /// True when any object is a puppet-rigged model (it references a bone/mesh `.mdl`). Such a scene
    /// needs skeletal mesh deformation the renderer doesn't do yet, so drawing its layer atlas raw shows
    /// scattered body parts — the player shows the static preview instead.
    public let usesPuppet: Bool
    /// Scene-level bloom (`general.bloom`): strength scales the additive glow, threshold is the luma above
    /// which a pixel blooms. Strength 0 (the default, and most scenes) means no bloom — the renderer skips the
    /// extra pass entirely, so those scenes are unaffected.
    public let bloomStrength: Double
    public let bloomThreshold: Double

    public init(orthoWidth: Int, orthoHeight: Int, clearColor: SceneVec3,
                layers: [SceneLayer], particleSystems: [ParticleSystem] = [], usesPuppet: Bool = false,
                bloomStrength: Double = 0, bloomThreshold: Double = 0.8) {
        self.orthoWidth = orthoWidth
        self.orthoHeight = orthoHeight
        self.clearColor = clearColor
        self.layers = layers
        self.particleSystems = particleSystems
        self.usesPuppet = usesPuppet
        self.bloomStrength = bloomStrength
        self.bloomThreshold = bloomThreshold
    }
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
    /// `overrides` are the viewer's per-property values from the Customize panel, keyed by the WE property
    /// name (`schemecolor`, `promptbox`, `rain`, `time`, …). A property the author wired to a user value with
    /// `{ "user": <name>, "value": <default> }` takes the saved override of <name> when one exists — colours,
    /// sliders and visibility toggles alike — so the wallpaper shows what the user configured, not the author's
    /// default. An empty map (the default) reproduces the scene exactly as authored.
    public static func load(from package: ScenePackage, overrides: [String: PropertyValue] = [:]) throws -> RenderableScene {
        guard let sceneEntry = package.sceneJSON else { throw SceneGraphError.missingSceneJSON }
        guard let root = (try? JSONSerialization.jsonObject(with: sceneEntry.data)) as? [String: Any]
        else { throw SceneGraphError.invalidSceneJSON }

        let general = root["general"] as? [String: Any] ?? [:]
        let ortho = general["orthogonalprojection"] as? [String: Any] ?? [:]
        // The scene's half-extents — the fallback spawn box for a boxrandom particle emitter that ships no
        // distancemax (so its sprites spread across the wallpaper like Wallpaper Engine, not pile at a point).
        let sceneBox = SceneVec3(x: Double(int(ortho["width"])) / 2, y: Double(int(ortho["height"])) / 2, z: 0)
        let clearColor = SceneVec3(parsing: general["clearcolor"] as? String ?? "0 0 0")
        // Scene-level bloom: only when the flag is on AND the strength is meaningful (many scenes ship
        // `bloom:true` with strength 0). Clamp both against malformed values.
        let bloomOn = (general["bloom"] as? Bool) == true || (general["bloom"] as? NSNumber)?.boolValue == true
        let bloomStrength = bloomOn ? min(8, max(0, (general["bloomstrength"] as? NSNumber)?.doubleValue ?? 0)) : 0
        let bloomThreshold = min(1, max(0, (general["bloomthreshold"] as? NSNumber)?.doubleValue ?? 0.8))

        var layers: [SceneLayer] = []
        var particleSystems: [ParticleSystem] = []
        var usesPuppet = false

        // WE objects form a transform hierarchy: a child carries a `parent` (object id) and its origin/scale/
        // angle are relative to the parent's world transform. Flattening each object with its local transform
        // as absolute would scatter every parented layer (a character anchored to an off-screen holder lands
        // off-screen). Index objects by id and compose the full 2-D world transform up the parent chain — the
        // child offset is scaled then rotated into the parent's frame, and the parent's scale/angle compound
        // into the child's. A depth cap guards against cyclic `parent` ids. Unparented objects return their
        // local transform unchanged (byte-identical to before).
        let objects = root["objects"] as? [[String: Any]] ?? []
        var objectsByID: [Int: [String: Any]] = [:]
        for object in objects where (object["id"] as? NSNumber) != nil {
            objectsByID[(object["id"] as! NSNumber).intValue] = object
        }
        func worldTransform(_ object: [String: Any], _ depth: Int)
            -> (origin: SceneVec3, angle: Double, scale: SceneVec3) {
            let localOrigin = originVec(object["origin"])
            let localAngle = vec(object["angles"]).z   // screen-plane rotation (radians)
            let localScale = vec(object["scale"], default: SceneVec3(x: 1, y: 1, z: 1))
            guard depth < 16, let pid = (object["parent"] as? NSNumber)?.intValue,
                  pid != (object["id"] as? NSNumber)?.intValue, let parent = objectsByID[pid]
            else { return (localOrigin, localAngle, localScale) }
            let p = worldTransform(parent, depth + 1)
            let sx = p.scale.x * localOrigin.x, sy = p.scale.y * localOrigin.y
            let ca = cos(p.angle), sa = sin(p.angle)
            let origin = SceneVec3(x: p.origin.x + (sx * ca - sy * sa),
                                   y: p.origin.y + (sx * sa + sy * ca),
                                   z: p.origin.z + p.scale.z * localOrigin.z)
            let scale = SceneVec3(x: p.scale.x * localScale.x, y: p.scale.y * localScale.y, z: p.scale.z * localScale.z)
            return (origin, p.angle + localAngle, scale)
        }
        func worldOrigin(_ object: [String: Any], _ depth: Int) -> SceneVec3 { worldTransform(object, depth).origin }

        for object in objects {
            // A now-playing media widget (album-art tile, vinyl disc, progress bar, song-title/artist text,
            // play/pause icons, panel background) shows a placeholder graphic until music plays. Lumora has no
            // media playback, so its steady state is the hidden widget — exactly like Wallpaper Engine with
            // nothing playing. Skip the whole layer. This generalises the visibility-script case (handled in
            // isVisible) to widgets whose visibility is ungated but whose graphic only means anything with music.
            if isMediaPlayerWidget(object) { continue }
            // A particle object spawns sprites instead of drawing an image; collect it (and any child
            // sub-emitters — an ember's glow, a shooting-star's trail, a magic charge's rays — which WE
            // spawns alongside the parent) and move on.
            if let particlePath = object["particle"] as? String,
               isVisible(object["visible"], overrides: overrides),
               let particleJSON = json(package.entry(named: particlePath)) {
                let objectOrigin = worldOrigin(object, 0)
                particleSystems.append(contentsOf:
                    collectParticleSystems(from: particleJSON, at: objectOrigin, in: package, depth: 0, sceneBox: sceneBox))
                continue
            }
            // A text object (clock, label, counter, …) draws rendered glyphs, not a packed texture. Its
            // `text` is a value-or-`{value, script}` field; the script drives it per frame (e.g. a clock).
            if let textField = object["text"] {
                let value = (textField as? [String: Any])?["value"] as? String ?? (textField as? String)
                let script = (textField as? [String: Any])?["script"] as? String
                if value != nil || script != nil {
                    // The point size comes straight from untrusted scene.json; a non-finite value (e.g.
                    // an overflowing `1e400`) or a wild one would make the text layer's glyph quads vanish
                    // or balloon. Keep it finite and within a sane range, defaulting like a missing field.
                    let rawPointSize = Self.scalar(object["pointsize"], default: 32, overrides: overrides)
                    let pointSize = rawPointSize.isFinite ? min(4096, max(0, rawPointSize)) : 32
                    layers.append(SceneLayer(
                        name: object["name"] as? String ?? "",
                        texturePath: nil, isSolidLayer: false,
                        origin: worldOrigin(object, 0),
                        scale: vec(object["scale"], default: SceneVec3(x: 1, y: 1, z: 1)),
                        size: (object["size"] as? String).map(SceneVec3.init(parsing:)),
                        angles: vec(object["angles"]),
                        alpha: alphaValue(object["alpha"], overrides: overrides),
                        color: vec(object["color"], default: SceneVec3(x: 1, y: 1, z: 1), overrides: overrides),
                        alphaAnimation: alphaAnimation(object["alpha"]),
                        originAnimation: vec3Animation(object["origin"]),
                        scaleAnimation: vec3Animation(object["scale"]),
                        anglesAnimation: vec3Animation(object["angles"]),
                        colorAnimation: vec3Animation(object["color"]),
                        parallaxDepth: vec(object["parallaxDepth"]),
                        // Hide un-customised template placeholders and author self-promo watermarks (a static
                        // "customizable text" / social-handle string) — never a real title or a scripted clock.
                        visible: isVisible(object["visible"], overrides: overrides)
                            && !(script == nil && Self.isTemplateJunkText(value)),
                        blending: nil, shader: nil, effects: [],
                        textValue: value, textScript: script,
                        fontPath: object["font"] as? String,
                        pointSize: pointSize,
                        horizontalAlign: object["horizontalalign"] as? String,
                        verticalAlign: object["verticalalign"] as? String))
                    continue
                }
            }
            guard let imagePath = object["image"] as? String, !imagePath.isEmpty else { continue }
            let material = resolveMaterial(imagePath: imagePath, in: package)
            // A puppet object references a bone/mesh model (on the object, or inside its model JSON). Capture
            // the `.mdl` path so the renderer can draw the assembled mesh; flag the scene either way so the
            // player still falls back to the static preview for puppets the renderer can't yet assemble.
            let modelJSON = json(package.entry(named: imagePath))
            let puppetPath = (object["puppet"] as? String) ?? (modelJSON?["puppet"] as? String)
            // Flag the scene as puppet-rigged whenever a puppet reference EXISTS in any form — not only when
            // it casts to a String path. A variant-shaped reference that failed the cast would otherwise drop
            // the preview fallback and leave the renderer drawing the raw atlas as scattered parts.
            if object["puppet"] != nil || modelJSON?["puppet"] != nil { usesPuppet = true }
            // Compose the full world transform so a parented image inherits its parent's placement, scale and
            // rotation (the child's own angle x/y are kept; only the screen-plane z is compounded).
            let wt = worldTransform(object, 0)
            let localAngles = vec(object["angles"])
            // A per-object `colorBlendMode` (Wallpaper Engine's Photoshop-style layer blend) overrides the
            // material pass's `blending` string. When it denotes an additive/glow blend, honour that — a glow
            // (lens flare, light outline) composited as plain alpha-over paints its dark backing field over
            // the scene instead of glowing through it, which on a full-screen layer blacks the frame out.
            let blendOverride = Self.additiveColorBlendMode(object["colorBlendMode"]) ? "additive" : nil
            // A WE composition layer (models/util/{project,compose,fullscreen,effect}layer.json) has no texture of
            // its own; it reprojects/post-processes the scene through its effects. Capture the object id and the
            // `dependencies` (the ids of the layers it consumes as input) so the renderer can drive it.
            let isComp = Self.isCompositionImage(imagePath)
            layers.append(SceneLayer(
                name: object["name"] as? String ?? "",
                texturePath: material.texture,
                isSolidLayer: imagePath.contains("solidlayer"),
                origin: wt.origin,
                scale: wt.scale,
                size: (object["size"] as? String).map(SceneVec3.init(parsing:)),
                angles: SceneVec3(x: localAngles.x, y: localAngles.y, z: wt.angle),
                alpha: alphaValue(object["alpha"], overrides: overrides),
                color: vec(object["color"], default: SceneVec3(x: 1, y: 1, z: 1), overrides: overrides),
                alphaAnimation: alphaAnimation(object["alpha"]),
                originAnimation: vec3Animation(object["origin"]),
                scaleAnimation: vec3Animation(object["scale"]),
                anglesAnimation: vec3Animation(object["angles"]),
                colorAnimation: vec3Animation(object["color"]),
                parallaxDepth: vec(object["parallaxDepth"]),
                visible: isVisible(object["visible"], overrides: overrides),
                blending: blendOverride ?? material.blending,
                colorBlendMode: Self.colorBlendModeValue(object["colorBlendMode"]),
                shader: material.shader,
                effects: effects(of: object, in: package, overrides: overrides),
                puppetPath: puppetPath,
                driverScript: boundScript(of: object, in: package),
                alignment: object["alignment"] as? String,
                objectID: (object["id"] as? NSNumber)?.intValue,
                isCompositionLayer: isComp,
                dependencyIDs: isComp ? Self.parseDependencyIDs(object["dependencies"]) : []
            ))
        }
        return RenderableScene(
            orthoWidth: int(ortho["width"]),
            orthoHeight: int(ortho["height"]),
            clearColor: clearColor,
            layers: layers,
            particleSystems: particleSystems,
            usesPuppet: usesPuppet,
            bloomStrength: bloomStrength,
            bloomThreshold: bloomThreshold
        )
    }

    /// Whether an object's `colorBlendMode` denotes an additive/glow composite (Wallpaper Engine's per-object
    /// blend, which overrides the material's `blending`). WE's modes are a Photoshop-style enum; mode 31 is the
    /// additive glow used by lens flares and light "outline" layers across this library, and is the only value
    /// that visibly breaks under our default alpha-over (its dark backing field paints over the scene). Every
    /// other value falls through to the material's own blend, preserving today's behaviour — unmapped modes
    /// (normal, the darken/multiply family, etc.) are not yet distinguished from their material default.
    static func additiveColorBlendMode(_ raw: Any?) -> Bool {
        guard let mode = (raw as? NSNumber)?.intValue else { return false }
        return mode == 31
    }

    /// The raw `colorBlendMode` value (Wallpaper Engine's Photoshop-style blend enum), or 0 (Normal) when the
    /// field is absent or unparseable. The renderer maps non-zero values to a per-channel composite.
    static func colorBlendModeValue(_ raw: Any?) -> Int {
        (raw as? NSNumber)?.intValue ?? 0
    }

    /// Whether an `image` path is a Wallpaper Engine built-in composition-layer model. These live under
    /// `models/util/` and carry no packed texture; the object instead reprojects or post-processes the scene
    /// (or the layers named in its `dependencies`) through its effect chain. WE ships projectlayer (re-projection
    /// / parallax of its dependency composite), composelayer and fullscreenlayer (post-process over the composite),
    /// and effectlayer. The renderer draws these specially rather than skipping them as unresolved image layers.
    static func isCompositionImage(_ imagePath: String) -> Bool {
        guard imagePath.hasPrefix("models/util/") else { return false }
        return imagePath.contains("projectlayer") || imagePath.contains("composelayer")
            || imagePath.contains("fullscreenlayer") || imagePath.contains("effectlayer")
    }

    /// Parse a composition layer's `dependencies` — the WE object ids of the layers it consumes as its input.
    /// A bare list of numbers in practice; tolerate `{ "id": N }` shapes and ignore anything non-numeric.
    static func parseDependencyIDs(_ raw: Any?) -> [Int] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { element in
            if let n = (element as? NSNumber)?.intValue { return n }
            if let dict = element as? [String: Any], let n = (dict["id"] as? NSNumber)?.intValue { return n }
            return nil
        }
    }

    /// A SceneScript bound to one of an image object's transform/visibility properties drives the scene graph
    /// rather than returning a value (the audio visualisers bind to `visible`/`scale`/`origin` and clone the
    /// layer into bars). Find the first such `{ "value": …, "script": … }` binding and return its source. WE
    /// stores the script either inline (the whole module as the string) or as a `scripts/…js` package path;
    /// handle both. Returns nil when the object has no scripted property.
    private static func boundScript(of object: [String: Any], in package: ScenePackage) -> String? {
        for key in ["visible", "scale", "origin", "alpha", "color", "size", "angles"] {
            guard let binding = object[key] as? [String: Any],
                  let script = binding["script"] as? String, !script.isEmpty else { continue }
            // Inline module (contains JS, not a bare path): use it directly. Otherwise resolve the path.
            if script.contains("function") || script.contains("\n") || script.contains("=>") {
                return script
            }
            if let entry = package.entry(named: script), let source = String(data: entry.data, encoding: .utf8) {
                return source
            }
        }
        return nil
    }

    /// True when `object` is a now-playing media-player widget layer (album art, vinyl disc, progress bar,
    /// song-title/artist text, play/pause icons, panel background). Such layers subscribe to WE's media events
    /// — mediaPlaybackChanged / mediaThumbnailChanged / mediaPropertiesChanged (and their *Event types) — and
    /// only render meaningful content while music plays; with nothing playing they show a placeholder (a blank
    /// album-art box, the vinyl graphic, "Title"). Lumora has no media playback, so these are hidden, matching
    /// Wallpaper Engine. EXCLUDES audio visualisers ("Audio Bars"): they react to the audio spectrum
    /// (registerAudioBuffers / AUDIO_RESOLUTION) and merely tint by the album art — without music they already
    /// collapse to zero height, so they must keep rendering normally.
    static func isMediaPlayerWidget(_ object: [String: Any]) -> Bool {
        let scripts = boundScriptText(in: object)
        let mediaEvents = ["mediaPlaybackChanged", "mediaThumbnailChanged", "mediaPropertiesChanged",
                           "MediaPlaybackEvent", "MediaThumbnailEvent", "MediaPropertiesEvent"]
        guard mediaEvents.contains(where: { scripts.contains($0) }) else { return false }
        if scripts.contains("registerAudioBuffers") || scripts.contains("AUDIO_RESOLUTION") { return false }
        return true
    }

    /// Concatenate only the SCRIPT source bound anywhere in an object's JSON — the value of every `"script"`
    /// key (a property binding's `{value, script}`, a text field's script, etc.) — so a substring scan can spot
    /// which WE callbacks a layer wires up. Deliberately NOT the object's names or image/material paths: a layer
    /// merely *named* or *pathed* with a media-ish token (e.g. `materials/mediaThumbnail_bg.tex`) must not be
    /// mistaken for a now-playing widget. Bounded: one object holds a handful of KB of script at most.
    private static func boundScriptText(in object: [String: Any]) -> String {
        var out = ""
        func walk(_ any: Any, _ depth: Int) {
            guard depth < 32 else { return }   // untrusted JSON: bound recursion so a deeply-nested tree can't overflow the stack
            if let d = any as? [String: Any] {
                if let s = d["script"] as? String { out += s; out += "\n" }
                for (k, v) in d where k != "script" { walk(v, depth + 1) }
            } else if let a = any as? [Any] {
                for v in a { walk(v, depth + 1) }
            }
        }
        walk(object, 0)
        return out
    }

    /// A `visible` field is a Bool, or a `{ "user": …, "value": Bool }` property binding — read either. When the
    /// binding names a simple user property (a prompt/author box, an optional effect, a clock component) and the
    /// viewer has overridden it in the Customize panel, the override wins; otherwise the binding's default
    /// `value` stands. This is how Wallpaper Engine lets a user permanently turn off, say, the author's
    /// "prompt box" (`{ "user": "promptbox", … }`) — without the override it shows by default.
    private static func isVisible(_ value: Any?, overrides: [String: PropertyValue] = [:]) -> Bool {
        if let flag = value as? Bool { return flag }
        if let dict = value as? [String: Any] {
            // A media-player widget (album-art tile, now-playing overlay, controls) drives its own visibility
            // with a script that keeps it hidden — `targetAlpha = 0` — until music plays (mediaPlaybackChanged /
            // mediaThumbnailChanged fire). Lumora has no media playback, so the steady state is hidden, exactly
            // like Wallpaper Engine with nothing playing. Honour that instead of drawing the static placeholder
            // (a blank white album-art box, dark fade overlays) the `value` field still reports as visible.
            if let script = dict["script"] as? String,
               script.contains("mediaPlayback") || script.contains("MediaPlaybackEvent") || script.contains("mediaThumbnail") {
                return false
            }
            // The author's "prompt box" (a self-promo / "how to close this" overlay, bound to a `promptbox`
            // user property) is never shown in Lumora — it's intrusive and adds nothing to a wallpaper. Force it
            // hidden regardless of the scene's default or any saved override. Match the property name whether
            // it's the plain string form (`"user": "promptbox"`) or the combo form (`"user": { "name": … }`),
            // and accept any name CONTAINING "promptbox" (authors suffix it, e.g. `promptbox2`).
            if Self.userPropertyName(dict["user"])?.lowercased().contains("promptbox") == true { return false }
            // A plain `{ "user": "<name>", "value": Bool }` toggle: a user override of <name> overrides the
            // default. (The combo-conditional form, `"user": { "name", "condition" }`, is left on its default
            // `value` — it depends on a multi-choice selection, not a simple boolean.)
            if let userKey = dict["user"] as? String, case let .bool(override)? = overrides[userKey] { return override }
            if let flag = dict["value"] as? Bool { return flag }
        }
        return true
    }

    /// The property name a `visible`/`text` binding's `user` field refers to, from either the plain string form
    /// (`"user": "name"`) or the combo form (`"user": { "name": "...", "condition": "..." }`).
    private static func userPropertyName(_ user: Any?) -> String? {
        if let name = user as? String { return name }
        if let dict = user as? [String: Any] { return dict["name"] as? String }
        return nil
    }

    /// True when a text layer's authored value is Wallpaper-Engine template *junk* the user never customised —
    /// an un-replaced "customizable text" placeholder, the literal "Text Layer" default, or an author self-promo
    /// watermark (a social handle / "this prompt box can be turned off" notice). These add nothing to a wallpaper
    /// and read as broken/unprofessional, so Lumora hides the layer rather than stamping the placeholder on the
    /// desktop. Matched case-insensitively against a tight signature list so real titles (a stylised "Frieren",
    /// "Chainsaw Man", "君の名は。") are never caught.
    public static func isTemplateJunkText(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        // Un-customised placeholder markers (the author left the template's "type your text here" default).
        let placeholders = ["可自定义文字", "customizable text", "在此输入", "请输入", "输入文字", "输入文本", "your text here", "edit text", "sample text"]
        if placeholders.contains(where: { lower.contains($0.lowercased()) }) { return true }
        if lower == "text layer" || lower == "text" || lower == "new text" { return true }
        // Author self-promo / instructional watermarks (social handles, "turn this off" notices, maker credits).
        let promo = ["bilibili", "哔哩哔哩", "抖音", "微博", "公众号", "qq群", "老有话说", "wallpaper maker",
                     "permanently turned off", "user settings bar", "可永久关闭", "用户设置栏",
                     "夜莺night", "动态制作", "动效制作", "weibo"]
        if promo.contains(where: { lower.contains($0.lowercased()) }) { return true }
        // Template configuration captions baked as on-screen text — a clock/effect template's own setting
        // labels ("dynamic effect: simple", "time gradient mode") that the author never removed. They read as
        // a settings menu over the art; no real wallpaper title contains them.
        let configLabels = ["动效：", "时间模式", "变化模式", "渐变模式"]
        if configLabels.contains(where: { trimmed.contains($0) }) { return true }
        return false
    }

    /// Resolve a `{ "user": <name>, "value": <default> }` user-property binding to the value that should drive
    /// the render: the viewer's saved override of <name> when there is one, else the author's `value` default.
    /// The override (a Customize-panel `PropertyValue`) is handed back in the bare JSON shape the value readers
    /// already understand — a colour/text `String`, a slider/count `Double` (as `NSNumber`), or a `Bool` — so a
    /// user-tuned colour scheme or slider reaches the uniform instead of the author's baked-in default.
    private static func bound(_ object: [String: Any], overrides: [String: PropertyValue]) -> Any? {
        if let userKey = object["user"] as? String, let override = overrides[userKey] {
            switch override {
            case .string(let s): return s
            case .number(let d): return d as NSNumber
            case .bool(let b):   return b
            case .null:          break
            }
        }
        return object["value"]
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

    /// Resolve a layer's post-process effects. Each `object.effects[i].file` → effect.json, which is a
    /// graph of passes (a multi-pass effect like blur is downsample → gaussian-x → gaussian-y → combine,
    /// wired through named `fbos`). Each pass → its material → shader, combos and aux textures; the pass's
    /// `target` and `bind` come from the effect.json. The user's `constantshadervalues` and combo overrides
    /// (e.g. the blend mode) are shared across the passes.
    /// Whether an effect entry's `visible` field leaves it enabled by default. `true`/missing → on; a bare
    /// `false` or a `{ "user": …, "value": false }` property binding → off (WE applies it only when the user
    /// enables the property, which Lumora has no way to do, so the default state governs).
    static func isEffectEnabled(_ visible: Any?, overrides: [String: PropertyValue] = [:]) -> Bool {
        if let flag = visible as? Bool { return flag }
        if let dict = visible as? [String: Any] {
            // Symmetric with layer visibility: a viewer who turns a default-off effect ON (or an on effect OFF)
            // in the Customize panel overrides the author's default `value`.
            if let userKey = dict["user"] as? String, case let .bool(override)? = overrides[userKey] { return override }
            if let flag = dict["value"] as? Bool { return flag }
        }
        return true
    }

    static func effects(of object: [String: Any], in package: ScenePackage,
                        overrides: [String: PropertyValue] = [:]) -> [LayerEffect] {
        guard let entries = object["effects"] as? [[String: Any]] else { return [] }
        var result: [LayerEffect] = []
        for entry in entries {
            // An effect can be toggled off by a user property: its `visible` is then a `{ "user": …, "value": false }`
            // binding (or a bare `false`) whose `value` is the default state. Wallpaper Engine applies the effect
            // only when that property is enabled, so a default-off effect (an optional colour tint, a background
            // blur, a "fire colour" overlay) is NOT drawn on a fresh load. Lumora has no UI to flip it, so the
            // default governs — skip a default-off effect rather than rendering one WE leaves off. A bare `true`,
            // a `{ value: true }`, or a missing `visible` is always-on.
            guard isEffectEnabled(entry["visible"], overrides: overrides) else { continue }
            guard let file = entry["file"] as? String,
                  let effect = json(package.entry(named: file)),
                  let effectPasses = effect["passes"] as? [[String: Any]], !effectPasses.isEmpty else { continue }

            // Constant overrides (e.g. a local-contrast effect's `strength`) live on the instance pass that
            // uses them — often a LATER combine pass, not the first — and a pass's packer only applies the
            // constants its own shader declares, so gather them across every instance pass.
            var constants: [String: String] = [:]
            for instancePass in (entry["passes"] as? [[String: Any]]) ?? [] {
                if let values = instancePass["constantshadervalues"] as? [String: Any] {
                    for (key, value) in values where constantString(value, overrides: overrides) != nil {
                        constants[key] = constantString(value, overrides: overrides)
                    }
                }
            }
            // The instance can override each material pass's texture slots — most importantly the opacity
            // mask that confines an effect to a region. The instance's `passes` mirror the effect's material
            // passes 1:1 by index, and the mask often sits on a LATER pass (a blur or local-contrast effect
            // binds it on its combine pass, not the first), so the override must be read per-pass; reading
            // only the first pass's slots drops the mask and the effect smears the whole layer.
            let instancePasses = (entry["passes"] as? [[String: Any]]) ?? []

            var passes: [EffectPass] = []
            // Cap the pass count: effect.json is untrusted, and a real effect graph is small (a 4-pass blur is
            // the heaviest), so an unbounded list could only be an attempt to exhaust memory at prepare time.
            for (passIndex, jsonPass) in effectPasses.prefix(16).enumerated() {
                guard let materialPath = jsonPass["material"] as? String,
                      let material = json(package.entry(named: materialPath)),
                      let materialPass = (material["passes"] as? [[String: Any]])?.first,
                      let shader = materialPass["shader"] as? String else { continue }
                // This pass's instance combo overrides (the wallpaper's blend mode, a per-pass VERTICAL on a
                // separable blur), read from its matching instance pass; the material's own combos override.
                var combos: [String: Int] = [:]
                if let source = (passIndex < instancePasses.count ? (instancePasses[passIndex]["combos"] as? [String: Any]) : nil) {
                    for (key, value) in source { if let i = (value as? NSNumber)?.intValue { combos[key] = i } }
                }
                if let materialCombos = materialPass["combos"] as? [String: Any] {
                    for (key, value) in materialCombos { if let i = (value as? NSNumber)?.intValue { combos[key] = i } }
                }
                var textures = (materialPass["textures"] as? [Any])?.map { $0 as? String } ?? []
                // Layer THIS pass's instance texture overrides on top of the material defaults (a slot the
                // instance leaves null keeps the material's), extending the list for slots the material omits.
                let entryTextures = (passIndex < instancePasses.count
                    ? (instancePasses[passIndex]["textures"] as? [Any]) : nil)?.map { $0 as? String } ?? []
                for (i, override) in entryTextures.enumerated() {
                    guard let override else { if i >= textures.count { textures.append(nil) }; continue }
                    if i < textures.count { textures[i] = override } else { textures.append(override) }
                }
                let binds: [EffectBind] = ((jsonPass["bind"] as? [[String: Any]]) ?? []).compactMap {
                    // Reject an out-of-range slot from untrusted JSON — it would later index a Metal fragment
                    // texture argument table (0…30) and trap. (The texture-override indices above are clamped too.)
                    guard let name = $0["name"] as? String, let index = ($0["index"] as? NSNumber)?.intValue,
                          (0...30).contains(index) else { return nil }
                    return EffectBind(name: name, index: index)
                }
                passes.append(EffectPass(fragmentShaderPath: "shaders/\(shader).frag",
                                         vertexShaderPath: "shaders/\(shader).vert",
                                         combos: combos, textures: textures,
                                         target: jsonPass["target"] as? String, binds: binds))
            }
            guard let first = passes.first else { continue }

            // Same untrusted-input bound on the FBO list, and clamp each scale to the 1…16 the renderer
            // actually allocates (1/2/4/8/16) so a bogus huge scale can't size a buffer absurdly.
            let fbos: [EffectFBO] = ((effect["fbos"] as? [[String: Any]]) ?? []).prefix(16).compactMap {
                guard let name = $0["name"] as? String else { return nil }
                let scale = ($0["scale"] as? NSNumber)?.intValue ?? 1
                return EffectFBO(name: name, scale: min(16, max(1, scale)), format: ($0["format"] as? String) ?? "rgba_backbuffer")
            }

            let name = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
            result.append(LayerEffect(
                name: name.isEmpty ? file : name,
                fragmentShaderPath: first.fragmentShaderPath,
                vertexShaderPath: first.vertexShaderPath,
                constants: constants, combos: first.combos, textures: first.textures,
                passes: passes, fbos: fbos))
        }
        return result
    }

    private static func constantString(_ value: Any?, overrides: [String: PropertyValue] = [:]) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        // A `constantshadervalues` entry is often a user-property binding `{ "user": …, "value": <string|number> }`
        // (a tint colour, a strength slider, …) rather than a bare literal. Unwrap to its bound value — the
        // viewer's Customize override of that property if set, else the author's `value` default; otherwise the
        // constant is dropped and the effect falls back to its shader default — e.g. a tint background washing
        // RED instead of the bound lavender (scene 3195212886).
        case let object as [String: Any]: return constantString(bound(object, overrides: overrides))
        default: return nil
        }
    }

    /// `alpha` is either a number or an animated `{ "value": Double, … }` object — take its base value
    /// (non-finite → 1).
    private static func alphaValue(_ value: Any?, overrides: [String: PropertyValue] = [:]) -> Double {
        let raw: Double?
        if let number = value as? NSNumber { raw = number.doubleValue }
        else if let object = value as? [String: Any], let base = bound(object, overrides: overrides) as? NSNumber { raw = base.doubleValue }
        else { raw = nil }
        guard let raw, raw.isFinite else { return 1 }
        return raw
    }

    /// A scalar property that may be a plain number or a `{ "user": …, "value": Double }` user-property binding
    /// (Wallpaper Engine lets the author wire a slider to a font size, an opacity, a count, …). Take the bound
    /// base value either way; without the dict case a bound `pointsize` collapses to the fallback — e.g. a clock
    /// authored at 119 pt renders at the 32 pt default, far too small for the layout it was placed in.
    private static func scalar(_ value: Any?, default fallback: Double, overrides: [String: PropertyValue] = [:]) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let object = value as? [String: Any], let base = bound(object, overrides: overrides) as? NSNumber { return base.doubleValue }
        return fallback
    }

    /// The keyframe animation under an `alpha` object's `animation.c0`, if present.
    private static func alphaAnimation(_ value: Any?) -> AlphaAnimation? {
        guard let object = value as? [String: Any],
              let animation = object["animation"] as? [String: Any],
              let curve = animation["c0"] as? [[String: Any]] else { return nil }
        let options = animation["options"] as? [String: Any] ?? [:]
        let fps = (options["fps"] as? NSNumber)?.doubleValue ?? 30
        let length = (options["length"] as? NSNumber)?.doubleValue ?? 0
        let isLooping = (options["mode"] as? String) == "loop"   // single (or absent) plays once and holds
        let keyframes = curve.compactMap { keyframe -> AlphaKeyframe? in
            guard let frame = (keyframe["frame"] as? NSNumber)?.doubleValue,
                  let value = (keyframe["value"] as? NSNumber)?.doubleValue,
                  frame.isFinite, value.isFinite else { return nil }
            return AlphaKeyframe(frame: frame, value: value)
        }.sorted { $0.frame < $1.frame }
        guard !keyframes.isEmpty, length > 0, length.isFinite, fps.isFinite else { return nil }
        return AlphaAnimation(keyframes: keyframes, fps: fps, length: length, isLooping: isLooping)
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
        let isLooping = (options["mode"] as? String) == "loop"   // single (or absent) plays once and holds
        func curve(_ key: String) -> AlphaAnimation? {
            guard let frames = animation[key] as? [[String: Any]], length > 0, length.isFinite, fps.isFinite else { return nil }
            let keyframes = frames.compactMap { keyframe -> AlphaKeyframe? in
                guard let frame = (keyframe["frame"] as? NSNumber)?.doubleValue,
                      let value = (keyframe["value"] as? NSNumber)?.doubleValue,
                      frame.isFinite, value.isFinite else { return nil }
                return AlphaKeyframe(frame: frame, value: value)
            }.sorted { $0.frame < $1.frame }
            guard !keyframes.isEmpty else { return nil }
            return AlphaAnimation(keyframes: keyframes, fps: fps, length: length, isLooping: isLooping)
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

    /// Parse a particle system AND its child sub-emitters into a flat list, each positioned at the parent
    /// emitter's world origin. WE particle `children` are secondary systems spawned alongside the parent (an
    /// ember's `emberglow`, a shooting-star's trail, a `magic_charge`'s rays); rendering them adds the
    /// secondary effect the scene shows in Wallpaper Engine. Each child resolves its own `particles/…json`
    /// and is offset by its (usually zero) origin. Depth-bounded so a cyclic or pathologically nested `.pkg`
    /// can't recurse without limit; a child that can't be parsed is simply skipped.
    private static func collectParticleSystems(from particleJSON: [String: Any], at worldOrigin: SceneVec3,
                                               in package: ScenePackage, depth: Int,
                                               sceneBox: SceneVec3? = nil) -> [ParticleSystem] {
        var out: [ParticleSystem] = []
        if var system = ParticleSystem.parse(particleJSON, sceneBox: sceneBox) {
            system.origin = SceneVec3(x: system.origin.x + worldOrigin.x,
                                      y: system.origin.y + worldOrigin.y,
                                      z: system.origin.z + worldOrigin.z)
            out.append(system)
        }
        guard depth < 4 else { return out }
        // Cap the children breadth (like passes/fbos/attractors) AND the total collected systems: a crafted
        // self-referential particle file with a huge `children` array would otherwise amplify breadth^depth
        // (each child is re-resolved + re-parsed) into a hang/OOM. Real effects nest a handful of children.
        for child in ((particleJSON["children"] as? [[String: Any]]) ?? []).prefix(8) {
            guard out.count < 64 else { break }
            guard let name = child["name"] as? String, let childJSON = json(package.entry(named: name)) else { continue }
            let off = vec(child["origin"])   // a child's emitter origin is relative to the parent (usually 0)
            let childWorld = SceneVec3(x: worldOrigin.x + off.x, y: worldOrigin.y + off.y, z: worldOrigin.z + off.z)
            out.append(contentsOf: collectParticleSystems(from: childJSON, at: childWorld, in: package, depth: depth + 1, sceneBox: sceneBox))
        }
        return out
    }
    /// A vector property that may be a plain `"x y z"` string or a `{ "value": "x y z", "script"/"animation": … }`
    /// binding — take the base value either way (the script/animation drives it on top at render time). Without
    /// the dict case, a scripted scale/colour/angle would silently fall back to the default.
    private static func vec(_ value: Any?, default fallback: SceneVec3 = SceneVec3(x: 0, y: 0, z: 0),
                            overrides: [String: PropertyValue] = [:]) -> SceneVec3 {
        if let string = value as? String { return SceneVec3(parsing: string) }
        if let object = value as? [String: Any], let string = bound(object, overrides: overrides) as? String {
            return SceneVec3(parsing: string)
        }
        return fallback
    }
    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
