// SPDX-License-Identifier: MIT
// Provenance: clean-room. Metal compositor for a WE scene: clears to the scene colour, then draws each
// image layer in painter's order as an orthographic quad positioned by its origin/size/scale, blended
// "over" or additively per its material. The MSL shader is authored here and compiled at runtime. No
// GPL source was consulted.
import Foundation
import Metal
import WEImporter
import WEShaderKit

/// The pixels produced by an offscreen render: tightly-packed RGBA8, row-major, top-left origin.
public struct RenderedFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// Per-layer quad placement in clip space (centre and half-extents in NDC).
private struct QuadUniform {
    var center: SIMD2<Float>
    var halfExtent: SIMD2<Float>
    var uvScale: SIMD2<Float>
}

/// One particle sprite for the instanced draw: clip-space centre + half-extent, RGB tint and alpha.
private struct ParticleInstance {
    var center: SIMD2<Float>
    var halfExtent: SIMD2<Float>
    var color: SIMD4<Float>
}

/// A particle system prepared for rendering: its parsed definition, sprite texture, and the number of
/// sprites to simulate (capped to the steady-state count rate × lifetime implies).
private struct PreparedParticles {
    let system: ParticleSystem
    let texture: MTLTexture
    let count: Int
    let isAdditive: Bool
}

/// A layer's effect compiled once: the full-screen pass plus the data to re-pack its uniforms each
/// frame (so a time-varying effect like pulse animates without re-transpiling the shader).
private struct PreparedEffect {
    let pipeline: MTLRenderPipelineState
    let scalars: [ShaderUniform]      // non-sampler uniforms, in declaration order, for packing
    let constants: [String: String]   // the effect's constant values, keyed by material annotation
    let auxTextures: [MTLTexture]      // samplers after g_Texture0 (noise/normal/mask), in binding order
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
    let originAnimation: Vec3Animation?
    let originScale: SIMD2<Float>   // scene units → NDC, for the position animation offset
    let effects: [PreparedEffect]   // post-process passes applied to this layer before compositing
}

/// A scene whose layer textures are decoded and uploaded once, ready to re-render every frame (so an
/// animation loop never touches the disk again).
public final class PreparedScene {
    fileprivate let layers: [PreparedLayer]
    fileprivate let clearColor: SceneVec3
    fileprivate let particles: [PreparedParticles]
    fileprivate let orthoWidth: Double
    fileprivate let orthoHeight: Double

    fileprivate init(layers: [PreparedLayer], clearColor: SceneVec3, particles: [PreparedParticles],
                     orthoWidth: Double, orthoHeight: Double) {
        self.layers = layers
        self.clearColor = clearColor
        self.particles = particles
        self.orthoWidth = orthoWidth
        self.orthoHeight = orthoHeight
    }

    /// How many layers will be drawn (0 means nothing resolved — the caller should show a fallback).
    public var layerCount: Int { layers.count }

    /// True if any layer animates (parallax, alpha/position keyframes, effects) or the scene emits
    /// particles — i.e. it moves over time and is worth driving with a render loop.
    public var hasAnimation: Bool {
        !particles.isEmpty || layers.contains {
            $0.parallaxDepth != SIMD2<Float>(0, 0) || $0.alphaAnimation != nil
                || $0.originAnimation != nil || !$0.effects.isEmpty
        }
    }
}

