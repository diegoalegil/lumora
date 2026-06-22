// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Wallpaper Engine's effect shaders `#include` a handful of standard headers
// (common.h, common_blending.h, common_blur.h, …) that ship with the engine, not inside a wallpaper, so
// they are absent from the packages we read. These are reconstructions of the *names and signatures* the
// user's own shaders call, each implemented from its universal/standard meaning — a rounded-box signed
// distance is the textbook SDF, an opacity blend is mix(base, blend(base, src), opacity) — and from the
// public WE shader docs. No GPL reference renderer's headers were read or translated.
import Foundation

/// The engine-provided shader headers, keyed by the name used in `#include "name"`. `ShaderPreprocessor`
/// splices the matching source in before resolving conditionals, so the helpers a shader calls are
/// declared. Helpers that need the fragment's textures/uniforms are deliberately left out for now — a
/// shader that still references an unknown name fails to transpile and is dropped by the renderer's
/// graceful degradation rather than rendering wrong pixels.
public enum WEStandardHeaders {
    public static let all: [String: String] = [
        "common.h": common,
        "common_blending.h": commonBlending,
        "common_blur.h": commonBlur,
        "common_perspective.h": commonPerspective,
        "common_composite.h": commonComposite,
    ]

    /// The combine pass of a multi-pass blur/glow reads the blurred buffer and the original layer and folds
    /// them together. `ApplyCompositeOffset` is the sub-texel sampling correction when upscaling a
    /// downsampled buffer — the bilinear sampler already covers the [0,1] buffer, so the identity uv is used
    /// (any residual offset is below a texel). `ApplyComposite` is the standard four-way composite the
    /// effect's COMPOSITE combo selects: normal replaces with the blurred, blend/under are source-over in
    /// either order, cutout keeps the blurred only inside the original's coverage.
    private static let commonComposite = """
    float2 ApplyCompositeOffset(float2 uv, float2 resolution) { return uv; }
    float4 ApplyComposite(float4 base, float4 blend) {
    #if COMPOSITE == 1
        return float4(mix(base.rgb, blend.rgb, blend.a), base.a + blend.a * (1.0 - base.a));
    #elif COMPOSITE == 2
        return float4(mix(blend.rgb, base.rgb, base.a), blend.a + base.a * (1.0 - blend.a));
    #elif COMPOSITE == 3
        return float4(blend.rgb, blend.a * base.a);
    #else
        return blend;
    #endif
    }
    """

    /// Perspective warp. `squareToQuad` builds the homography mapping the unit square onto the quad
    /// p0..p3 (the standard Heckbert construction); WE shaders use `inverse(squareToQuad(…))` with the
    /// dialect's row-vector `mul(v, M)`, so the matrix is stored to match that convention. A near-affine
    /// quad (a plain rectangle, e.g. the default transform) has a zero perspective denominator — fall back
    /// to the affine map there instead of dividing by zero.
    private static let commonPerspective = """
    float3x3 squareToQuad(float2 p0, float2 p1, float2 p2, float2 p3) {
        float dx1 = p1.x - p2.x, dx2 = p3.x - p2.x;
        float dy1 = p1.y - p2.y, dy2 = p3.y - p2.y;
        float sx = p0.x - p1.x + p2.x - p3.x;
        float sy = p0.y - p1.y + p2.y - p3.y;
        float den = dx1 * dy2 - dx2 * dy1;
        float g = 0.0, h = 0.0;
        if (abs(den) > 1e-7) {
            g = (sx * dy2 - dx2 * sy) / den;
            h = (dx1 * sy - sx * dy1) / den;
        }
        float a = p1.x - p0.x + g * p1.x;
        float b = p3.x - p0.x + h * p3.x;
        float c = p0.x;
        float d = p1.y - p0.y + g * p1.y;
        float e = p3.y - p0.y + h * p3.y;
        float f = p0.y;
        return float3x3(a, b, c, d, e, f, g, h, 1.0);
    }
    """

