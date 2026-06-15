// SPDX-License-Identifier: MIT
// Provenance: clean-room. Metal compositor for a WE scene: clears to the scene colour, then draws each
// image layer in painter's order as an orthographic quad positioned by its origin/size/scale, blended
// "over" or additively per its material. The MSL shader is authored here and compiled at runtime. No
// GPL source was consulted.
import Foundation
import Metal
import WEImporter

/// The pixels produced by an offscreen render: tightly-packed RGBA8, row-major, top-left origin.
public struct RenderedFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data
}

/// Per-layer quad placement in clip space (centre and half-extents in NDC).
private struct QuadUniform {
    var center: SIMD2<Float>
    var halfExtent: SIMD2<Float>
    var uvScale: SIMD2<Float>
}

/// One layer of a `PreparedScene`: an uploaded texture plus its resolution-independent placement.
private struct PreparedLayer {
    let texture: MTLTexture
    let center: SIMD2<Float>
    let halfExtent: SIMD2<Float>
    let uvScale: SIMD2<Float>
    let alpha: Float
    let alphaAnimation: AlphaAnimation?
    let tint: SIMD3<Float>
    let isAdditive: Bool
    let parallaxDepth: SIMD2<Float>
}

/// A scene whose layer textures are decoded and uploaded once, ready to re-render every frame (so an
/// animation loop never touches the disk again).
public final class PreparedScene {
    fileprivate let layers: [PreparedLayer]
    fileprivate let clearColor: SceneVec3

    fileprivate init(layers: [PreparedLayer], clearColor: SceneVec3) {
        self.layers = layers
        self.clearColor = clearColor
    }

    /// How many layers will be drawn (0 means nothing resolved — the caller should show a fallback).
    public var layerCount: Int { layers.count }

    /// True if any layer animates (parallax depth or an alpha keyframe animation), i.e. the scene moves
    /// over time and is worth driving with a render loop (otherwise one still render suffices).
    public var hasAnimation: Bool {
        layers.contains { $0.parallaxDepth != SIMD2<Float>(0, 0) || $0.alphaAnimation != nil }
    }
}

