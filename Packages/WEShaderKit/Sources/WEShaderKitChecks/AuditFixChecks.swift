// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room regression checks for two audited bugs: integer-typed uniforms were packed as float
// bits / wrong layout, and chained division in a #if was right-associative.
import Foundation
import WEShaderKit

func runAuditFixChecks() {
    Check.section("UniformPacker integer uniforms")

    // A scalar int writes integer bits, not the IEEE-754 bits of a float (1 → 0x00000001, not 0x3F800000).
    let intData = UniformPacker.pack([ShaderUniform(type: "int", name: "g_Mode", material: "m")], values: ["m": "1"])
    Check.that("an int uniform is 4 bytes", intData.count == 4)
    Check.that("an int uniform writes integer bits", intData.withUnsafeBytes { $0.load(as: Int32.self) } == 1)

    // ivec2 packs as int2: 8 bytes, two contiguous Int32s (the old default layout gave it only 4).
    let ivec = UniformPacker.pack([ShaderUniform(type: "ivec2", name: "g_IV", material: "v")], values: ["v": "3 4"])
    Check.that("ivec2 is 8 bytes", ivec.count == 8)
    Check.that("ivec2 writes two integers",
               ivec.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) } == 3 &&
               ivec.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) } == 4)

    // No tail desync: an int followed by a float lands the float at offset 4 with the right value.
    let mixed = UniformPacker.pack([
        ShaderUniform(type: "int", name: "g_N", material: "n"),
        ShaderUniform(type: "float", name: "g_F", material: "f"),
    ], values: ["n": "2", "f": "0.5"])
    Check.that("int+float packs to 8 bytes", mixed.count == 8)
    Check.that("the int reads 2", mixed.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) } == 2)
    Check.that("the float after the int reads 0.5", mixed.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) } == 0.5)

    // ivec2 (align 8) followed by a float: the float sits at offset 8, and the struct rounds up to align 8 → 16.
    let v2f = UniformPacker.pack([
        ShaderUniform(type: "ivec2", name: "g_V", material: "v"),
        ShaderUniform(type: "float", name: "g_F", material: "f"),
    ], values: ["v": "5 6", "f": "1.5"])
    Check.that("ivec2+float rounds up to 16 bytes", v2f.count == 16)
    Check.that("the float after ivec2 sits at offset 8",
               v2f.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) } == 1.5)

    // A hostile non-finite/huge integer value clamps instead of trapping.
    let huge = UniformPacker.pack([ShaderUniform(type: "int", name: "g_H", material: "h")], values: ["h": "1e30"])
    Check.that("an out-of-range int clamps to Int32.max", huge.withUnsafeBytes { $0.load(as: Int32.self) } == Int32.max)

    // Floats are untouched by the integer path.
    let f = UniformPacker.pack([ShaderUniform(type: "float", name: "g_F", material: "f")], values: ["f": "0.25"])
    Check.that("a float uniform still writes float bits", f.withUnsafeBytes { $0.load(as: Float.self) } == 0.25)

    Check.section("ShaderPreprocessor chained division")

    // (4 / 2) / 2 == 1, so the #if branch is taken; right-associative 4 / (2 / 2) == 4 would take the #else.
    let div = "x\n#if Q / 2 / 2 == 1\nyes\n#else\nno\n#endif\nz"
    Check.that("chained division is left-associative", ShaderPreprocessor.resolve(div, combos: ["Q": 4]) == "x\nyes\nz")
    Check.that("a single division still evaluates",
               ShaderPreprocessor.resolve("#if 8 / 2 == 4\ny\n#else\nn\n#endif", combos: [:]) == "y")
    Check.that("division by zero is still safe (yields 0)",
               ShaderPreprocessor.resolve("#if 4 / 0 == 0\ny\n#else\nn\n#endif", combos: [:]) == "y")
}