    /// Separable gaussian blur. WE's `blur{13,7,3}a(uv, step)` sample the framebuffer `g_Texture0` along a
    /// precomputed step direction (the paired vertex shader puts the centre uv in `.xy` and the per-tap
    /// offset in `.zw`, zeroed on the off-axis so the pass is one-dimensional). The framebuffer is implicit
    /// at the call site, so each name is a macro that injects it into a free function taking the texture as
    /// a parameter. The tap weights are WE's own 13/7/3-tap gaussian kernels (read from a packaged blur
    /// shader that lists them inline), so the result matches WE, not just a textbook approximation.
    private static let commonBlur = """
    #define blur13a(uv, step) _weBlur13(g_Texture0, g_Texture0_smp, (uv), (step))
    #define blur7a(uv, step) _weBlur7(g_Texture0, g_Texture0_smp, (uv), (step))
    #define blur3a(uv, step) _weBlur3(g_Texture0, g_Texture0_smp, (uv), (step))
    // Radial (zoom) blur: the same gaussian kernels, but the per-tap step runs along the ray FROM `center`
    // through `uv`, so the framebuffer smears outward from the centre and the blur grows with distance —
    // WE's blurRadial{13,7,3}a(uv, center, scale). The 0.03 factor maps `scale` (≈0.01…2) to a sensible
    // zoom length (the 6th tap reaches ~0.18·dist·scale).
    #define blurRadial13a(uv, center, scale) _weBlur13(g_Texture0, g_Texture0_smp, (uv), ((uv) - (center)) * (scale) * 0.03)
    #define blurRadial7a(uv, center, scale) _weBlur7(g_Texture0, g_Texture0_smp, (uv), ((uv) - (center)) * (scale) * 0.03)
    #define blurRadial3a(uv, center, scale) _weBlur3(g_Texture0, g_Texture0_smp, (uv), ((uv) - (center)) * (scale) * 0.03)
    float4 _weBlur13(texture2d<float> t, sampler s, float2 uv, float2 d) {
        float4 c = t.sample(s, uv) * 0.171834;
        c += (t.sample(s, uv + d) + t.sample(s, uv - d)) * 0.156756;
        c += (t.sample(s, uv + d * 2.0) + t.sample(s, uv - d * 2.0)) * 0.119007;
        c += (t.sample(s, uv + d * 3.0) + t.sample(s, uv - d * 3.0)) * 0.075189;
        c += (t.sample(s, uv + d * 4.0) + t.sample(s, uv - d * 4.0)) * 0.039533;
        c += (t.sample(s, uv + d * 5.0) + t.sample(s, uv - d * 5.0)) * 0.017298;
        c += (t.sample(s, uv + d * 6.0) + t.sample(s, uv - d * 6.0)) * 0.006299;
        return c;
    }
    float4 _weBlur7(texture2d<float> t, sampler s, float2 uv, float2 d) {
        float4 c = t.sample(s, uv) * 0.214607;
        c += (t.sample(s, uv + d) + t.sample(s, uv - d)) * 0.189879;
        c += (t.sample(s, uv + d * 2.0) + t.sample(s, uv - d * 2.0)) * 0.131514;
        c += (t.sample(s, uv + d * 3.0) + t.sample(s, uv - d * 3.0)) * 0.071303;
        return c;
    }
    float4 _weBlur3(texture2d<float> t, sampler s, float2 uv, float2 d) {
        float4 c = t.sample(s, uv) * 0.5;
        c += (t.sample(s, uv + d) + t.sample(s, uv - d)) * 0.25;
        return c;
    }
    """

    /// Colour-space helpers WE shaders call from `common.h`. The HSV⇄RGB pair is the standard branchless
    /// conversion (hue as a piecewise-linear ramp); it carries no engine state, so it is safe to provide
    /// unconditionally.
    private static let common = """
    float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
        float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }
    float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
    }
    """

    /// Opacity-weighted blending. WE passes the per-channel blend as a function argument
    /// (`BlendOpacity(base, src, BlendLinearDodge, opacity)`), so this is a template over that function;
    /// the named blend functions themselves come from the prelude.
    private static let commonBlending = """
    template <typename BlendFn>
    float3 BlendOpacity(float3 base, float3 blend, BlendFn fn, float opacity) {
        return mix(base, fn(base, blend), saturate(opacity));
    }
    """
}
