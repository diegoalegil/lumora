// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. A small MSL prelude prepended to every transpiled WE shader, supplying the
// names WE's GLSL dialect assumes from its (unshipped) common headers: the POSIX math.h constants Metal
// spells differently, standard geometric helpers, and the image-blending functions. Every definition is
// written from its universal mathematical meaning — a rotation matrix is a rotation matrix; the blend
// modes are the standard Porter-Duff / Photoshop compositing formulas (publicly specified, e.g. the W3C
// compositing spec). No GPL reference renderer's source was consulted.
import Foundation

public enum WEShaderPrelude {
    /// The prelude with the named functions removed. WE shaders sometimes ship their own copy of a helper
    /// — most importantly a `BlendTransparency` that switches over a transparency-mode combo rather than
    /// the plain lerp here — and the shader's version is the authoritative one. Dropping the prelude's
    /// definition lets the in-file copy provide the behaviour instead of being shadowed by (or colliding
    /// with) the generic one.
    public static func msl(omitting names: Set<String>) -> String {
        guard !names.isEmpty else { return msl }
        var result = msl
        for name in names { result = removingFunction(named: name, from: result) }
        return result
    }

    /// Drop EVERY `inline <type> <name>(…) { … }` definition of `name` (brace-matched). A prelude name like
    /// `mod` (7 overloads) or `atan` (4) is overloaded; removing only the first would leave the rest to
    /// collide with the shader's own copy. Loops until no definition of the name remains.
    private static func removingFunction(named name: String, from text: String) -> String {
        var result = text
        let pattern = "inline\\s+[\\w<>]+\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*\\("
        while let sig = result.range(of: pattern, options: .regularExpression),
              let brace = result.range(of: "{", range: sig.upperBound ..< result.endIndex) {
            var depth = 0, i = brace.lowerBound, removed = false
            while i < result.endIndex {
                if result[i] == "{" { depth += 1 } else if result[i] == "}" {
                    depth -= 1
                    if depth == 0 {
                        result = String(result[..<sig.lowerBound]) + String(result[result.index(after: i)...])
                        removed = true
                        break
                    }
                }
                i = result.index(after: i)
            }
            if !removed { break }   // malformed (no closing brace) — stop rather than loop
        }
        return result
    }