/// Renders a `RenderableScene` to an offscreen frame: clear colour plus every visible image layer
/// composited in order. Parallax, rotation and effects build on top of this.
public final class SceneRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelineOver: MTLRenderPipelineState
    private let pipelineAdditive: MTLRenderPipelineState
    private let particleAdditive: MTLRenderPipelineState   // instanced sprite draw, additive (glow)
    private let particleAlpha: MTLRenderPipelineState      // instanced sprite draw, alpha (solid sprites)
    private let sampler: MTLSamplerState
    private let whiteTexture: MTLTexture
    private let blackTexture: MTLTexture           // util/black aux default
    private let noiseTexture: MTLTexture           // util/noise aux default (procedural)
    private let haloTexture: MTLTexture            // soft radial glow for unshipped built-in sprites
    private let effectRenderer: EffectRenderer?   // compiles + runs per-layer post-process effects
    private var auxCache: [String: MTLTexture] = [:]   // resolved packaged aux textures, by name
    private var pooledOutput: MTLTexture?              // reused frame target (rendering is synchronous)

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
    struct PInst { float2 center; float2 halfExtent; float4 color; };
    struct POut { float4 position [[position]]; float2 uv; float4 color; };
    vertex POut lumora_particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                       constant PInst *insts [[buffer(0)]]) {
        float2 corner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]    = { float2(0, 1),  float2(1, 1),  float2(0, 0),  float2(1, 0) };
        PInst p = insts[iid];
        POut out;
        out.position = float4(p.center + corner[vid] * p.halfExtent, 0, 1);
        out.uv = uvs[vid];
        out.color = p.color;
        return out;
    }
    fragment float4 lumora_particle_fragment(POut in [[stage_in]],
                                             texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]]) {
        float4 t = tex.sample(samp, in.uv);
        return float4(t.rgb * in.color.rgb, t.a * in.color.a);
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
                  let particleVertex = library.makeFunction(name: "lumora_particle_vertex"),
                  let particleFragment = library.makeFunction(name: "lumora_particle_fragment"),
                  let over = Self.makePipeline(device: device, vertex: vertexFunction,
                                               fragment: fragmentFunction, additive: false),
                  let additive = Self.makePipeline(device: device, vertex: vertexFunction,
                                                   fragment: fragmentFunction, additive: true),
                  let particleAdd = Self.makeParticlePipeline(device: device, vertex: particleVertex,
                                                              fragment: particleFragment, additive: true),
                  let particleOver = Self.makeParticlePipeline(device: device, vertex: particleVertex,
                                                               fragment: particleFragment, additive: false) else { return nil }
            self.pipelineOver = over
            self.pipelineAdditive = additive
            self.particleAdditive = particleAdd
            self.particleAlpha = particleOver
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

        guard let black = Self.makeDataTexture([0, 0, 0, 255], width: 1, height: 1, device: device),
              let noise = Self.makeDataTexture(Self.noisePixels(side: 256), width: 256, height: 256, device: device),
              let halo = Self.makeDataTexture(Self.haloPixels(side: 64), width: 64, height: 64, device: device) else { return nil }
        self.blackTexture = black
        self.noiseTexture = noise
        self.haloTexture = halo

        self.effectRenderer = EffectRenderer(device: device)   // nil only if the device can't build it
    }

    /// Build a shader-readable RGBA8 texture from tightly-packed bytes.
    private static func makeDataTexture(_ bytes: [UInt8], width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = bytes
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: width * 4)
        return texture
    }

    /// A soft white radial glow (alpha falls off from centre) standing in for WE's unshipped built-in
    /// particle sprites (halo, glow, drop) — additive blend turns it into a luminous orb.
    private static func haloPixels(side: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let center = Double(side - 1) / 2
        for y in 0 ..< side {
            for x in 0 ..< side {
                let dx = (Double(x) - center) / center, dy = (Double(y) - center) / center
                let falloff = max(0, 1 - (dx * dx + dy * dy).squareRoot())
                let i = (y * side + x) * 4
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255
                pixels[i + 3] = UInt8(max(0, min(255, falloff * falloff * 255)))
            }
        }
        return pixels
    }

    /// A deterministic grayscale value-noise tile for WE's `util/noise` aux default (grain/shimmer).
    private static func noisePixels(side: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var state: UInt32 = 0x9E3779B9
        for i in 0 ..< side * side {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5   // xorshift32
            let v = UInt8(state & 0xFF)
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v
        }
        return pixels
    }

    /// Resolve a sampler's texture name to a texture: WE built-ins procedurally, packaged textures from
    /// the scene, anything unknown to white (so a missing aux never blanks the pass).
    private func resolveAuxTexture(_ name: String?, package: ScenePackage) -> MTLTexture {
        guard let name, !name.isEmpty else { return whiteTexture }
        switch name {
        case "util/white": return whiteTexture
        case "util/black": return blackTexture
        case let n where n.hasPrefix("util/noise") || n.hasSuffix("noise"): return noiseTexture
        default:
            if let cached = auxCache[name] { return cached }
            if let entry = package.entry(named: "materials/\(name).tex"),
               let decoded = try? SceneTexture.decodeFirstMip(entry.data),
               let texture = MetalTexture.make(decoded, device: device) {
                auxCache[name] = texture
                return texture
            }
            return whiteTexture
        }
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

    /// The instanced particle pipeline: additive (glow) or alpha-over (solid sprites) blend.
    private static func makeParticlePipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction,
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
            let center = SIMD2(Float(layer.origin.x / orthoW * 2 - 1), Float(layer.origin.y / orthoH * 2 - 1))
            let halfExtent = SIMD2(Float(sizeW * layer.scale.x / orthoW), Float(sizeH * layer.scale.y / orthoH))
            let tint = SIMD3(Float(layer.color.x), Float(layer.color.y), Float(layer.color.z))
            prepared.append(PreparedLayer(
                texture: texture,
                center: center,
                halfExtent: halfExtent,
                uvScale: uvScale,
                alpha: Float(layer.alpha),
                alphaAnimation: layer.alphaAnimation,
                tint: tint,
                isAdditive: layer.blending == "additive" || layer.blending == "add",
                parallaxDepth: SIMD2(Float(layer.parallaxDepth.x), Float(layer.parallaxDepth.y)),
                originAnimation: layer.originAnimation,
                originScale: SIMD2(Float(2 / orthoW), Float(2 / orthoH)),
                effects: prepareEffects(layer.effects, package: package, base: texture,
                                        center: center, halfExtent: halfExtent, uvScale: uvScale, tint: tint)))
        }

        var preparedParticles: [PreparedParticles] = []
        for system in document.particleSystems {
            guard let sprite = particleSprite(system, package: package) else { continue }
            // Steady-state live count ≈ spawn rate × longest lifetime, capped to the system's maxcount.
            let count = min(system.maxCount, max(1, Int((system.rate * system.lifetime.upperBound).rounded(.up))))
            preparedParticles.append(PreparedParticles(system: system, texture: sprite.texture,
                                                       count: count, isAdditive: sprite.isAdditive))
        }
        return PreparedScene(layers: prepared, clearColor: document.clearColor,
                             particles: preparedParticles, orthoWidth: orthoW, orthoHeight: orthoH)
    }

    /// The sprite a particle system draws — its material's first bound texture and blend mode
    /// (additive for glowy sparks/embers, alpha-over for solid sprites like petals/butterflies). Returns
    /// nil if the sprite can't be resolved, so the system is skipped rather than drawn as white squares.
    private func particleSprite(_ system: ParticleSystem, package: ScenePackage) -> (texture: MTLTexture, isAdditive: Bool)? {
        guard let materialPath = system.materialPath, let entry = package.entry(named: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: entry.data)) as? [String: Any],
              let pass = (material["passes"] as? [[String: Any]])?.first,
              let name = (pass["textures"] as? [Any])?.compactMap({ $0 as? String }).first,
              let texture = spriteTexture(named: name, package: package)
        else { return nil }
        let blending = (pass["blending"] as? String) ?? "normal"
        return (texture, blending == "additive" || blending == "add")
    }

    /// Load a particle sprite: WE's common built-in shapes procedurally (they aren't shipped in the
    /// package), packaged sprites from the scene, else nil so the system is skipped.
    private func spriteTexture(named name: String, package: ScenePackage) -> MTLTexture? {
        if name.hasPrefix("util/") { return resolveAuxTexture(name, package: package) }
        // Packaged sprite from the scene takes priority.
        if let entry = package.entry(named: "materials/\(name).tex"),
           let decoded = try? SceneTexture.decodeFirstMip(entry.data),
           let made = MetalTexture.make(decoded, device: device) {
            return made
        }
        // WE's unshipped built-in sprites: blob-like glows (halo, fire, fog, dot, flare, …) approximate
        // well as a soft radial glow tinted by the particle's colour. Elongated shapes (shafts, beams,
        // lightning) and detailed debris don't — skip those rather than draw a wrong blob.
        if name.hasPrefix("particle/") {
            let blob = ["halo", "glow", "drop", "fire", "dot", "fog", "flare", "smoke", "spark", "star", "bokeh", "circle"]
            let elongated = ["shaft", "beam", "lightning", "bolt", "ray", "trail", "streak", "debris"]
            if blob.contains(where: name.contains), !elongated.contains(where: name.contains) {
                return haloTexture
            }
        }
        return nil
    }

    /// Compile a layer's effects and keep only the ones that actually contribute. Each fragment shader is
    /// transpiled into a pipeline; effects that fail to build are dropped. Then the chain is dry-run at
    /// low resolution and any pass that blanks the layer (a not-yet-supported effect — vertex
    /// displacement, multi-pass blur, …) is skipped, so an unsupported effect degrades gracefully
    /// instead of turning the whole layer transparent.
    private func prepareEffects(_ effects: [LayerEffect], package: ScenePackage, base: MTLTexture,
                                center: SIMD2<Float>, halfExtent: SIMD2<Float>, uvScale: SIMD2<Float>,
                                tint: SIMD3<Float>) -> [PreparedEffect] {
        guard let effectRenderer, !effects.isEmpty else { return [] }
        var compiled: [PreparedEffect] = []
        for effect in effects {
            guard let entry = package.entry(named: effect.fragmentShaderPath) else { continue }
            let source = String(decoding: entry.data, as: UTF8.self)
            guard let pipeline = effectRenderer.makePipeline(fragmentShader: source, combos: effect.combos) else { continue }
            let resolved = ShaderPreprocessor.resolve(source,
                combos: ShaderPreprocessor.comboDefaults(source).merging(effect.combos) { _, b in b })
            let uniforms = ShaderUniforms.parse(resolved)
            // Resolve each aux sampler (everything after g_Texture0) to a real texture. The source index
            // comes from the name (g_TextureN) so combo-excluded samplers don't shift the binding; the
            // name is taken from the material's binding, else the sampler's annotated default.
            let samplers = uniforms.filter { $0.type.hasPrefix("sampler") }
            let auxTextures: [MTLTexture] = samplers.dropFirst().map { sampler in
                let index = Int(sampler.name.dropFirst("g_Texture".count)) ?? -1
                let bound = (index >= 0 && index < effect.textures.count) ? effect.textures[index] : nil
                return resolveAuxTexture(bound ?? sampler.defaultValue, package: package)
            }
            compiled.append(PreparedEffect(
                pipeline: pipeline,
                scalars: uniforms.filter { !$0.type.hasPrefix("sampler") },
                constants: effect.constants,
                auxTextures: auxTextures))
        }
        guard !compiled.isEmpty else { return [] }

        // Dry-run the chain on a small copy of the layer and keep only passes that preserve the layer's
        // coverage at every sampled time. An effect this renderer can't yet do (vertex displacement,
        // multi-pass blur) punches the layer out to the clear colour — sometimes only at certain phases
        // of its animation — so a pass is dropped unless it stays stable across the whole sample set.
        let probeW = 320, probeH = 180
        let times: [Float] = [0, 1.3, 2.6, 4.1, 5.7]
        guard var probe = renderQuadToTexture(base, center: center, halfExtent: halfExtent, uvScale: uvScale,
                                               tint: tint, width: probeW, height: probeH) else { return compiled }
        let probeRGBA = effectRenderer.readback(probe)
        var probeCoverage = coverage(probeRGBA)
        var probeDetail = detail(probeRGBA)
        var kept: [PreparedEffect] = []
        for effect in compiled {
            let aux = effect.auxTextures
            var stableOutput: MTLTexture?
            var stableRGBA: Data?
            var stable = true
            for time in times {
                let uniforms = UniformPacker.pack(effect.scalars, values: effect.constants, overrides: ["g_Time": [time]])
                guard let output = effectRenderer.apply(pipeline: effect.pipeline, to: probe, auxTextures: aux,
                                                        fragmentUniforms: uniforms.isEmpty ? nil : uniforms,
                                                        width: probeW, height: probeH) else { stable = false; break }
                let rgba = effectRenderer.readback(output)
                // Drop a pass that erases the layer's coverage OR flattens it to near-uniform colour — the
                // latter catches effects that blend against the placeholder aux texture and blow out (e.g.
                // a screen blend against white), which a coverage-only check misses.
                guard coverage(rgba) >= probeCoverage / 2, detail(rgba) >= probeDetail / 5 else { stable = false; break }
                if time == 0 { stableOutput = output; stableRGBA = rgba }
            }
            guard stable, let stableOutput, let stableRGBA else { continue }   // unstable / erasing / flattening
            kept.append(effect)
            probe = stableOutput
            probeCoverage = coverage(stableRGBA)
            probeDetail = detail(stableRGBA)
        }
        return kept
    }

    /// How many pixels are meaningfully opaque (alpha > 100) in an RGBA readback — a proxy for how much
    /// of the layer is still visible after an effect.
    private func coverage(_ rgba: Data) -> Int {
        var count = 0
        for i in stride(from: 3, to: rgba.count, by: 4) where rgba[i] > 100 { count += 1 }
        return count
    }

    /// Variance of the green channel — a proxy for how much image detail survives. Collapses toward 0
    /// when an effect flattens the layer to a single colour.
    private func detail(_ rgba: Data) -> Double {
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for i in stride(from: 1, to: rgba.count, by: 4) {
            let v = Double(rgba[i]); sum += v; sumSq += v * v; n += 1
        }
        guard n > 0 else { return 0 }
        return max(0, sumSq / n - (sum / n) * (sum / n))
    }

    // MARK: - Particles

    /// Analytically place every live sprite of a particle system at `time`. Each slot recycles on its own
    /// lifetime with a staggered phase; a per-life hash seeds its spawn point, velocity, size, colour and
    /// alpha, and the movement operator integrates position (p = p₀ + v·t + ½g·t²). Stateless, so any
    /// frame is reproducible without simulating the ones before it.
    private func simulateParticles(_ prepared: PreparedParticles, time: Double,
                                   orthoW: Double, orthoH: Double) -> [ParticleInstance] {
        let s = prepared.system
        var instances: [ParticleInstance] = []
        instances.reserveCapacity(prepared.count)
        for i in 0 ..< prepared.count {
            let slot = UInt32(truncatingIfNeeded: i)
            let life = lerp(s.lifetime.lowerBound, s.lifetime.upperBound, rand(slot, 101))
            guard life > 0.001 else { continue }
            let t = time + rand(slot, 102) * life          // staggered so they don't all spawn at once
            let cycle = (t / life).rounded(.down)
            let age = t - cycle * life
            let seed = hash(slot, UInt32(truncatingIfNeeded: Int(cycle)))

            let spawnX = s.origin.x + s.boxSize.x * (rand(seed, 1) * 2 - 1)
            let spawnY = s.origin.y + s.boxSize.y * (rand(seed, 2) * 2 - 1)
            // velocity = the velocityrandom range plus a sphere emitter's speed along a masked direction
            var velX = lerp(s.velocity.min.x, s.velocity.max.x, rand(seed, 3))
            var velY = lerp(s.velocity.min.y, s.velocity.max.y, rand(seed, 4))
            if s.speed.upperBound > 0 {
                let dx = (rand(seed, 10) * 2 - 1) * s.directions.x
                let dy = (rand(seed, 11) * 2 - 1) * s.directions.y
                let len = (dx * dx + dy * dy).squareRoot()
                if len > 0.0001 {
                    let speed = lerp(s.speed.lowerBound, s.speed.upperBound, rand(seed, 12))
                    velX += dx / len * speed
                    velY += dy / len * speed
                }
            }
            let size = lerp(s.size.lowerBound, s.size.upperBound, rand(seed, 5))
            let alpha0 = lerp(s.alpha.lowerBound, s.alpha.upperBound, rand(seed, 6))
            let color = SIMD3<Float>(Float(lerp(s.color.min.x, s.color.max.x, rand(seed, 7)) / 255),
                                     Float(lerp(s.color.min.y, s.color.max.y, rand(seed, 8)) / 255),
                                     Float(lerp(s.color.min.z, s.color.max.z, rand(seed, 9)) / 255))

            let posX = spawnX + velX * age + 0.5 * s.gravity.x * age * age
            let posY = spawnY + velY * age + 0.5 * s.gravity.y * age * age
            let lifeFrac = age / life
            let fade = Float(smoothstep(0, 0.15, lifeFrac) * (1 - smoothstep(0.85, 1, lifeFrac)))
            instances.append(ParticleInstance(
                center: SIMD2(Float(posX / orthoW * 2 - 1), Float(posY / orthoH * 2 - 1)),
                halfExtent: SIMD2(Float(size / orthoW), Float(size / orthoH)),
                color: SIMD4(color, Float(alpha0) * fade)))
        }
        return instances
    }

    private func hash(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var h = a &* 0x9E3779B9
        h = (h ^ b) &* 0x85EBCA6B
        h ^= h >> 13; h = h &* 0xC2B2AE35; h ^= h >> 16
        return h
    }
    private func rand(_ seed: UInt32, _ channel: UInt32) -> Double { Double(hash(seed, channel)) / Double(UInt32.max) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
    }

    /// Render a prepared scene at `time` seconds, applying a gentle automatic camera parallax so layers
    /// configured with depth drift slightly — the wallpaper breathes instead of sitting perfectly still.
    /// `time = 0` is the still composite (no sway).
    public func render(_ scene: PreparedScene, width: Int, height: Int, time: Double = 0) -> RenderedFrame? {
        let swayX = Float(0.012 * sin(time * 0.6))
        let swayY = Float(0.009 * sin(time * 0.45))

        // Pass 1: a layer with effects is rendered to its own texture and run through its effect chain.
        // The result is keyed by layer index; layers without effects are drawn directly in the main pass.
        // Setting LUMORA_NO_EFFECTS skips this and composites every layer flat (a safety/debug switch).
        var effectResult: [Int: MTLTexture] = [:]
        if let effectRenderer, ProcessInfo.processInfo.environment["LUMORA_NO_EFFECTS"] == nil {
            for (index, layer) in scene.layers.enumerated() where !layer.effects.isEmpty {
                let center = animatedCenter(layer, time: time, swayX: swayX, swayY: swayY)
                guard var texture = renderQuadToTexture(layer.texture, center: center, halfExtent: layer.halfExtent,
                                                        uvScale: layer.uvScale, tint: layer.tint,
                                                        width: width, height: height) else { continue }
                for effect in layer.effects {
                    let uniforms = UniformPacker.pack(effect.scalars, values: effect.constants,
                                                      overrides: ["g_Time": [Float(time)]])
                    let aux = effect.auxTextures
                    guard let output = effectRenderer.apply(pipeline: effect.pipeline, to: texture, auxTextures: aux,
                                                            fragmentUniforms: uniforms.isEmpty ? nil : uniforms,
                                                            width: width, height: height) else { break }
                    texture = output
                }
                effectResult[index] = texture
            }
        }

        // Pass 2: composite layers in painter's order — the effect result full-screen for effect layers,
        // the layer quad directly otherwise.
        return withRenderPass(clearColor: scene.clearColor, width: width, height: height) { encoder in
            for (index, layer) in scene.layers.enumerated() {
                var alpha = layer.alphaAnimation.map { Float($0.value(at: time)) } ?? layer.alpha
                encoder.setRenderPipelineState(layer.isAdditive ? pipelineAdditive : pipelineOver)
                var quad: QuadUniform
                var tint: SIMD3<Float>
                let texture: MTLTexture
                if let effected = effectResult[index] {   // effect output already sits at the layer's placement
                    quad = QuadUniform(center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1))
                    tint = SIMD3(1, 1, 1)
                    texture = effected
                } else {
                    quad = QuadUniform(center: animatedCenter(layer, time: time, swayX: swayX, swayY: swayY),
                                       halfExtent: layer.halfExtent, uvScale: layer.uvScale)
                    tint = layer.tint
                    texture = layer.texture
                }
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            // Particles draw on top of the composited layers, additively, as instanced sprite quads.
            for prepared in scene.particles {
                let instances = simulateParticles(prepared, time: time,
                                                  orthoW: scene.orthoWidth, orthoH: scene.orthoHeight)
                guard !instances.isEmpty,
                      let buffer = device.makeBuffer(bytes: instances,
                                                     length: MemoryLayout<ParticleInstance>.stride * instances.count,
                                                     options: .storageModeShared) else { continue }
                encoder.setRenderPipelineState(prepared.isAdditive ? particleAdditive : particleAlpha)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentTexture(prepared.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
            }
        }
    }

    /// The layer's clip-space centre at `time`: its placement nudged by the automatic parallax sway and
    /// any keyframed position animation.
    private func animatedCenter(_ layer: PreparedLayer, time: Double, swayX: Float, swayY: Float) -> SIMD2<Float> {
        var center = SIMD2(layer.center.x + swayX * layer.parallaxDepth.x,
                           layer.center.y + swayY * layer.parallaxDepth.y)
        if let animation = layer.originAnimation {
            let offset = animation.offset(at: time)
            center.x += Float(offset.x) * layer.originScale.x
            center.y += Float(offset.y) * layer.originScale.y
        }
        return center
    }

    /// Render one quad (a layer's texture at its placement, tint baked in, full opacity) onto a
    /// transparent target, to feed an effect chain. Returns nil if the target can't be made.
    private func renderQuadToTexture(_ source: MTLTexture, center: SIMD2<Float>, halfExtent: SIMD2<Float>,
                                     uvScale: SIMD2<Float>, tint: SIMD3<Float>, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var quad = QuadUniform(center: center, halfExtent: halfExtent, uvScale: uvScale)
        var alpha: Float = 1
        var tintCopy = tint
        encoder.setRenderPipelineState(pipelineOver)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&tintCopy, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
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
        // Reuse the frame target across renders of the same size: the animation loop renders the same
        // dimensions every frame and each render is synchronous (waitUntilCompleted), so the previous
        // frame is fully read back before the next reuses the texture — no per-frame 33 MB allocation.
        let output: MTLTexture
        if let pooled = pooledOutput, pooled.width == width, pooled.height == height {
            output = pooled
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
            output = made
            pooledOutput = made
        }
        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }

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
