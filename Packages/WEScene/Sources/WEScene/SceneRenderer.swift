// SPDX-License-Identifier: MIT
// Provenance: clean-room. Minimal Metal compositor for a WE scene: clears to the scene's colour and
// draws its base image layer over an orthographic full-screen quad. The shader is WE-dialect-free MSL
// authored here and compiled at runtime. No GPL source was consulted.
import Foundation
import Metal
import WEImporter

/// The pixels produced by an offscreen render: tightly-packed RGBA8, row-major, top-left origin.
public struct RenderedFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data
}

/// Renders a `SceneDocument` to an offscreen frame. First light: clear colour + the base image layer
/// drawn full-screen; multi-layer compositing, parallax and effects build on top of this.
public final class SceneRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut lumora_scene_vertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uv[4]  = { float2(0, 1),  float2(1, 1),  float2(0, 0),  float2(1, 0) };
        VOut out; out.position = float4(pos[vid], 0, 1); out.uv = uv[vid]; return out;
    }
    fragment float4 lumora_scene_fragment(VOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant float &layerAlpha [[buffer(0)]]) {
        float4 c = tex.sample(samp, in.uv);
        return float4(c.rgb, c.a * layerAlpha);
    }
    """

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "lumora_scene_vertex"),
                  let fragmentFunction = library.makeFunction(name: "lumora_scene_fragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .rgba8Unorm
            color.isBlendingEnabled = true                       // straight-alpha "over" compositing
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .sourceAlpha
            color.sourceAlphaBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
    }

    /// Render a scene's base image layer full-screen over its clear colour.
    public func render(_ document: SceneDocument, package: ScenePackage, width: Int, height: Int) -> RenderedFrame? {
        var texture: MTLTexture?
        var alpha: Float = 1
        if let layer = document.layers.first(where: { $0.texturePath != nil }),
           let path = layer.texturePath,
           let entry = package.entry(named: path),
           let decoded = try? SceneTexture.decodeFirstMip(entry.data) {
            texture = MetalTexture.make(decoded, device: device)
            alpha = Float(layer.alpha)
        }
        return render(texture: texture, alpha: alpha, clearColor: document.clearColor, width: width, height: height)
    }

    /// Render a single decoded texture full-screen over `clearColor` (used for previews and tests).
    public func render(decoded: DecodedTexture, alpha: Float = 1, clearColor: SceneVec3, width: Int, height: Int) -> RenderedFrame? {
        render(texture: MetalTexture.make(decoded, device: device), alpha: alpha,
               clearColor: clearColor, width: width, height: height)
    }

    /// Core pass: clear to `clearColor`, then (if given) draw `texture` full-screen at `alpha`.
    public func render(texture: MTLTexture?, alpha: Float, clearColor: SceneVec3, width: Int, height: Int) -> RenderedFrame? {
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
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: clearColor.x, green: clearColor.y, blue: clearColor.z, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        if let texture {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var layerAlpha = alpha
            encoder.setFragmentBytes(&layerAlpha, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            output.getBytes(base, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return RenderedFrame(width: width, height: height, rgba: rgba)
    }
}
