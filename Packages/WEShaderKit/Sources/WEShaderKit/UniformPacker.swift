// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Packs effect constant values into a Metal uniform buffer laid out exactly like
// the `Uniforms` struct WEShaderTranspiler emits — declaration order with MSL member alignment (float→4,
// float2→8, float3/float4/float4x4→16). No GPL.
import Foundation

public enum UniformPacker {
    /// Pack `uniforms` (the non-sampler uniforms, in declaration order) into a buffer matching the
    /// transpiler's MSL `Uniforms` struct. Each value comes from `values` (keyed by the uniform's
    /// `material` annotation), else the uniform's default, else zero.
    public static func pack(_ uniforms: [ShaderUniform], values: [String: String],
                            overrides: [String: [Float]] = [:]) -> Data {
        var buffer = Data()
        var maxAlignment = 4
        for uniform in uniforms {
            let info = layout(uniform.type)
            // `arrayCount` is the `[N]` from an untrusted shader. Cap it before the component arithmetic and
            // buffer growth below: a hostile `g_X[2000000000]` (or one near Int.max) would otherwise overflow
            // `components * count` or ask `fit` for a multi-gigabyte allocation. The cap MUST match the one the
            // transpiler applies to the emitted struct member (`maxArrayElements`), or this packed data and
            // that struct disagree on where every later uniform sits. Real WE array uniforms (audio spectra,
            // small tables) are orders of magnitude below it, so it's a no-op for them.
            let count = min(WEShaderTranspiler.maxArrayElements, max(1, uniform.arrayCount ?? 1))
            maxAlignment = max(maxAlignment, info.alignment)
            buffer.pad(to: align(buffer.count, to: info.alignment))
            let components: [Float]
            if let override = overrides[uniform.name] {   // a built-in supplied by the renderer
                components = fit(override, to: info.components * count)
            } else {
                let source = uniform.material.flatMap { values[$0] } ?? uniform.defaultValue ?? "0"
                components = floats(source, count: info.components * count)
            }
            // Emit `count` array elements (count == 1 for a plain uniform). MSL packs a scalar/vector array
            // member at the element's own stride — float[N] is tightly packed at 4 bytes, vecN[N] at 16, etc.
            let isInteger = Self.isIntegerType(uniform.type)
            for element in 0 ..< count {
                let base = element * info.components
                if uniform.type == "mat3" {
                    // float3x3 in MSL is three columns of float3, each padded to 16 bytes (48 total).
                    for column in 0 ..< 3 {
                        for row in 0 ..< 3 { buffer.appendFloat(components[base + column * 3 + row]) }
                        buffer.appendFloat(0)
                    }
                } else {
                    for c in 0 ..< info.components {
                        // An int/uint uniform's 4 bytes are an integer, not the IEEE-754 bits of a float — a
                        // shader's `int g_Mode = 1` must read 1, not 0x3F800000.
                        if isInteger { buffer.appendInt32(int32(components[base + c])) }
                        else { buffer.appendFloat(components[base + c]) }
                    }
                    buffer.pad(to: buffer.count + (info.stride - info.components * 4))
                }
            }
        }
        buffer.pad(to: align(buffer.count, to: maxAlignment))
        return buffer
    }

    /// MSL alignment, stored stride, and float-component count for a WE uniform type.
    private static func layout(_ type: String) -> (alignment: Int, stride: Int, components: Int) {
        switch type {
        case "float": return (4, 4, 1)
        case "vec2":  return (8, 8, 2)
        case "vec3":  return (16, 16, 3)   // a float3 occupies 16 bytes in a struct
        case "vec4":  return (16, 16, 4)
        case "mat2":  return (8, 16, 4)    // two float2 columns, contiguous
        case "mat3":  return (16, 48, 9)   // three float3 columns, each padded to 16 (handled in pack)
        case "mat4":  return (16, 64, 16)
        // Integer/unsigned uniforms align in an MSL struct exactly like their float counterparts (int→int,
        // int2→int2 …); only their bytes are integer-encoded (handled in pack). The transpiler emits int/uint
        // and int2/3/4, uint2/3/4 for these.
        case "int", "uint":              return (4, 4, 1)
        case "ivec2", "uvec2":           return (8, 8, 2)
        case "ivec3", "uvec3":           return (16, 16, 3)
        case "ivec4", "uvec4":           return (16, 16, 4)
        // bool/bvec uniforms don't occur in real WE shaders (booleans are compile-time combos), and MSL's
        // bool packing is byte-sized and subtle — leave them on the conservative scalar default rather than
        // risk a wrong layout for a case that never arises.
        default:      return (4, 4, 1)
        }
    }

    /// True for the integer/unsigned uniform types, whose values must be written as integer bits (not float).
    private static func isIntegerType(_ type: String) -> Bool {
        switch type {
        case "int", "uint", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4": return true
        default: return false
        }
    }

    private static func floats(_ string: String, count: Int) -> [Float] {
        fit(string.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Float($0) ?? 0 }, to: count)
    }

    private static func fit(_ values: [Float], to count: Int) -> [Float] {
        var values = values
        if values.count < count { values += Array(repeating: 0, count: count - values.count) }
        return Array(values.prefix(count))
    }

    private static func align(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }

    /// Convert a parsed (float) component to Int32, tolerating NaN/overflow (→ 0 / clamped) so a hostile value
    /// never traps. Integer uniform values arrive as their decimal string, parsed to Float upstream.
    private static func int32(_ value: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        if value >= Float(Int32.max) { return Int32.max }
        if value <= Float(Int32.min) { return Int32.min }
        return Int32(value.rounded(.towardZero))
    }
}

private extension Data {
    mutating func pad(to size: Int) { if size > count { append(Data(count: size - count)) } }
    mutating func appendFloat(_ value: Float) {
        var copy = value
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
    mutating func appendInt32(_ value: Int32) {
        var copy = value
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
