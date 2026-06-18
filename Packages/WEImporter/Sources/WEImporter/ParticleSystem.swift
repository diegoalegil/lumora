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

    /// The vortex operator: orbits particles tangentially about a centre (emitter origin + offset). The
    /// tangential speed blends from `speedInner` to `speedOuter` between the inner/outer radii; the renderer
    /// turns it into an angular sweep and rotates the particle about the centre (radius-preserving).
    public struct Vortex: Sendable, Equatable {
        public var offset: SceneVec3
        public var distanceInner: Double
        public var distanceOuter: Double
        public var speedInner: Double
        public var speedOuter: Double
        public init(offset: SceneVec3, distanceInner: Double, distanceOuter: Double, speedInner: Double, speedOuter: Double) {
            self.offset = offset; self.distanceInner = distanceInner; self.distanceOuter = distanceOuter
            self.speedInner = speedInner; self.speedOuter = speedOuter
        }
    }

    /// The turbulence operator: a noise flow-field that drifts particles. Approximated statelessly as a
    /// closed-form positional displacement sampled at (spawn position · `scale`, age · `timescale`), so it
    /// preserves the (seed, age) → state invariant. `mask` selects axes; `speed` scales the drift.
    public struct Turbulence: Sendable, Equatable {
        public var mask: SceneVec3
        public var speed: ClosedRange<Double>
        public var scale: Double
        public var phaseMax: Double
        public var timescale: Double
        public init(mask: SceneVec3, speed: ClosedRange<Double>, scale: Double, phaseMax: Double, timescale: Double) {
            self.mask = mask; self.speed = speed; self.scale = scale; self.phaseMax = phaseMax; self.timescale = timescale
        }
    }

    /// A sinusoidal modulator (oscillatealpha / oscillatesize / oscillateposition). Each particle picks a
    /// frequency in `freq` (Hz) and a phase in `phase` (cycles). For alpha/size the 0…1 sine envelope is
    /// mapped into the `scale` multiplier range; for position `scale` is the displacement amplitude and `mask`
    /// selects which axes move. nil ⇒ the operator is absent (no modulation), so unaffected systems are
    /// byte-identical.
    public struct Oscillator: Sendable, Equatable {
        public var freq: ClosedRange<Double>
        public var scale: ClosedRange<Double>
        public var phase: ClosedRange<Double>
        public var mask: SceneVec3
        public init(freq: ClosedRange<Double>, scale: ClosedRange<Double>, phase: ClosedRange<Double>, mask: SceneVec3) {
            self.freq = freq; self.scale = scale; self.phase = phase; self.mask = mask
        }
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
    public var drag: Double             // velocity damping 1/s (movement operator's `drag`); 0 = no damping
    public var initialRotation: ClosedRange<Double>   // radians; a random starting orientation (rotationrandom)
    public var angularVelocity: ClosedRange<Double>   // radians/s about z (angularvelocityrandom's z component)
    public var angularForce: Double                   // radians/s² about z (angularmovement's z force); 0 = none
    // Size-over-life (sizechange operator): the size multiplier ramps from `sizeStart` to `sizeEnd` between
    // `sizeStartTime` and `sizeEndTime` (life fractions 0…1), holding flat outside that span. Defaults to a
    // constant 1 (no change), so a system without the operator renders exactly as before.
    public var sizeStart: Double
    public var sizeEnd: Double
    public var sizeStartTime: Double
    public var sizeEndTime: Double
    // Alpha-over-life (alphafade operator): fade in over [0, fadeInTime] and out over [fadeOutTime, 1] (life
    // fractions). `hasAlphaFade` is false when the system ships no alphafade operator — the renderer then
    // keeps its generic gentle fade rather than guessing.
    public var hasAlphaFade: Bool
    public var fadeInTime: Double
    public var fadeOutTime: Double
    public var oscillateAlpha: Oscillator?      // oscillatealpha: sine on alpha
    public var oscillateSize: Oscillator?       // oscillatesize: sine on size
    public var oscillatePosition: Oscillator?   // oscillateposition: sine displacement along `mask`
    // turbulentvelocityrandom: a noise-seeded kick added to the spawn velocity. 0 scale ⇒ no kick.
    public var turbVelScale: Double
    public var turbVelOffset: Double
    public var turbVelSpeed: ClosedRange<Double>
    // colorchange: the tint multiplies from `colorChangeStart` to `colorChangeEnd` (0…1 colours) across the
    // [startTime, endTime] life-fraction span. `hasColorChange` false ⇒ tint unchanged.
    public var hasColorChange: Bool
    public var colorChangeStart: SceneVec3
    public var colorChangeEnd: SceneVec3
    public var colorChangeStartTime: Double
    public var colorChangeEndTime: Double
    public var turbulence: Turbulence?   // turbulence operator: a noise flow-field drift (nil = none)
    // controlpointattract: pull/push particles toward a control point (≈ emitter origin + offset). `cpScale`
    // is the force (negative = repel); `cpThreshold` its falloff radius. 0 scale = no operator.
    public var cpScale: Double
    public var cpThreshold: Double
    public var cpOffset: SceneVec3
    public var vortex: Vortex?   // vortex operator: orbit particles about a centre (nil = none)

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
            alpha: 1 ... 1, gravity: SceneVec3(x: 0, y: 0, z: 0), drag: 0,
            initialRotation: 0 ... 0, angularVelocity: 0 ... 0, angularForce: 0,
            sizeStart: 1, sizeEnd: 1, sizeStartTime: 0, sizeEndTime: 1,
            hasAlphaFade: false, fadeInTime: 0, fadeOutTime: 1,
            oscillateAlpha: nil, oscillateSize: nil, oscillatePosition: nil,
            turbVelScale: 0, turbVelOffset: 0, turbVelSpeed: 0 ... 0,
            hasColorChange: false, colorChangeStart: SceneVec3(x: 1, y: 1, z: 1),
            colorChangeEnd: SceneVec3(x: 1, y: 1, z: 1), colorChangeStartTime: 0, colorChangeEndTime: 1,
            turbulence: nil, cpScale: 0, cpThreshold: 0, cpOffset: SceneVec3(x: 0, y: 0, z: 0), vortex: nil)

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
            case "turbulentvelocityrandom":
                // A noise-seeded kick added to the spawn velocity. Scale clamped so it can't fling sprites.
                system.turbVelScale = clampFinite((initializer["scale"] as? NSNumber)?.doubleValue ?? 0, -100, 100, 0)
                system.turbVelOffset = clampFinite((initializer["offset"] as? NSNumber)?.doubleValue ?? 0, -10, 10, 0)
                system.turbVelSpeed = scalarRange(initializer, fallback: 0, keys: ("speedmin", "speedmax"))
            default: break
            }
        }
        for op in (json["operator"] as? [[String: Any]]) ?? [] {
            switch op["name"] as? String {
            case "movement":
                system.gravity = vec3(op["gravity"])
                system.drag = min(50, max(0, (op["drag"] as? NSNumber)?.doubleValue ?? 0))
            case "sizechange":
                func num(_ key: String, _ fallback: Double) -> Double { (op[key] as? NSNumber)?.doubleValue ?? fallback }
                system.sizeStart = num("startvalue", 1)
                system.sizeEnd = num("endvalue", 1)
                system.sizeStartTime = num("starttime", 0)
                system.sizeEndTime = num("endtime", 1)
            case "alphafade":
                system.hasAlphaFade = true
                system.fadeInTime = clampFinite((op["fadeintime"] as? NSNumber)?.doubleValue ?? 0, 0, 1, 0)
                system.fadeOutTime = clampFinite((op["fadeouttime"] as? NSNumber)?.doubleValue ?? 1, 0, 1, 1)
            case "angularmovement":
                // Angular acceleration about z (the screen-plane spin); clamped like the spin rate.
                system.angularForce = min(12, max(-12, vec3(op["force"]).z))
            case "oscillatealpha":    system.oscillateAlpha = oscillator(op, scaleDefault: (1, 1))
            case "oscillatesize":     system.oscillateSize = oscillator(op, scaleDefault: (1, 1))
            case "oscillateposition": system.oscillatePosition = oscillator(op, scaleDefault: (0, 0))
            case "vortex", "vortex_v2":
                func num(_ k: String, _ f: Double) -> Double { (op[k] as? NSNumber)?.doubleValue ?? f }
                system.vortex = Vortex(
                    offset: vec3(op["offset"]),
                    distanceInner: num("distanceinner", 0),
                    distanceOuter: max(num("distanceinner", 0) + 1, num("distanceouter", 1)),
                    speedInner: num("speedinner", 0),
                    speedOuter: num("speedouter", 0))
            case "controlpointattract":
                let cpId = (op["controlpoint"] as? NSNumber)?.intValue ?? 1
                let cps = json["controlpoint"] as? [[String: Any]] ?? []
                let cp = cps.first { ($0["id"] as? NSNumber)?.intValue == cpId }
                system.cpScale = min(20000, max(-20000, (op["scale"] as? NSNumber)?.doubleValue ?? 0))
                system.cpThreshold = max(1, (op["threshold"] as? NSNumber)?.doubleValue ?? 64)
                system.cpOffset = vec3(cp?["offset"])
            case "turbulence":
                func num(_ k: String, _ f: Double) -> Double { (op[k] as? NSNumber)?.doubleValue ?? f }
                let sp = scalarRange(op, fallback: 0, keys: ("speedmin", "speedmax"))
                system.turbulence = Turbulence(
                    mask: vec3(op["mask"], default: 1),
                    speed: sp,
                    scale: min(1, max(0, num("scale", 0.005))),
                    phaseMax: max(0, num("phasemax", 1)),
                    timescale: min(100, max(0, num("timescale", 1))))
            case "colorchange":
                // The tint animates from startvalue to endvalue (0…1 colours) across [starttime, endtime].
                system.hasColorChange = true
                system.colorChangeStart = vec3(op["startvalue"], default: 1)
                system.colorChangeEnd = vec3(op["endvalue"], default: 1)
                system.colorChangeStartTime = (op["starttime"] as? NSNumber)?.doubleValue ?? 0
                system.colorChangeEndTime = (op["endtime"] as? NSNumber)?.doubleValue ?? 1
            default: break
            }
        }
        return system.rate > 0 ? system : nil
    }

    /// Build an `Oscillator` from an oscillate* operator dict. Frequencies clamp to ≤30 Hz so a bad value
    /// can't strobe; phase defaults to a 0…1 spread (so particles desync naturally) unless the op pins it.
    private static func oscillator(_ op: [String: Any], scaleDefault: (Double, Double)) -> Oscillator {
        func num(_ k: String, _ f: Double) -> Double { (op[k] as? NSNumber)?.doubleValue ?? f }
        let fmin = num("frequencymin", 1), fmax = num("frequencymax", fmin)
        // Scale and phase come from untrusted .pkg JSON; a non-finite value (e.g. `1e400` → inf) would make
        // sin(phase) NaN downstream and fling a sprite to a non-finite position (a scatter). Sanitise both to
        // finite, generous bounds — a no-op for real values (small multipliers / a handful of cycles).
        let smin = clampFinite(num("scalemin", scaleDefault.0), -100_000, 100_000, scaleDefault.0)
        let smax = clampFinite(num("scalemax", scaleDefault.1), -100_000, 100_000, scaleDefault.1)
        let pmin = clampFinite(num("phasemin", 0), -1024, 1024, 0)
        let pmax = clampFinite(num("phasemax", 1), -1024, 1024, 1)
        func clampF(_ v: Double) -> Double { v.isFinite ? max(0, min(30, v)) : 1 }
        return Oscillator(freq: clampF(min(fmin, fmax)) ... clampF(max(fmin, fmax)),
                          scale: min(smin, smax) ... max(smin, smax),
                          phase: min(pmin, pmax) ... max(pmin, pmax),
                          mask: vec3(op["mask"], default: 1))
    }

    /// Clamp an untrusted scalar to `[lo, hi]`, mapping a non-finite value (inf/NaN from a malformed .pkg) to
    /// `fallback` so it can never propagate into the simulation.
    private static func clampFinite(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
        v.isFinite ? min(hi, max(lo, v)) : fallback
    }

    /// Parse a `"x y z"` string (or a missing value → `fallback` on each axis).
    private static func vec3(_ value: Any?, default fallback: Double = 0) -> SceneVec3 {
        if let string = value as? String, !string.isEmpty { return SceneVec3(parsing: string) }
        return SceneVec3(x: fallback, y: fallback, z: fallback)
    }

    private static func scalarRange(_ d: [String: Any], fallback: Double,
                                    keys: (String, String) = ("min", "max")) -> ClosedRange<Double> {
        // Sanitise untrusted .pkg numbers: a non-finite value (e.g. "1e400" → inf) becomes the fallback, and
        // the magnitude is clamped so a malformed lifetime/size/speed can't propagate inf/NaN into the sim.
        func clean(_ v: Double) -> Double { v.isFinite ? min(1_000_000, max(-1_000_000, v)) : fallback }
        let lo = clean((d[keys.0] as? NSNumber)?.doubleValue ?? fallback)
        let hi = clean((d[keys.1] as? NSNumber)?.doubleValue ?? lo)
        return min(lo, hi) ... max(lo, hi)
    }
}