    /// File-scope MSL definitions inserted after the combo `#define`s, before the shader's structs.
    public static let msl = """
    // Math constants WE's dialect assumes (Metal only predefines the *_F spellings). NB: WE's M_PI_2 is
    // "two pi" (tau), NOT math.h's π/2 — its shaders use it as a full turn, e.g. sin(frac(t / M_PI_2) *
    // M_PI_2) is one sine period and (atan2(y, x) + M_PI) / M_PI_2 normalises an angle to [0,1]; godray
    // fans spread by M_PI_2 * {0.2,0.4,…}. The genuine half-pi is M_PI_HALF.
    constant float M_PI = 3.14159265358979323846;
    constant float M_PI_2 = 6.28318530717958647692;     // tau, the value WE's shaders expect (not π/2)
    constant float M_PI_HALF = 1.57079632679489661923;
    constant float M_PI_4 = 0.78539816339744830962;
    constant float M_1_PI = 0.31830988618379067154;
    constant float M_2_PI = 0.63661977236758134308;
    constant float M_SQRT2 = 1.41421356237309504880;
    constant float M_SQRT1_2 = 0.70710678118654752440;

    // Rotate a 2D vector by `angle` radians about the origin (callers re-centre as needed).
    inline float2 rotateVec2(float2 v, float angle) {
        float s = sin(angle);
        float c = cos(angle);
        return float2(c * v.x - s * v.y, s * v.x + c * v.y);
    }

    // Rec.601 luma — WE's greyscale of an RGB colour.
    inline float greyscale(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

    // RGB <-> HSV, the standard branchless hexcone formulas (hue/sat/value in [0,1]). WE's colour
    // helpers expose these to gradient/hue shaders; a shader that ships its own copy shadows these.
    inline float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
        float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }
    inline float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
    }

    // 1 where `uv` is inside the [0,1] square, falling to 0 just outside — the coverage of a sampled
    // sub-layer so its edges don't smear when blended.
    inline float GetUVBlend(float2 uv) {
        float2 inside = step(float2(0.0), uv) * step(uv, float2(1.0));
        return inside.x * inside.y;
    }

    // GLSL mod is floor-based (its result takes the sign of y); Metal's fmod isn't, so define it.
    inline float  mod(float x, float y)   { return x - y * floor(x / y); }
    inline float2 mod(float2 x, float2 y) { return x - y * floor(x / y); }
    inline float3 mod(float3 x, float3 y) { return x - y * floor(x / y); }
    inline float4 mod(float4 x, float4 y) { return x - y * floor(x / y); }
    inline float2 mod(float2 x, float y)  { return x - y * floor(x / y); }
    inline float3 mod(float3 x, float y)  { return x - y * floor(x / y); }
    inline float4 mod(float4 x, float y)  { return x - y * floor(x / y); }

    // GLSL's two-argument atan(y, x) is atan2.
    inline float  atan(float y, float x)   { return atan2(y, x); }
    inline float2 atan(float2 y, float2 x) { return atan2(y, x); }
    inline float3 atan(float3 y, float3 x) { return atan2(y, x); }
    inline float4 atan(float4 y, float4 x) { return atan2(y, x); }

    // --- Image blending -----------------------------------------------------------------------------
    // Functions that take a blend mode implicitly use the BLENDMODE combo; guarantee it is defined.
    #ifndef BLENDMODE
    #define BLENDMODE 0
    #endif

    // Per-channel blend formulas (standard compositing math). `a` = base/destination, `b` = source.
    inline float3 BlendNormal(float3 a, float3 b)      { return b; }
    inline float3 BlendAdditive(float3 a, float3 b)    { return a + b; }
    inline float3 BlendLinearDodge(float3 a, float3 b) { return a + b; }
    inline float3 BlendMultiply(float3 a, float3 b)    { return a * b; }
    inline float3 BlendScreen(float3 a, float3 b)      { return 1.0 - (1.0 - a) * (1.0 - b); }
    inline float3 BlendLighten(float3 a, float3 b)     { return max(a, b); }
    inline float3 BlendDarken(float3 a, float3 b)      { return min(a, b); }
    inline float3 BlendSubtract(float3 a, float3 b)    { return a - b; }
    inline float3 BlendDifference(float3 a, float3 b)  { return abs(a - b); }
    inline float3 BlendNegation(float3 a, float3 b)    { return 1.0 - abs(1.0 - a - b); }
    inline float3 BlendExclusion(float3 a, float3 b)   { return a + b - 2.0 * a * b; }
    inline float3 BlendOverlay(float3 a, float3 b) {
        return select(2.0 * a * b, 1.0 - 2.0 * (1.0 - a) * (1.0 - b), a >= 0.5);
    }
    inline float3 BlendHardLight(float3 a, float3 b) {
        return select(2.0 * a * b, 1.0 - 2.0 * (1.0 - a) * (1.0 - b), b >= 0.5);
    }
    inline float3 BlendSoftLight(float3 a, float3 b) {
        return select(2.0 * a * b + a * a * (1.0 - 2.0 * b),
                      sqrt(a) * (2.0 * b - 1.0) + 2.0 * a * (1.0 - b), b >= 0.5);
    }
    inline float3 BlendColorDodge(float3 a, float3 b) { return select(min(float3(1.0), a / (1.0 - b)), float3(1.0), b >= 1.0); }
    inline float3 BlendColorBurn(float3 a, float3 b)  { return select(1.0 - min(float3(1.0), (1.0 - a) / b), float3(0.0), b <= 0.0); }
    inline float3 BlendLinearBurn(float3 a, float3 b) { return a + b - 1.0; }

    // The remaining per-channel formulas WE's common_blending.h defines, reimplemented clean-room from the
    // public Photoshop / W3C compositing math. `a` = base/destination, `b` = source.
    inline float3 BlendReflect(float3 a, float3 b)    { return select(min(a * a / (1.0 - b), 1.0), float3(1.0), b >= 1.0); }
    inline float3 BlendGlow(float3 a, float3 b)       { return BlendReflect(b, a); }   // Reflect, args swapped
    inline float3 BlendPhoenix(float3 a, float3 b)    { return min(a, b) - max(a, b) + 1.0; }
    inline float3 BlendAverage(float3 a, float3 b)    { return (a + b) * 0.5; }
    inline float3 BlendTint(float3 a, float3 b)       { return max(max(a.x, a.y), a.z) * b; }
    inline float3 BlendVividLight(float3 a, float3 b) {
        // ColorBurn for a dark blend, ColorDodge for a light one (blend doubled about 0.5).
        return select(BlendColorBurn(a, 2.0 * b), BlendColorDodge(a, 2.0 * (b - 0.5)), b >= 0.5);
    }
    inline float3 BlendLinearLight(float3 a, float3 b) {
        // LinearBurn for a dark blend, LinearDodge for a light one.
        return select(max(a + 2.0 * b - 1.0, 0.0), a + 2.0 * (b - 0.5), b >= 0.5);
    }
    inline float3 BlendPinLight(float3 a, float3 b) {
        // Darken for a dark blend, Lighten for a light one.
        return select(min(a, 2.0 * b), max(a, 2.0 * b - 1.0), b >= 0.5);
    }
    inline float3 BlendHardMix(float3 a, float3 b) {
        // 1 where VividLight reaches 0.5, else 0 (per channel).
        return select(float3(0.0), float3(1.0), BlendVividLight(a, b) >= 0.5);
    }

    // WE's colorBlendMode / BLENDMODE values mapped to the per-channel formula above, following the canonical
    // common_blending.h `ApplyBlending` enum exactly (kept in lock-step with SceneRenderer's we_apply_blend).
    // Returns the pre-opacity blend; ApplyBlending applies the opacity mix and the few modes WE leaves unmixed.
    // 26–29 (Hue/Saturation/Color/Luminosity) need HSL helpers the prelude doesn't model and, like
    // we_apply_blend, fall through to Normal. Unknown modes fall back to Normal so a bad value never hard-fails.
    inline float3 weBlendValue(int mode, float3 a, float3 b) {
        switch (mode) {
            case 1:  return min(a, b);                   // Darken
            case 2:  return BlendMultiply(a, b);         // Multiply
            case 3:  return BlendColorBurn(a, b);        // ColorBurn
            case 4:  return max(a + b - 1.0, 0.0);       // Subtract
            case 5:  return min(a, b);                   // min (ApplyBlending evaluates this without the mix)
            case 6:  return max(a, b);                   // Lighten
            case 7:  return BlendScreen(a, b);           // Screen
            case 8:  return BlendColorDodge(a, b);       // ColorDodge
            case 9:  return min(a + b, 1.0);             // Add (clamped)
            case 10: return max(a, b);                   // max (ApplyBlending evaluates this without the mix)
            case 11: return BlendOverlay(a, b);          // Overlay
            case 12: return BlendSoftLight(a, b);        // SoftLight
            case 13: return BlendHardLight(a, b);        // HardLight
            case 14: return BlendVividLight(a, b);       // VividLight
            case 15: return BlendLinearLight(a, b);      // LinearLight
            case 16: return BlendPinLight(a, b);         // PinLight
            case 17: return BlendHardMix(a, b);          // HardMix
            case 18: return BlendDifference(a, b);       // Difference
            case 19: return BlendExclusion(a, b);        // Exclusion
            case 20: return max(a + b - 1.0, 0.0);       // Subtract (alternate index)
            case 21: return BlendReflect(a, b);          // Reflect
            case 22: return BlendGlow(a, b);             // Glow
            case 23: return BlendPhoenix(a, b);          // Phoenix
            case 24: return BlendAverage(a, b);          // Average
            case 25: return BlendNegation(a, b);         // Negation
            case 30: return BlendTint(a, b);             // Tint
            case 31: return a + b;                       // Additive — mix(a, a+b, op) == a + b*op
            case 32: return a + a * b;                   // glow-multiply
            default: return BlendNormal(a, b);           // Normal / unmapped → plain source-over
        }
    }

    // Blend `blend` over `base` in mode `mode`, then fade by `opacity`. Three modes WE evaluates without the
    // standard opacity mix (see common_blending.h): min, max, and the additive weighted sum.
    inline float3 ApplyBlending(int mode, float3 base, float3 blend, float opacity) {
        if (mode == 5)  return min(base, blend);
        if (mode == 10) return max(base, blend);
        if (mode == 31) return base + blend * opacity;
        return mix(base, weBlendValue(mode, base, blend), saturate(opacity));
    }
    // RGBA variant using the active BLENDMODE; preserves the base alpha.
    inline float4 PerformBlend(float4 base, float4 blend, float opacity) {
        return float4(ApplyBlending(BLENDMODE, base.rgb, blend.rgb, opacity), base.a);
    }
    // Source-over composite of a premultiplied-ish layer `over` onto `base`.
    inline float4 ApplyComposite(float4 base, float4 over) {
        return float4(mix(base.rgb, over.rgb, over.a), base.a + over.a * (1.0 - base.a));
    }
    // Alpha-only "normal over" used to fold a layer's coverage into the destination alpha.
    inline float BlendTransparency(float base, float blend, float opacity) {
        return base + (blend - base) * opacity;
    }

    // --- Matrix helpers GLSL has and Metal doesn't ---------------------------------------------------
    // GLSL's mat3(mat4) keeps the upper-left 3×3; Metal has no such truncating constructor, so take the
    // first three components of the first three columns (WE's CAST3X3 macro lowers to this).
    inline float3x3 _weCast3x3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }

    // GLSL provides inverse(); Metal doesn't. 3×3 inverse via the adjugate over the determinant.
    inline float3x3 inverse(float3x3 m) {
        float c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1];
        float c01 = m[0][2] * m[2][1] - m[0][1] * m[2][2];
        float c02 = m[0][1] * m[1][2] - m[0][2] * m[1][1];
        float c10 = m[1][2] * m[2][0] - m[1][0] * m[2][2];
        float c11 = m[0][0] * m[2][2] - m[0][2] * m[2][0];
        float c12 = m[0][2] * m[1][0] - m[0][0] * m[1][2];
        float c20 = m[1][0] * m[2][1] - m[1][1] * m[2][0];
        float c21 = m[0][1] * m[2][0] - m[0][0] * m[2][1];
        float c22 = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        float invDet = 1.0 / (m[0][0] * c00 + m[0][1] * c10 + m[0][2] * c20);
        return float3x3(c00 * invDet, c01 * invDet, c02 * invDet,
                        c10 * invDet, c11 * invDet, c12 * invDet,
                        c20 * invDet, c21 * invDet, c22 * invDet);
    }

    """
}
