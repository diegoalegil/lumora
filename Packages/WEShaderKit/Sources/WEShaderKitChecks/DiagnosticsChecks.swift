// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room verification of the transpiler's silent-degradation diagnostics — the array
// clamp, the dropped out-of-range array varying, and the unresolved #include surfaced via the
// `…Diagnosed` overloads. Exercises the observability path the plain String overloads keep hidden.
import Foundation
import WEShaderKit

func runDiagnosticsChecks() {
    Check.section("WEShaderTranspiler diagnostics")

    // A shader the transpiler models fully must report ZERO diagnostics, and the diagnosed overload's MSL
    // must be byte-for-byte identical to the plain overload's — the side-channel is purely additive.
    let cleanFrag = """
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0; // {"material":"fb"}
    uniform float g_Brightness; // {"material":"b","default":1.0}
    void main() {
        vec4 color = texSample2D(g_Texture0, v_TexCoord.xy);
        gl_FragColor = color * g_Brightness;
    }
    """
    let plainFrag = WEShaderTranspiler.fragmentToMSL(cleanFrag)
    let diagFrag = WEShaderTranspiler.fragmentToMSLDiagnosed(cleanFrag)
    Check.that("a fully-modelled fragment yields zero diagnostics", diagFrag.diagnostics.isEmpty)
    Check.that("the diagnosed fragment MSL is byte-identical to the plain overload", diagFrag.msl == plainFrag)

    let cleanVert = """
    attribute vec3 a_Position;
    attribute vec4 a_TexCoord;
    uniform mat4 g_ModelViewProjectionMatrix;
    varying vec4 v_TexCoord;
    void main() {
        gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
        v_TexCoord = a_TexCoord;
    }
    """
    let plainVert = WEShaderTranspiler.vertexToMSL(cleanVert)
    let diagVert = WEShaderTranspiler.vertexToMSLDiagnosed(cleanVert)
    Check.that("a fully-modelled vertex yields zero diagnostics", diagVert.diagnostics.isEmpty)
    Check.that("the diagnosed vertex MSL is byte-identical to the plain overload", diagVert.msl == plainVert)

    // An array uniform longer than the cap is silently clamped (so the emitted struct and the packer agree
    // on the layout) — the diagnosed overload must surface the clamp, naming the uniform and both counts,
    // and the MSL must still match the plain path exactly (the clamp itself is unchanged).
    let cap = WEShaderTranspiler.maxArrayElements
    let overLong = cap + 1024
    let clampFrag = """
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_Spectrum[\(overLong)]; // {"material":"s"}
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * g_Spectrum[0]; }
    """
    let plainClamp = WEShaderTranspiler.fragmentToMSL(clampFrag)
    let diagClamp = WEShaderTranspiler.fragmentToMSLDiagnosed(clampFrag)
    Check.that("an over-long array uniform yields exactly one diagnostic", diagClamp.diagnostics.count == 1)
    Check.that("the clamp diagnostic names the uniform and both counts",
               diagClamp.diagnostics.first == "array uniform 'g_Spectrum' clamped from \(overLong) to \(cap)")
    Check.that("the clamped MSL is still byte-identical to the plain overload", diagClamp.msl == plainClamp)
    Check.that("the emitted struct still clamps to the cap", diagClamp.msl.contains("float g_Spectrum[\(cap)]"))

    // An array uniform AT the cap (or below) is not a clamp — no diagnostic, count unchanged.
    let atCapFrag = """
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_Spectrum[\(cap)]; // {"material":"s"}
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * g_Spectrum[0]; }
    """
    Check.that("an array uniform exactly at the cap yields no clamp diagnostic",
               WEShaderTranspiler.fragmentToMSLDiagnosed(atCapFrag).diagnostics.isEmpty)
    let smallArrayFrag = """
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_AudioSpectrum16Left[16];
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * g_AudioSpectrum16Left[3]; }
    """
    Check.that("a real-size audio array uniform yields no diagnostic",
               WEShaderTranspiler.fragmentToMSLDiagnosed(smallArrayFrag).diagnostics.isEmpty)

    // An out-of-range array VARYING is dropped to a non-array (the body can no longer index it), degrading
    // the effect — surface the drop. The huge-array fragment also still degrades to a bounded scaffold.
    let dropVaryingFrag = """
    varying vec2 v_TexCoord[999999999];
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord[0]); }
    """
    let plainDrop = WEShaderTranspiler.fragmentToMSL(dropVaryingFrag)
    let diagDrop = WEShaderTranspiler.fragmentToMSLDiagnosed(dropVaryingFrag)
    Check.that("an out-of-range array varying yields a drop diagnostic", diagDrop.diagnostics.count == 1)
    Check.that("the drop diagnostic names the varying and the rejected length",
               diagDrop.diagnostics.first == "varying 'v_TexCoord' has out-of-range array length 999999999; dropped to non-array (allowed 1...64)")
    Check.that("the dropped-varying MSL is still byte-identical to the plain overload", diagDrop.msl == plainDrop)
    Check.that("the dropped-varying MSL is still bounded (not expanded to millions of members)", diagDrop.msl.count < 100_000)

    // A legitimately-sized array varying (the blur/godray family declares [4]) is NOT a drop — no diagnostic.
    let okVaryingFrag = """
    varying vec2 v_TexCoord[4];
    uniform sampler2D g_Texture0;
    void main() {
        vec4 sum = vec4(0.0);
        for (int i = 0; i < 4; i++) sum += texSample2D(g_Texture0, v_TexCoord[i]);
        gl_FragColor = sum;
    }
    """
    Check.that("an in-range array varying yields no drop diagnostic",
               WEShaderTranspiler.fragmentToMSLDiagnosed(okVaryingFrag).diagnostics.isEmpty)

    // A vertex out-of-range array attribute/varying is surfaced through the vertex diagnosed overload too.
    let dropVertVarying = """
    attribute vec3 a_Position;
    varying vec2 v_Trail[5000];
    void main() { gl_Position = vec4(a_Position, 1.0); }
    """
    let diagVertDrop = WEShaderTranspiler.vertexToMSLDiagnosed(dropVertVarying)
    Check.that("the vertex path surfaces an out-of-range array varying drop",
               diagVertDrop.diagnostics.contains("varying 'v_Trail' has out-of-range array length 5000; dropped to non-array (allowed 1...64)"))

    // An #include with no matching header is left in place (later dropped as a `#` line), taking its helpers
    // with it. The diagnosed overload surfaces it; the MSL is unchanged versus the plain path.
    let missingIncludeFrag = """
    #include "common.h"
    #include "not_a_real_header.h"
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy); }
    """
    let plainInclude = WEShaderTranspiler.fragmentToMSL(missingIncludeFrag)
    let diagInclude = WEShaderTranspiler.fragmentToMSLDiagnosed(missingIncludeFrag)
    Check.that("an unresolved #include yields exactly one diagnostic (the known header is silent)",
               diagInclude.diagnostics.count == 1)
    Check.that("the unresolved-include diagnostic names the header",
               diagInclude.diagnostics.first == "unresolved #include \"not_a_real_header.h\"; its helpers are unavailable")
    Check.that("the unresolved-include MSL is still byte-identical to the plain overload", diagInclude.msl == plainInclude)

    // A shader that uses only resolvable bundled headers reports nothing.
    let resolvableIncludeFrag = """
    #include "common.h"
    #include "common_blending.h"
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    void main() {
        vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
        vec3 tinted = hsv2rgb(rgb2hsv(albedo.rgb));
        gl_FragColor = vec4(BlendOpacity(albedo.rgb, tinted, BlendLinearDodge, 0.5), albedo.a);
    }
    """
    Check.that("a shader using only resolvable headers reports no diagnostics",
               WEShaderTranspiler.fragmentToMSLDiagnosed(resolvableIncludeFrag).diagnostics.isEmpty)

    // Several degradations in one shader are all reported, de-duplicated, and the MSL still matches the plain
    // path byte-for-byte — the diagnostics are an observation, never a behaviour change.
    let multiFrag = """
    #include "ghost_header.h"
    varying vec2 v_Trail[100000];
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_Spectrum[\(overLong)]; // {"material":"s"}
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * g_Spectrum[0]; }
    """
    let plainMulti = WEShaderTranspiler.fragmentToMSL(multiFrag)
    let diagMulti = WEShaderTranspiler.fragmentToMSLDiagnosed(multiFrag)
    Check.that("a shader with three distinct degradations reports all three", diagMulti.diagnostics.count == 3)
    Check.that("the multi-degradation set covers the include, the varying and the uniform",
               Set(diagMulti.diagnostics) == [
                "unresolved #include \"ghost_header.h\"; its helpers are unavailable",
                "varying 'v_Trail' has out-of-range array length 100000; dropped to non-array (allowed 1...64)",
                "array uniform 'g_Spectrum' clamped from \(overLong) to \(cap)",
               ])
    Check.that("the multi-degradation MSL is still byte-identical to the plain overload", diagMulti.msl == plainMulti)

    // The clamp diagnostic for the SAME over-long uniform is reported once, even though the struct emit and
    // the dim/packing passes each touch the same declaration — a repeat would be noise.
    let dedupFrag = """
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform float g_A[\(overLong)]; // {"material":"a"}
    uniform float g_B[\(overLong)]; // {"material":"b"}
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * (g_A[0] + g_B[0]); }
    """
    let diagDedup = WEShaderTranspiler.fragmentToMSLDiagnosed(dedupFrag).diagnostics
    Check.that("two distinct over-long uniforms each report once (no per-pass duplication)", diagDedup.count == 2)

    // The plain String overloads remain available and unchanged — a caller that doesn't want diagnostics
    // pays nothing and sees the exact same output it always did.
    Check.that("the plain fragment overload still returns a no-op-free body for a clamp shader",
               WEShaderTranspiler.fragmentToMSL(clampFrag).contains("g_Texture0.sample("))
}
