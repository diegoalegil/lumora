// SPDX-License-Identifier: MIT
// Provenance: clean-room. Runs a WE post-process effect as a Metal pass over a layer's framebuffer
// (bound as g_Texture0). The fragment is transpiled to MSL (via WEShaderKit); where the effect ships a
// vertex shader (rotation, shake, scroll, blur-tap offsets, mesh displacement…) it is transpiled too and
// run over a tessellated quad so the vertex stage's varyings/displacement are honoured, falling back to a
// fixed full-screen vertex for fragment-only effects. Apple frameworks only. No GPL.
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

    // The effect's own vertex reads a_Position/a_TexCoord from this shared mesh. A grid (not a single
    // quad) so vertex-displacement effects (waterwaves, ripple…) deform smoothly instead of moving four
    // corners. Built once; positions are in NDC and texcoords top-left, matching the fixed vertex below.
    private let gridVertexBuffer: MTLBuffer
    private let gridIndexBuffer: MTLBuffer
    private let gridIndexCount: Int
    private static let gridCells = 64
    private static let gridBufferIndex = 1   // the vertex uniform buffer is at buffer(0); keep the mesh clear of it

    // A fixed full-screen vertex that outputs v_TexCoord (in both halves of a vec4, as WE effect
    // fragments expect). Used for effects that have no vertex shader, or whose vertex can't be paired.
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

        // Tessellated quad: (cells+1)² vertices of [px, py, pz, u, v] (tight 20-byte stride), two
        // triangles per cell. NDC y is flipped so v=0 is the top, matching the fixed vertex's mapping.
        let cells = Self.gridCells, side = cells + 1
        var verts = [Float](); verts.reserveCapacity(side * side * 5)
        for gy in 0 ... cells {
            for gx in 0 ... cells {
                let u = Float(gx) / Float(cells), v = Float(gy) / Float(cells)
                verts.append(contentsOf: [u * 2 - 1, 1 - v * 2, 0, u, v])
            }
        }
        var indices = [UInt32](); indices.reserveCapacity(cells * cells * 6)
        for gy in 0 ..< cells {
            for gx in 0 ..< cells {
                let i00 = UInt32(gy * side + gx), i10 = i00 + 1
                let i01 = i00 + UInt32(side), i11 = i01 + 1
                indices.append(contentsOf: [i00, i10, i01, i10, i11, i01])
            }
        }
        guard let vbuf = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared),
              let ibuf = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared) else { return nil }
        self.gridVertexBuffer = vbuf
        self.gridIndexBuffer = ibuf
        self.gridIndexCount = indices.count

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
    public func makePipeline(fragmentShader: String, combos: [String: Int] = [:],
                             pixelFormat: MTLPixelFormat = .rgba8Unorm) -> MTLRenderPipelineState? {
        guard let fragmentLibrary = try? device.makeLibrary(source: WEShaderTranspiler.fragmentToMSL(fragmentShader, combos: combos), options: nil),
              let fragmentFunction = fragmentLibrary.makeFunction(name: "we_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Build a pipeline pairing the effect's OWN transpiled vertex with its fragment, so the vertex
    /// stage's varyings (blur-tap offsets, rotated/scaled coords, `v_Bounds`…) and any per-vertex
    /// displacement are produced — the fixed full-screen vertex can't, and pairing it with these fragments
    /// fails to link. Returns nil if either stage won't transpile/compile, the link fails, or the vertex
    /// uses an attribute the shared grid mesh doesn't provide (every shipped effect uses a_Position +
    /// a_TexCoord; anything else falls back to the fixed-vertex path).
    public func makeVertexPipeline(vertexShader: String, fragmentShader: String, combos: [String: Int] = [:],
                                   pixelFormat: MTLPixelFormat = .rgba8Unorm) -> MTLRenderPipelineState? {
        let attributes = WEShaderTranspiler.vertexAttributes(vertexShader, combos: combos)
        guard !attributes.isEmpty,
              attributes.allSatisfy({ $0.name == "a_Position" || $0.name == "a_TexCoord" }) else { return nil }
        guard let vertexLibrary = try? device.makeLibrary(source: WEShaderTranspiler.vertexToMSL(vertexShader, combos: combos), options: nil),
              let vertex = vertexLibrary.makeFunction(name: "we_vertex"),
              let fragmentLibrary = try? device.makeLibrary(source: WEShaderTranspiler.fragmentToMSL(fragmentShader, combos: combos), options: nil),
              let fragment = fragmentLibrary.makeFunction(name: "we_fragment") else { return nil }

        let vertexDescriptor = MTLVertexDescriptor()
        for (index, attribute) in attributes.enumerated() {
            vertexDescriptor.attributes[index].bufferIndex = Self.gridBufferIndex
            if attribute.name == "a_Position" {
                vertexDescriptor.attributes[index].format = .float3
                vertexDescriptor.attributes[index].offset = 0
            } else {
                vertexDescriptor.attributes[index].format = .float2
                vertexDescriptor.attributes[index].offset = 12   // after the float3 position
            }
        }
        vertexDescriptor.layouts[Self.gridBufferIndex].stride = 20   // float3 + float2, tightly packed
        vertexDescriptor.layouts[Self.gridBufferIndex].stepFunction = .perVertex

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Map a WE FBO format token to a Metal pixel format. Intermediate blur/glow buffers are usually the
    /// backbuffer's rgba8; HDR bloom uses 16-bit float so bright values survive accumulation.
    public static func pixelFormat(for weFormat: String) -> MTLPixelFormat {
        switch weFormat {
        case "rgb161616f", "rgba16f", "rgba16161616f": return .rgba16Float
        case "r8": return .r8Unorm
        case "rg88": return .rg8Unorm
        default: return .rgba8Unorm   // rgba_backbuffer, rgba8888
        }
    }

    /// A render-target texture of the given size and format (shader-readable, so a later pass can sample it).
    public func makeTarget(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba8Unorm) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    /// Run one effect pass into `output`: bind each `(index, texture)` to both stages at its sampler slot,
    /// feed the stage uniform buffers, and draw — the tessellated grid through the effect's own vertex when
    /// `hasVertex`, else the fixed full-screen quad. Returns false on a uniform overflow or GPU fault.
    public func renderPass(pipeline: MTLRenderPipelineState, hasVertex: Bool,
                           inputs: [(index: Int, texture: MTLTexture)],
                           vertexUniforms: Data? = nil, fragmentUniforms: Data? = nil,
                           into output: MTLTexture) -> Bool {
        // setVertexBytes/setFragmentBytes are capped at 4 KB; a crafted effect with a huge uniform block
        // would abort the render, so drop the pass instead (the layer still composites without it).
        if let fragmentUniforms, fragmentUniforms.count > 4096 { return false }
        if let vertexUniforms, vertexUniforms.count > 4096 { return false }
        guard let commandBuffer = queue.makeCommandBuffer() else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        if hasVertex { encoder.setVertexBuffer(gridVertexBuffer, offset: 0, index: Self.gridBufferIndex) }
        if let vertexUniforms, !vertexUniforms.isEmpty {
            vertexUniforms.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setVertexBytes(base, length: vertexUniforms.count, index: 0) }
            }
        }
        // Bind to both stages — a displacement/flow map is sampled in the vertex, colour in the fragment;
        // binding to a stage that doesn't declare the sampler is harmless.
        for (index, texture) in inputs {
            encoder.setVertexTexture(texture, index: index)
            encoder.setVertexSamplerState(sampler, index: index)
            encoder.setFragmentTexture(texture, index: index)
            encoder.setFragmentSamplerState(sampler, index: index)
        }
        if let fragmentUniforms, !fragmentUniforms.isEmpty {
            fragmentUniforms.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setFragmentBytes(base, length: fragmentUniforms.count, index: 0) }
            }
        }
        if hasVertex {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: gridIndexCount,
                                          indexType: .uint32, indexBuffer: gridIndexBuffer, indexBufferOffset: 0)
        } else {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.error == nil   // a GPU fault leaves the target undefined — fail cleanly
    }

    /// Render `input` through an own-vertex effect `pipeline` into a fresh full-size texture: `input` binds
    /// as g_Texture0, `auxTextures` as g_Texture1…, drawing the grid through the effect's vertex stage.
    public func applyVertexEffect(pipeline: MTLRenderPipelineState, to input: MTLTexture, auxTextures: [MTLTexture] = [],
                                  vertexUniforms: Data? = nil, fragmentUniforms: Data? = nil,
                                  width: Int, height: Int) -> MTLTexture? {
        guard let output = makeTarget(width: width, height: height) else { return nil }
        let inputs = [(index: 0, texture: input)] + auxTextures.enumerated().map { (index: $0.offset + 1, texture: $0.element) }
        return renderPass(pipeline: pipeline, hasVertex: true, inputs: inputs,
                          vertexUniforms: vertexUniforms, fragmentUniforms: fragmentUniforms, into: output) ? output : nil
    }

    /// Render `input` through a fragment-only effect `pipeline` (fixed full-screen vertex) into a fresh
    /// texture: `input` binds as g_Texture0, `auxTextures` as g_Texture1…
    public func apply(pipeline: MTLRenderPipelineState, to input: MTLTexture, auxTextures: [MTLTexture] = [],
                      fragmentUniforms: Data? = nil, width: Int, height: Int) -> MTLTexture? {
        guard let output = makeTarget(width: width, height: height) else { return nil }
        let inputs = [(index: 0, texture: input)] + auxTextures.enumerated().map { (index: $0.offset + 1, texture: $0.element) }
        return renderPass(pipeline: pipeline, hasVertex: false, inputs: inputs,
                          fragmentUniforms: fragmentUniforms, into: output) ? output : nil
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
