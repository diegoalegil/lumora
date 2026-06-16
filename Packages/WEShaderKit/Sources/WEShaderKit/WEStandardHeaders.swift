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
    ]

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
