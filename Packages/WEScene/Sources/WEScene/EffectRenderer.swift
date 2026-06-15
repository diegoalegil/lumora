// SPDX-License-Identifier: MIT
// Provenance: clean-room. Runs a WE post-process effect as a full-screen Metal pass: transpiles the
// effect's WE-dialect shaders to MSL (via WEShaderKit), builds a pipeline, and draws a full-screen quad
// that samples the layer's framebuffer as g_Texture0. Apple frameworks only. No GPL.
import Foundation
import Metal
import WEShaderKit

/// A full-screen-quad vertex for an effect pass: clip-space position + a texcoord carried in both halves
/// of a vec4 (WE effect shaders read v_TexCoord.xy and .zw).
private struct EffectVertex {
    var position: SIMD3<Float>
    var texcoord: SIMD4<Float>
}

/// Runs WE post-process effects (pulse, tint, blur…) as full-screen Metal passes over a layer's texture.
public final class EffectRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let quadBuffer: MTLBuffer
    private let vertexDescriptor: MTLVertexDescriptor
    private let sampler: MTLSamplerState

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        let quad: [EffectVertex] = [
            EffectVertex(position: SIMD3(-1, -1, 0), texcoord: SIMD4(0, 1, 0, 1)),
            EffectVertex(position: SIMD3(1, -1, 0), texcoord: SIMD4(1, 1, 1, 1)),
            EffectVertex(position: SIMD3(-1, 1, 0), texcoord: SIMD4(0, 0, 0, 0)),
            EffectVertex(position: SIMD3(1, 1, 0), texcoord: SIMD4(1, 0, 1, 0)),
        ]
        guard let buffer = device.makeBuffer(bytes: quad, length: MemoryLayout<EffectVertex>.stride * quad.count) else { return nil }
        self.quadBuffer = buffer

        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float4
        descriptor.attributes[1].offset = MemoryLayout<EffectVertex>.offset(of: \.texcoord) ?? 16
        descriptor.attributes[1].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<EffectVertex>.stride
        self.vertexDescriptor = descriptor

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
    }

    /// Build a pipeline from a WE effect's vertex + fragment shaders, or nil if either fails to transpile,
    /// compile, or link.
    public func makePipeline(vertexShader: String, fragmentShader: String) -> MTLRenderPipelineState? {
        guard let vertexLibrary = try? device.makeLibrary(source: WEShaderTranspiler.vertexToMSL(vertexShader), options: nil),
              let fragmentLibrary = try? device.makeLibrary(source: WEShaderTranspiler.fragmentToMSL(fragmentShader), options: nil),
              let vertexFunction = vertexLibrary.makeFunction(name: "we_vertex"),
              let fragmentFunction = fragmentLibrary.makeFunction(name: "we_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
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
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
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
        return output
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
