// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. A small MSL prelude prepended to every transpiled WE shader, supplying the
// names WE's GLSL dialect assumes from its (unshipped) common headers: the POSIX math.h constants Metal
// spells differently, standard geometric helpers, and the image-blending functions. Every definition is
// written from its universal mathematical meaning — a rotation matrix is a rotation matrix; the blend
// modes are the standard Porter-Duff / Photoshop compositing formulas (publicly specified, e.g. the W3C
// compositing spec). No GPL reference renderer's source was consulted.
import Foundation

public enum WEShaderPrelude {
    /// File-scope MSL definitions inserted after the combo `#define`s, before the shader's structs.
    public static let msl = """
    // math.h constants WE uses (Metal only predefines the *_F spellings).
    constant float M_PI = 3.14159265358979323846;
    constant float M_PI_2 = 1.57079632679489661923;
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

    // 1 where `uv` is inside the [0,1] square, falling to 0 just outside — the coverage of a sampled
    // sub-layer so its edges don't smear when blended.
    inline float GetUVBlend(float2 uv) {
        float2 inside = step(float2(0.0), uv) * step(uv, float2(1.0));
        return inside.x * inside.y;
    }

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

    // WE's imageblending mode values mapped to the per-channel blend above. Unknown modes fall back to
    // Normal so an unrecognised value never produces a hard failure.
    inline float3 weBlendValue(int mode, float3 a, float3 b) {
        switch (mode) {
            case 1:  return BlendAdditive(a, b);
            case 2:  return BlendMultiply(a, b);
            case 3:  return BlendScreen(a, b);
            case 4:  return BlendLighten(a, b);
            case 5:  return BlendDarken(a, b);
            case 6:  return BlendLinearDodge(a, b);
            case 7:  return BlendLinearBurn(a, b);
            case 8:  return BlendColorDodge(a, b);
            case 9:  return BlendScreen(a, b);   // pulse's default — a brightening (screen) blend
            case 10: return BlendOverlay(a, b);
            case 11: return BlendSoftLight(a, b);
            case 12: return BlendHardLight(a, b);
            case 13: return BlendDifference(a, b);
            case 14: return BlendExclusion(a, b);
            case 15: return BlendNegation(a, b);
            default: return BlendNormal(a, b);
        }
    }

    // Blend `blend` over `base` in mode `mode`, then fade by `opacity`.
    inline float3 ApplyBlending(int mode, float3 base, float3 blend, float opacity) {
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

    """
}
