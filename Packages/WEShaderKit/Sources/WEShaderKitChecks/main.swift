// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room verification of the WE shader uniform/annotation extractor against a shader
// in the real WE dialect (CLT-only equivalent of unit tests).
import Foundation
import WEShaderKit

// Dev mode: parse a real shader file and list its uniforms.
if CommandLine.arguments.count > 1,
   let real = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
    let parsed = ShaderUniforms.parse(real)
    print("\(parsed.count) uniforms:")
    for uniform in parsed {
        print("  \(uniform.type) \(uniform.name)  material=\(uniform.material ?? "-")  default=\(uniform.defaultValue ?? "-")  range=\(uniform.range.map(String.init(describing:)) ?? "-")")
    }
    exit(0)
}

// A fragment shader in WE's dialect (shape taken from real packaged effect shaders).
let source = """
varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white"}
uniform float g_Threshold; // {"material":"ui_editor_properties_ray_threshold","default":0.5,"range":[0, 1]}
uniform vec3 g_Color; // {"material":"ui_editor_properties_color","default":"1 0.5 0.25"}
uniform mat4 g_ModelViewProjectionMatrix;

void main() {
    float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * mask * g_Threshold;
}
"""

let uniforms = ShaderUniforms.parse(source)

Check.section("ShaderUniforms")
Check.that("finds all five uniforms", uniforms.count == 5)
Check.that("first is sampler2D g_Texture0", uniforms[0].type == "sampler2D" && uniforms[0].name == "g_Texture0")
Check.that("captures the material label", uniforms[0].material == "ui_editor_properties_framebuffer")
Check.that("captures a string (asset path) default", uniforms[1].defaultValue == "util/white")
Check.that("captures a numeric default", uniforms[2].defaultValue == "0.5")
Check.that("captures a [min,max] range", uniforms[2].range == [0, 1])
Check.that("captures a vector default", uniforms[3].defaultValue == "1 0.5 0.25")
Check.that("includes an un-annotated built-in", uniforms[4].name == "g_ModelViewProjectionMatrix" && uniforms[4].material == nil)
Check.that("ignores varyings and other lines", !uniforms.contains { $0.name.hasPrefix("v_") })
Check.that("a shader with no uniforms parses to empty", ShaderUniforms.parse("void main() {}").isEmpty)

Check.summarize()