/// Renders a `RenderableScene` to an offscreen frame: clear colour plus every visible image layer
/// composited in order. Parallax, rotation and effects build on top of this.
public final class SceneRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelineOver: MTLRenderPipelineState
    private let pipelineAdditive: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let whiteTexture: MTLTexture

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float2 center; float2 halfExtent; float2 uvScale; };
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut lumora_scene_vertex(uint vid [[vertex_id]], constant Quad &quad [[buffer(0)]]) {
        float2 corner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]    = { float2(0, 1),  float2(1, 1),  float2(0, 0),  float2(1, 0) };
        VOut out;
        out.position = float4(quad.center + corner[vid] * quad.halfExtent, 0, 1);
        out.uv = uvs[vid] * quad.uvScale;   // sample only the content region of a padded texture
        return out;
    }
    fragment float4 lumora_scene_fragment(VOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant float &layerAlpha [[buffer(0)]],
                                          constant float3 &tint [[buffer(1)]]) {
        float4 c = tex.sample(samp, in.uv);
        return float4(c.rgb * tint, c.a * layerAlpha);
    }
    """

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "lumora_scene_vertex"),
                  let fragmentFunction = library.makeFunction(name: "lumora_scene_fragment"),
                  let over = Self.makePipeline(device: device, vertex: vertexFunction,
                                               fragment: fragmentFunction, additive: false),
                  let additive = Self.makePipeline(device: device, vertex: vertexFunction,
                                                   fragment: fragmentFunction, additive: true) else { return nil }
            self.pipelineOver = over
            self.pipelineAdditive = additive
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

        // A 1×1 white texture lets solid-colour fill layers reuse the textured pipeline (tinted by
        // their colour) instead of needing a separate shader.
        let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        whiteDescriptor.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: whiteDescriptor) else { return nil }
        var whitePixel: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &whitePixel, bytesPerRow: 4)
        self.whiteTexture = white
    }

    private static func makePipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction,
                                     additive: Bool) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .rgba8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.sourceAlphaBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Decode and upload every visible layer's texture once into a `PreparedScene`, so the render loop
    /// can redraw every frame without touching the disk. Placement is resolution-independent (NDC).
    public func prepare(_ document: RenderableScene, package: ScenePackage) -> PreparedScene {
        let orthoW = Double(document.orthoWidth > 0 ? document.orthoWidth : 1920)
        let orthoH = Double(document.orthoHeight > 0 ? document.orthoHeight : 1080)
        var prepared: [PreparedLayer] = []
        // Solid fills are kept only while still behind every textured layer (a background) — a solid
        // layer above the artwork is usually an animated flash that a still frame would over-paint.
        var drewTexturedLayer = false
        for layer in document.layers where layer.visible {
            var texture: MTLTexture?
            var textureW = 0.0, textureH = 0.0
            var uvScale = SIMD2<Float>(1, 1)
            var isSolidFill = false
            if let path = layer.texturePath,
               let entry = package.entry(named: path),
               let decoded = try? SceneTexture.decodeFirstMip(entry.data),
               let made = MetalTexture.make(decoded, device: device) {
                texture = made
                textureW = Double(decoded.imageWidth)
                textureH = Double(decoded.imageHeight)
                if decoded.width > 0, decoded.height > 0 {
                    uvScale = SIMD2(Float(min(1.0, Double(decoded.imageWidth) / Double(decoded.width))),
                                    Float(min(1.0, Double(decoded.imageHeight) / Double(decoded.height))))
                }
            } else if layer.isSolidLayer, !drewTexturedLayer {
                texture = whiteTexture            // a background solid fill: white texel, tinted
                textureW = orthoW
                textureH = orthoH
                isSolidFill = true
            }
            guard let texture else { continue }   // unresolved non-solid, or a foreground fill: skip
            if !isSolidFill { drewTexturedLayer = true }

            let sizeW = (layer.size?.x ?? 0) > 0 ? layer.size!.x : (textureW > 0 ? textureW : orthoW)
            let sizeH = (layer.size?.y ?? 0) > 0 ? layer.size!.y : (textureH > 0 ? textureH : orthoH)
            prepared.append(PreparedLayer(
                texture: texture,
                center: SIMD2(Float(layer.origin.x / orthoW * 2 - 1), Float(layer.origin.y / orthoH * 2 - 1)),
                halfExtent: SIMD2(Float(sizeW * layer.scale.x / orthoW), Float(sizeH * layer.scale.y / orthoH)),
                uvScale: uvScale,
                alpha: Float(layer.alpha),
                alphaAnimation: layer.alphaAnimation,
                tint: SIMD3(Float(layer.color.x), Float(layer.color.y), Float(layer.color.z)),
                isAdditive: layer.blending == "additive" || layer.blending == "add",
                parallaxDepth: SIMD2(Float(layer.parallaxDepth.x), Float(layer.parallaxDepth.y))))
        }
        return PreparedScene(layers: prepared, clearColor: document.clearColor)
    }

    /// Render a prepared scene at `time` seconds, applying a gentle automatic camera parallax so layers
    /// configured with depth drift slightly — the wallpaper breathes instead of sitting perfectly still.
    /// `time = 0` is the still composite (no sway).
    public func render(_ scene: PreparedScene, width: Int, height: Int, time: Double = 0) -> RenderedFrame? {
        let swayX = Float(0.012 * sin(time * 0.6))
        let swayY = Float(0.009 * sin(time * 0.45))
        return withRenderPass(clearColor: scene.clearColor, width: width, height: height) { encoder in
            for layer in scene.layers {
                var quad = QuadUniform(
                    center: SIMD2(layer.center.x + swayX * layer.parallaxDepth.x,
                                  layer.center.y + swayY * layer.parallaxDepth.y),
                    halfExtent: layer.halfExtent,
                    uvScale: layer.uvScale)
                var alpha = layer.alphaAnimation.map { Float($0.value(at: time)) } ?? layer.alpha
                var tint = layer.tint
                encoder.setRenderPipelineState(layer.isAdditive ? pipelineAdditive : pipelineOver)
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
                encoder.setFragmentTexture(layer.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
    }

    /// Convenience: prepare and render a scene as a single still frame.
    public func render(_ document: RenderableScene, package: ScenePackage, width: Int, height: Int) -> RenderedFrame? {
        render(prepare(document, package: package), width: width, height: height)
    }

    /// Render a single decoded texture full-screen over `clearColor` (used for previews and tests).
    public func render(decoded: DecodedTexture, alpha: Float = 1, clearColor: SceneVec3, width: Int, height: Int) -> RenderedFrame? {
        render(texture: MetalTexture.make(decoded, device: device), alpha: alpha,
               clearColor: clearColor, width: width, height: height)
    }

    /// Core helper: clear to `clearColor`, then (if given) draw `texture` full-screen at `alpha`.
    public func render(texture: MTLTexture?, alpha: Float, clearColor: SceneVec3, width: Int, height: Int) -> RenderedFrame? {
        withRenderPass(clearColor: clearColor, width: width, height: height) { encoder in
            guard let texture else { return }
            var quad = QuadUniform(center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1))
            var layerAlpha = alpha
            var tint = SIMD3<Float>(1, 1, 1)
            encoder.setRenderPipelineState(pipelineOver)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&layerAlpha, length: MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Set up an offscreen target, run `draw` inside a clear render pass, and read the pixels back.
    private func withRenderPass(clearColor: SceneVec3, width: Int, height: Int,
                                draw: (MTLRenderCommandEncoder) -> Void) -> RenderedFrame? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: clearColor.x, green: clearColor.y, blue: clearColor.z, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        draw(encoder)
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
