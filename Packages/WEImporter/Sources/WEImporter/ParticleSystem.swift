// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Parses a Wallpaper Engine particle system (particles/**.json) into the subset
// the renderer simulates: one box/point emitter, the standard random initializers (lifetime, size,
// velocity, colour, alpha, rotation), a movement operator (gravity), and the sprite material. Reversed
// from the user's own particle files; no GPL source consulted.
import Foundation

/// A parsed WE particle system: an emitter spawning sprites with randomised initial state, advanced by
/// gravity, drawn with `materialPath`'s sprite texture. Simulated analytically by the renderer.
public struct ParticleSystem: Sendable, Equatable {
    public struct Range3: Sendable, Equatable {           // an inclusive [min, max] vector range
        public var min: SceneVec3
        public var max: SceneVec3
        public init(min: SceneVec3, max: SceneVec3) { self.min = min; self.max = max }
    }

    public var maxCount: Int            // live particle cap
    public var rate: Double             // particles spawned per second
    public var origin: SceneVec3        // emitter centre (scene units)
    public var boxSize: SceneVec3       // half-extents a particle may spawn within (boxrandom)
    public var isAdditive: Bool         // sprite blend mode
    public var materialPath: String?    // material → sprite texture

    public var lifetime: ClosedRange<Double>
    public var size: ClosedRange<Double>
    public var velocity: Range3
    public var speed: ClosedRange<Double>   // sphere emitter: random speed along `directions`
    public var directions: SceneVec3        // per-axis mask for the emission direction (e.g. "1 1 0")
    public var color: Range3            // 0–255 per channel
    public var alpha: ClosedRange<Double>
    public var gravity: SceneVec3       // scene units / s²
    public var initialRotation: ClosedRange<Double>   // radians; a random starting orientation (rotationrandom)
    public var angularVelocity: ClosedRange<Double>   // radians/s about z (angularvelocityrandom's z component)
    // Size-over-life (sizechange operator): the size multiplier ramps from `sizeStart` to `sizeEnd` between
    // `sizeStartTime` and `sizeEndTime` (life fractions 0…1), holding flat outside that span. Defaults to a
    // constant 1 (no change), so a system without the operator renders exactly as before.
    public var sizeStart: Double
    public var sizeEnd: Double
    public var sizeStartTime: Double
    public var sizeEndTime: Double

    /// Parse a particle system from its JSON object, or nil if it lacks an emitter we can drive.
    public static func parse(_ json: [String: Any], materialOverride: String? = nil) -> ParticleSystem? {
        guard let emitters = json["emitter"] as? [[String: Any]], let emitter = emitters.first else { return nil }

        // distancemax is a box's half-extents, or (for a sphere emitter) a scalar radius — spread it
        // across the screen plane so particles fill the scene instead of spawning along one axis.
        let kind = (emitter["name"] as? String) ?? "box"
        var boxSize = vec3(emitter["distancemax"])
        if kind.hasPrefix("sphere"), boxSize.y == 0, boxSize.z == 0 {
            boxSize = SceneVec3(x: boxSize.x, y: boxSize.x, z: 0)
        }

        var system = ParticleSystem(
            maxCount: min(4000, max(1, (json["maxcount"] as? NSNumber)?.intValue ?? 100)),
            rate: max(0, (emitter["rate"] as? NSNumber)?.doubleValue ?? 0),
            origin: vec3(emitter["origin"]),
            boxSize: boxSize,
            isAdditive: true,
            materialPath: materialOverride ?? (json["material"] as? String),
            lifetime: 1 ... 1, size: 10 ... 10,
            velocity: Range3(min: SceneVec3(x: 0, y: 0, z: 0), max: SceneVec3(x: 0, y: 0, z: 0)),
            speed: scalarRange(emitter, fallback: 0, keys: ("speedmin", "speedmax")),
            directions: vec3(emitter["directions"]),
            color: Range3(min: SceneVec3(x: 255, y: 255, z: 255), max: SceneVec3(x: 255, y: 255, z: 255)),
            alpha: 1 ... 1, gravity: SceneVec3(x: 0, y: 0, z: 0),
            initialRotation: 0 ... 0, angularVelocity: 0 ... 0,
            sizeStart: 1, sizeEnd: 1, sizeStartTime: 0, sizeEndTime: 1)

        for initializer in (json["initializer"] as? [[String: Any]]) ?? [] {
            let name = (initializer["name"] as? String) ?? ""
            switch name {
            case "lifetimerandom": system.lifetime = scalarRange(initializer, fallback: 1)
            case "sizerandom":     system.size = scalarRange(initializer, fallback: 10)
            case "alpharandom":    system.alpha = scalarRange(initializer, fallback: 1)
            case "velocityrandom": system.velocity = Range3(min: vec3(initializer["min"]), max: vec3(initializer["max"]))
            case "colorrandom":
                system.color = Range3(min: vec3(initializer["min"], default: 255),
                                      max: vec3(initializer["max"], default: 255))
            case "rotationrandom":
                // A random starting orientation. WE stores no bounds for the common 2-D case → a full circle.
                system.initialRotation = 0 ... (2 * .pi)
            case "angularvelocityrandom":
                // Per-axis spin; for a flat sprite only the z component (the screen-plane spin, rad/s) matters.
                let lo = vec3(initializer["min"]).z, hi = vec3(initializer["max"]).z
                system.angularVelocity = min(lo, hi) ... max(lo, hi)
            default: break
            }
        }
        for op in (json["operator"] as? [[String: Any]]) ?? [] {
            switch op["name"] as? String {
            case "movement":
                system.gravity = vec3(op["gravity"])
            case "sizechange":
                func num(_ key: String, _ fallback: Double) -> Double { (op[key] as? NSNumber)?.doubleValue ?? fallback }
                system.sizeStart = num("startvalue", 1)
                system.sizeEnd = num("endvalue", 1)
                system.sizeStartTime = num("starttime", 0)
                system.sizeEndTime = num("endtime", 1)
            default: break
            }
        }
        return system.rate > 0 ? system : nil
    }

    /// Parse a `"x y z"` string (or a missing value → `fallback` on each axis).
    private static func vec3(_ value: Any?, default fallback: Double = 0) -> SceneVec3 {
        if let string = value as? String, !string.isEmpty { return SceneVec3(parsing: string) }
        return SceneVec3(x: fallback, y: fallback, z: fallback)
    }

    private static func scalarRange(_ d: [String: Any], fallback: Double,
                                    keys: (String, String) = ("min", "max")) -> ClosedRange<Double> {
        let lo = (d[keys.0] as? NSNumber)?.doubleValue ?? fallback
        let hi = (d[keys.1] as? NSNumber)?.doubleValue ?? lo
        return min(lo, hi) ... max(lo, hi)
    }
}
