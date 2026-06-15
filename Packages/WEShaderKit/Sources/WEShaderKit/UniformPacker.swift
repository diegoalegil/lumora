// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. Packs effect constant values into a Metal uniform buffer laid out exactly like
// the `Uniforms` struct WEShaderTranspiler emits — declaration order with MSL member alignment (float→4,
// float2→8, float3/float4/float4x4→16). No GPL.
import Foundation

public enum UniformPacker {
    /// Pack `uniforms` (the non-sampler uniforms, in declaration order) into a buffer matching the
    /// transpiler's MSL `Uniforms` struct. Each value comes from `values` (keyed by the uniform's
    /// `material` annotation), else the uniform's default, else zero.
    public static func pack(_ uniforms: [ShaderUniform], values: [String: String]) -> Data {
        var buffer = Data()
        var maxAlignment = 4
        for uniform in uniforms {
            let info = layout(uniform.type)
            maxAlignment = max(maxAlignment, info.alignment)
            buffer.pad(to: align(buffer.count, to: info.alignment))
            let source = uniform.material.flatMap { values[$0] } ?? uniform.defaultValue ?? "0"
            for component in floats(source, count: info.components) { buffer.appendFloat(component) }
            buffer.pad(to: buffer.count + (info.stride - info.components * 4))
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
        case "mat4":  return (16, 64, 16)
        default:      return (4, 4, 1)
        }
    }

    private static func floats(_ string: String, count: Int) -> [Float] {
        var values = string.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Float($0) ?? 0 }
        if values.count < count { values += Array(repeating: 0, count: count - values.count) }
        return Array(values.prefix(count))
    }

    private static func align(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}

private extension Data {
    mutating func pad(to size: Int) { if size > count { append(Data(count: size - count)) } }
    mutating func appendFloat(_ value: Float) {
        var copy = value
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
