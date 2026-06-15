// SPDX-License-Identifier: MIT
// Provenance: clean-room. Runs a WE post-process effect as a full-screen Metal pass: transpiles the
// effect's WE-dialect fragment shader to MSL (via WEShaderKit), pairs it with a fixed full-screen
// vertex (the effect work lives in the fragment), and draws a quad sampling the layer's framebuffer as
// g_Texture0. Apple frameworks only. No GPL.
import Foundation
import Metal
import WEImporter
import WEShaderKit

/// Runs WE post-process effects (pulse, tint, blur…) as full-screen Metal passes over a layer's texture.
public final class EffectRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let vertexFunction: MTLFunction
    private let sampler: MTLSamplerState

    // A fixed full-screen vertex that outputs v_TexCoord (in both halves of a vec4, as WE effect
    // fragments expect). Effect vertex shaders are just full-screen passthroughs, so one fixed vertex
    // serves them all and avoids per-shader vertex descriptors and MVP uniforms.
    private static let vertexSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float4 v_TexCoord [[user(locn0)]]; };
    vertex VertexOut we_effect_vertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uv[4]  = { float2(0, 1),  float2(1, 1),  float2(0, 0),  float2(1, 0) };
        VertexOut out;
        out.position = float4(pos[vid], 0, 1);
        out.v_TexCoord = float4(uv[vid], uv[vid]);
        return out;
    }
    """

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.vertexSource, options: nil),
              let vertexFunction = library.makeFunction(name: "we_effect_vertex") else { return nil }
        self.device = device
        self.queue = queue
        self.vertexFunction = vertexFunction

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
    }

    /// Build a pipeline pairing the fixed full-screen vertex with a WE effect's transpiled fragment, or
    /// nil if it fails to transpile, compile, or link. `combos` are the effect's combo selections.
    public func makePipeline(fragmentShader: String, combos: [String: Int] = [:]) -> MTLRenderPipelineState? {
        guard let fragmentLibrary = try? device.makeLibrary(source: WEShaderTranspiler.fragmentToMSL(fragmentShader, combos: combos), options: nil),
              let fragmentFunction = fragmentLibrary.makeFunction(name: "we_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Render `input` through the effect `pipeline` into a new texture: `input` binds as g_Texture0,
    /// `auxTextures` as g_Texture1…, and `fragmentUniforms` (if any) as the fragment uniform buffer.
    public func apply(pipeline: MTLRenderPipelineState, to input: MTLTexture, auxTextures: [MTLTexture] = [],
                      fragmentUniforms: Data? = nil, width: Int, height: Int) -> MTLTexture? {
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        outputDescriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: outputDescriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for (offset, texture) in auxTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: offset + 1)
            encoder.setFragmentSamplerState(sampler, index: offset + 1)
        }
        if let fragmentUniforms, !fragmentUniforms.isEmpty {
            fragmentUniforms.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setFragmentBytes(base, length: fragmentUniforms.count, index: 0) }
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.error != nil { return nil }   // a GPU fault leaves the target undefined — fail cleanly
        return output
    }

    /// Apply a parsed `LayerEffect` to `input`: read its fragment shader from `package`, transpile it,
    /// pack the effect's constants, bind `auxTexture` for the extra samplers, and render the pass.
    public func apply(_ effect: LayerEffect, to input: MTLTexture, package: ScenePackage,
                      auxTexture: MTLTexture, width: Int, height: Int) -> MTLTexture? {
        guard let fragmentEntry = package.entry(named: effect.fragmentShaderPath) else { return nil }
        let fragmentSource = String(decoding: fragmentEntry.data, as: UTF8.self)
        guard let pipeline = makePipeline(fragmentShader: fragmentSource, combos: effect.combos) else { return nil }

        let resolved = ShaderPreprocessor.resolve(fragmentSource,
            combos: ShaderPreprocessor.comboDefaults(fragmentSource).merging(effect.combos) { _, b in b })
        let scalars = ShaderUniforms.parse(resolved).filter { !$0.type.hasPrefix("sampler") }
        let fragmentBuffer = UniformPacker.pack(scalars, values: effect.constants)
        let samplerCount = ShaderUniforms.parse(resolved).filter { $0.type.hasPrefix("sampler") }.count
        let aux = Array(repeating: auxTexture, count: max(0, samplerCount - 1))

        return apply(pipeline: pipeline, to: input, auxTextures: aux,
                     fragmentUniforms: fragmentBuffer.isEmpty ? nil : fragmentBuffer, width: width, height: height)
    }

    /// Upload tightly-packed RGBA8 bytes into a shader-readable texture (for an effect's input).
    public func makeTexture(rgba: Data, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: base, bytesPerRow: width * 4)
            }
        }
        return texture
    }

    /// Read an RGBA8 texture's pixels back (for tests and previews).
    public func readback(_ texture: MTLTexture) -> Data {
        let width = texture.width, height = texture.height
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                texture.getBytes(base, bytesPerRow: width * 4,
                                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        return rgba
    }
}
