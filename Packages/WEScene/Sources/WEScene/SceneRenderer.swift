// SPDX-License-Identifier: MIT
// Provenance: clean-room. Metal compositor for a WE scene: clears to the scene colour, then draws each
// image layer in painter's order as an orthographic quad positioned by its origin/size/scale, blended
// "over" or additively per its material. The MSL shader is authored here and compiled at runtime. No
// GPL source was consulted.
import Foundation
import Metal
import WECore
import WEImporter
import WEShaderKit
import WESceneDynamics

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
    /// Per-axis clip-space scale that makes the scene COVER a target of a different aspect (fill + crop the
    /// overflow) instead of stretching. Defaults to identity so every other call site is unchanged.
    var aspectScale: SIMD2<Float> = SIMD2(1, 1)
    /// The two rows of a 2×2 rotation applied to the corner offset (for a layer with a roll angle). It's
    /// pre-distorted by the scene's aspect on the CPU so a square layer stays square. Identity = no roll.
    var rotA: SIMD2<Float> = SIMD2(1, 0)
    var rotB: SIMD2<Float> = SIMD2(0, 1)
}

/// Placement uniform for a puppet mesh draw — matches the MSL `PuppetU` (origin/scale in scene units, the
/// ortho size, and the cover aspect scale).
private struct PuppetU {
    var origin: SIMD2<Float>
    var scale: SIMD2<Float>
    var ortho: SIMD2<Float>
    var aspectScale: SIMD2<Float>
}

/// One particle sprite for the instanced draw: clip-space centre + half-extent, RGB tint and alpha.
private struct ParticleInstance {
    var center: SIMD2<Float>
    var halfExtent: SIMD2<Float>
    var color: SIMD4<Float>
    var rotor: SIMD2<Float>   // (cos θ, sin θ) — the sprite's screen-plane rotation this frame
}

/// A particle system prepared for rendering: its parsed definition, sprite texture, and the number of
/// sprites to simulate (capped to the steady-state count rate × lifetime implies).
private struct PreparedParticles {
    let system: ParticleSystem
    let texture: MTLTexture
    let normalTexture: MTLTexture?   // for refractive droplets (rain-on-glass): the surface normal map
    let count: Int
    let isAdditive: Bool
    let isRefractive: Bool           // draw by refracting the background through the normal map
    let instanceBuffer: MTLBuffer    // sized for `count` instances, refilled each frame (not reallocated)
}

/// How a pass's sampler slot gets its texture each frame: the effect's input ("previous"), a named
/// intermediate buffer, or a fixed aux texture (noise/mask) resolved once at prepare time.
private enum EffectInput {
    case previous
    case buffer(String)
    case aux(MTLTexture)
}

/// One compiled pass of an effect: the pipeline, whether it runs its own vertex over the grid, the uniform
/// layouts to re-pack each frame, the named target it writes (nil = the effect output), and, per declared
/// sampler, the WE g_Texture<n> number it is plus where its texture comes from.
private struct PreparedPass {
    let pipeline: MTLRenderPipelineState
    let hasVertex: Bool
    let scalars: [ShaderUniform]       // fragment non-sampler uniforms, declaration order
    let vertexScalars: [ShaderUniform] // vertex non-sampler uniforms (empty when !hasVertex)
    let constants: [String: String]
    let target: String?                // named FBO it renders into; nil = the effect's full-size output
    let samplers: [(slot: Int, number: Int, input: EffectInput)]   // slot = bind index; number = g_Texture<number>
}

/// A layer's effect compiled once: its pass graph and the intermediate buffers the passes wire together.
private struct PreparedEffect {
    let passes: [PreparedPass]
    let fbos: [EffectFBO]
}

/// One layer of a `PreparedScene`: an uploaded texture plus its resolution-independent placement.
/// A video-backed layer's animation frames. Decoding a couple dozen exact frames with seeks is slow,
/// so it runs off the render thread; the decoded CPU pixels are handed back under a lock and uploaded
/// to the GPU lazily, the first time the render thread asks for them. `@unchecked Sendable`: `pending`
/// is lock-guarded; `uploaded`/`frameDuration` are only ever touched on the render thread.
final class VideoFrameTrack: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (frames: [DecodedTexture], duration: Double)?
    private var uploaded: [MTLTexture] = []
    private(set) var frameDuration = 0.0

    /// Called once from the background decode queue.
    func deliver(_ frames: [DecodedTexture], duration: Double) {
        lock.lock(); pending = (frames, duration); lock.unlock()
    }

    /// The uploaded frames, uploading the delivered batch on first use. Render-thread only.
    func frames(device: MTLDevice) -> [MTLTexture] {
        guard uploaded.isEmpty else { return uploaded }
        lock.lock(); let batch = pending; pending = nil; lock.unlock()
        guard let batch else { return [] }
        let textures = batch.frames.compactMap { MetalTexture.make($0, device: device) }
        guard textures.count >= 2 else { return [] }
        uploaded = textures
        frameDuration = batch.duration / Double(textures.count)
        return uploaded
    }
}

/// A puppet layer's mesh, uploaded once: the (position, uv) vertex stream, the triangle indices, and the
/// scene placement (origin/scale in scene units + the ortho size) that maps model space into the frame.
private struct PreparedPuppet {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let origin: SIMD2<Float>
    let scale: SIMD2<Float>
    let ortho: SIMD2<Float>
}

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
    let rotA: SIMD2<Float>          // 2×2 roll (rows), aspect-corrected; identity when the layer isn't rolled
    let rotB: SIMD2<Float>
    let effects: [PreparedEffect]   // post-process passes applied to this layer before compositing
    let videoTrack: VideoFrameTrack?  // video-texture animation frames (nil = static `texture`)
    let puppet: PreparedPuppet?     // skeletal mesh to draw instead of the quad (nil = ordinary layer)
    let text: PreparedTextLayer?    // a text/clock layer drawn from rendered glyphs (nil = ordinary layer)
    let scriptGroup: PreparedScriptGroup?  // an audio visualiser that clones this layer into bars (nil = ordinary)
}

/// A layer whose bound SceneScript clones it into N elements (an audio visualiser's spectrum bars). The
/// bar sprite + its size-1 extent are captured once; each frame the runtime is fed the current spectrum,
/// run, and the layers it produced are drawn as quads. Degrades gracefully: with no audio the spectrum is
/// zeros, so the script leaves every bar flat (height 0) and nothing spurious is drawn.
private final class PreparedScriptGroup {
    let runtime: SceneScriptRuntime
    let texture: MTLTexture
    let baseHalfExtent: SIMD2<Float>   // a bar's NDC half-extent at the script's scale = 1 (before per-bar scale)
    let uvScale: SIMD2<Float>
    let isAdditive: Bool
    let orthoW: Double
    let orthoH: Double

    init(runtime: SceneScriptRuntime, texture: MTLTexture, baseHalfExtent: SIMD2<Float>,
         uvScale: SIMD2<Float>, isAdditive: Bool, orthoW: Double, orthoH: Double) {
        self.runtime = runtime
        self.texture = texture
        self.baseHalfExtent = baseHalfExtent
        self.uvScale = uvScale
        self.isAdditive = isAdditive
        self.orthoW = orthoW
        self.orthoH = orthoH
    }
}

/// A scene whose layer textures are decoded and uploaded once, ready to re-render every frame (so an
/// animation loop never touches the disk again).
public final class PreparedScene {
    fileprivate let layers: [PreparedLayer]
    fileprivate let clearColor: SceneVec3
    fileprivate let particles: [PreparedParticles]
    fileprivate let orthoWidth: Double
    fileprivate let orthoHeight: Double
    /// True when the scene has at least one puppet layer and EVERY puppet layer assembled into a sane mesh.
    /// A puppet scene that isn't ready would draw its raw atlas as scattered parts, so the caller should show
    /// the static preview instead; a ready one can be rendered live like any other scene.
    public let puppetReady: Bool

    fileprivate init(layers: [PreparedLayer], clearColor: SceneVec3, particles: [PreparedParticles],
                     orthoWidth: Double, orthoHeight: Double, puppetReady: Bool) {
        self.layers = layers
        self.clearColor = clearColor
        self.particles = particles
        self.orthoWidth = orthoWidth
        self.orthoHeight = orthoHeight
        self.puppetReady = puppetReady
    }

    /// How many layers will be drawn (0 means nothing resolved — the caller should show a fallback).
    public var layerCount: Int { layers.count }

    /// True if the scene has anything to draw — image layers or particles. A particle-only scene has no
    /// layers but still renders its sprites over the clear colour.
    public var isRenderable: Bool { !layers.isEmpty || !particles.isEmpty }

    /// True if any particle system refracts the background (rain-on-glass) — the renderer takes a two-pass
    /// path for these, composing the scene to a texture the droplets then sample with displacement.
    fileprivate var hasRefractiveParticles: Bool { particles.contains { $0.isRefractive } }

    /// True if any layer animates (parallax, alpha/position keyframes, effects) or the scene emits
    /// particles — i.e. it moves over time and is worth driving with a render loop.
    public var hasAnimation: Bool {
        !particles.isEmpty || layers.contains {
            $0.parallaxDepth != SIMD2<Float>(0, 0) || $0.alphaAnimation != nil
                || $0.originAnimation != nil || !$0.effects.isEmpty || $0.videoTrack != nil
                || $0.scriptGroup != nil || ($0.text?.isDynamic == true)
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
    private let particleRefract: MTLRenderPipelineState    // refractive droplets sampling the background
    private let pipelinePuppet: MTLRenderPipelineState     // skeletal puppet mesh (over-blend), atlas-textured
    private let sampler: MTLSamplerState
    private let whiteTexture: MTLTexture
    private let blackTexture: MTLTexture           // util/black aux default
    private let noiseTexture: MTLTexture           // util/noise aux default (procedural)
    private let haloTexture: MTLTexture            // soft radial glow for unshipped built-in sprites
    private let effectRenderer: EffectRenderer?   // compiles + runs per-layer post-process effects
    private var auxCache: [String: MTLTexture] = [:]   // resolved packaged aux textures, by name
    private var pooledOutput: MTLTexture?              // reused frame target (rendering is synchronous)
    private var pooledBackground: MTLTexture?          // reused composited-scene target for refractive scenes
    // Effect render targets are reused across frames instead of reallocated every frame. Rendering is fully
    // synchronous (each pass waits for the GPU), and targets are only recycled after the frame is composited,
    // so a borrowed texture is never aliased while still in use.
    private var effectTexturePool: [Int: [MTLTexture]] = [:]
    private var effectTexturesInUse: [MTLTexture] = []
    // The audio spectra (g_AudioSpectrum16/32/64 Left/Right) for the frame being rendered, as packer
    // overrides keyed by uniform name. Set at the top of render() from the AudioSpectrumProvider; merged
    // into every effect pass's uniforms. Empty (no audio uniforms touched) when the source is silent.
    private var currentAudioOverrides: [String: [Float]] = [:]
    // Target pixels per scene unit for the frame being rendered, set at the top of render(). Text layers
    // rasterise at this density so glyphs stay crisp on a Retina/4K target instead of being magnified 1×.
    private var currentPixelScale: Double = 1

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float2 center; float2 halfExtent; float2 uvScale; float2 aspectScale; float2 rotA; float2 rotB; };
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut lumora_scene_vertex(uint vid [[vertex_id]], constant Quad &quad [[buffer(0)]]) {
        float2 corner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]    = { float2(0, 1),  float2(1, 1),  float2(0, 0),  float2(1, 0) };
        VOut out;
        // Roll the corner offset about the layer centre (aspect-corrected on the CPU), then aspectScale
        // (≥1 on one axis) scales the whole composition to cover a differently-shaped target, pushing the
        // overflow past the clip bounds so it's cropped rather than stretching the content.
        float2 offset = corner[vid] * quad.halfExtent;
        offset = float2(dot(quad.rotA, offset), dot(quad.rotB, offset));
        out.position = float4((quad.center + offset) * quad.aspectScale, 0, 1);
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
    // A puppet layer draws a real mesh (assembled from its sprite atlas) instead of a quad: each vertex is a
    // model-space position + atlas UV, placed into the scene by the object's origin/scale and the ortho.
    struct PuppetU { float2 origin; float2 scale; float2 ortho; float2 aspectScale; };
    struct PuppetVtx { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    vertex VOut lumora_puppet_vertex(PuppetVtx in [[stage_in]], constant PuppetU &u [[buffer(1)]]) {
        float2 world = u.origin + in.pos * u.scale;
        float2 ndc = (world / u.ortho) * 2.0 - 1.0;
        VOut out;
        out.position = float4(ndc * u.aspectScale, 0, 1);
        out.uv = in.uv;
        return out;
    }
    struct PInst { float2 center; float2 halfExtent; float4 color; float2 rotor; };
    struct POut { float4 position [[position]]; float2 uv; float4 color; };
    vertex POut lumora_particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                       constant PInst *insts [[buffer(0)]],
                                       constant float2 &aspectScale [[buffer(1)]]) {
        float2 corner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]    = { float2(0, 1),  float2(1, 1),  float2(0, 0),  float2(1, 0) };
        PInst p = insts[iid];
        POut out;
        // Rotate the unit corner by the sprite's rotor (cos, sin) before scaling: halfExtent maps the unit
        // square to equal pixels on both axes, so this spins the sprite in the screen plane.
        float2 c = corner[vid];
        float2 r = float2(c.x * p.rotor.x - c.y * p.rotor.y, c.x * p.rotor.y + c.y * p.rotor.x);
        out.position = float4((p.center + r * p.halfExtent) * aspectScale, 0, 1);
        out.uv = uvs[vid];
        out.color = p.color;
        return out;
    }
    fragment float4 lumora_particle_fragment(POut in [[stage_in]],
                                             texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]]) {
        float4 t = tex.sample(samp, in.uv);
        return float4(t.rgb * in.color.rgb, t.a * in.color.a);
    }
    // A refractive droplet (rain on glass): inside the sprite's shape (albedo alpha), show the composited
    // background sampled at a screen position displaced by the droplet's surface normal — so the scene
    // bends through the water — plus a faint specular highlight. Outside the shape it's transparent.
    fragment float4 lumora_particle_refract(POut in [[stage_in]],
                                            texture2d<float> albedo [[texture(0)]], sampler samp [[sampler(0)]],
                                            texture2d<float> normalTex [[texture(1)]],
                                            texture2d<float> background [[texture(2)]],
                                            constant float2 &viewport [[buffer(0)]]) {
        float4 a = albedo.sample(samp, in.uv);
        float coverage = a.a * in.color.a;
        if (coverage < 0.02) { discard_fragment(); }
        float2 n = normalTex.sample(samp, in.uv).xy * 2.0 - 1.0;     // tangent-space normal xy
        float2 screenUV = in.position.xy / viewport;                 // this fragment's spot on screen
        float2 refracted = clamp(screenUV + n * 0.035, 0.0, 1.0);    // bend the view by the normal
        float3 bg = background.sample(samp, refracted).rgb;
        float3 col = bg + a.rgb * (0.12 * a.a);                      // subtle bright rim/highlight
        return float4(col, coverage);
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
                                                               fragment: particleFragment, additive: false),
                  let particleRefractFragment = library.makeFunction(name: "lumora_particle_refract"),
                  let particleRefractPipe = Self.makeParticlePipeline(device: device, vertex: particleVertex,
                                                                      fragment: particleRefractFragment, additive: false),
                  let puppetVertex = library.makeFunction(name: "lumora_puppet_vertex"),
                  let puppet = Self.makePuppetPipeline(device: device, vertex: puppetVertex, fragment: fragmentFunction) else { return nil }
            self.pipelineOver = over
            self.pipelineAdditive = additive
            self.particleAdditive = particleAdd
            self.particleAlpha = particleOver
            self.particleRefract = particleRefractPipe
            self.pipelinePuppet = puppet
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
    /// particle sprites (halo, glow, drop). WE's atmospheric glows are faint: a scene can keep a hundred of
    /// them alive and additively overlapping, so a fully-opaque centre would stack into a blown-out wash.
    /// A gaussian profile with a low peak reads as a soft glow on its own and accumulates gently in a crowd.
    private static func haloPixels(side: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let center = Double(side - 1) / 2
        for y in 0 ..< side {
            for x in 0 ..< side {
                let dx = (Double(x) - center) / center, dy = (Double(y) - center) / center
                let glow = exp(-(dx * dx + dy * dy) * 4.0)   // gaussian: 1 at centre, soft tail to the edge
                let i = (y * side + x) * 4
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255
                pixels[i + 3] = UInt8(max(0, min(255, glow * 90)))   // low peak so additive overlap stays soft
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
        color.sourceAlphaBlendFactor = .one   // straight-alpha: don't square the source alpha
        color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The puppet-mesh pipeline: a per-vertex (position, uv) stream (stride 16, buffer 0) drawn alpha-over,
    /// atlas-textured. The placement uniform binds at vertex buffer 1.
    private static func makePuppetPipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction) -> MTLRenderPipelineState? {
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2; vertexDescriptor.attributes[0].offset = 0;  vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2; vertexDescriptor.attributes[1].offset = 8;  vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 16
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .rgba8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
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
        color.sourceAlphaBlendFactor = .one   // straight-alpha: don't square the source alpha
        color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The number of particle-instance slots to allocate ≈ spawn rate × longest lifetime, capped to the
    /// system's maxcount. `rate` and `lifetime` come from untrusted scene JSON with no upper bound, so the
    /// product is clamped into [1, maxCount] in Double space — and a non-finite product (an overflow to
    /// infinity from a crafted rate × lifetime) is treated as the cap — before the `Int(_:)` conversion,
    /// which would otherwise trap on a value past Int.max or on infinity and crash the scene load.
    public static func particleInstanceCount(rate: Double, lifetimeUpper: Double, maxCount: Int) -> Int {
        let cap = max(1, maxCount)
        let steady = (rate * lifetimeUpper).rounded(.up)
        guard steady.isFinite else { return cap }
        return min(cap, max(1, Int(min(steady, Double(cap)))))
    }

    /// Decode and upload every visible layer's texture once into a `PreparedScene`, so the render loop
    /// can redraw every frame without touching the disk. Placement is resolution-independent (NDC).
    public func prepare(_ document: RenderableScene, package: ScenePackage) -> PreparedScene {
        // Aux textures (masks, normal maps, ramps) are cached by name only, so a renderer reused across scenes
        // could hand a later package a same-named texture from an earlier one. Clear the cache per scene — it
        // is rebuilt from `package` below, and prepare() runs once per load, not per frame.
        auxCache.removeAll(keepingCapacity: true)
        let orthoW = Double(document.orthoWidth > 0 ? document.orthoWidth : 1920)
        let orthoH = Double(document.orthoHeight > 0 ? document.orthoHeight : 1080)
        var prepared: [PreparedLayer] = []
        // Solid fills are kept only while still behind every textured layer (a background) — a solid
        // layer above the artwork is usually an animated flash that a still frame would over-paint.
        var drewTexturedLayer = false
        // Video-texture frames are held for the scene's lifetime; cap their total so a scene with
        // several video layers can't grow GPU memory without bound. Beyond it, layers stay on their
        // (already-uploaded) first frame.
        let videoFrameCount = 24
        let videoVRAMBudget = 384 * 1024 * 1024
        var videoVRAMUsed = 0
        var puppetLayerCount = 0, puppetReadyCount = 0   // a scene is puppet-ready only if every puppet assembles
        for layer in document.layers where layer.visible {
            // A text layer (clock, label) draws rendered glyphs: build its font + (optional) script runtime;
            // the quad's size is derived at render time from the rasterised string. No packed texture.
            if layer.isTextLayer {
                let fontData = layer.fontPath.flatMap { package.entry(named: $0)?.data }
                let font = PreparedTextLayer.makeFont(data: fontData, pointSize: layer.pointSize)
                let runtime = layer.textScript.flatMap { SceneScriptRuntime(script: $0) }
                let prepText = PreparedTextLayer(runtime: runtime, staticText: layer.textValue ?? "",
                                                 font: font, color: SIMD3(Float(layer.color.x), Float(layer.color.y), Float(layer.color.z)),
                                                 pointSize: layer.pointSize, device: device, horizontalAlign: layer.horizontalAlign)
                let center = SIMD2(Float(layer.origin.x / orthoW * 2 - 1), Float(layer.origin.y / orthoH * 2 - 1))
                prepared.append(PreparedLayer(
                    texture: whiteTexture, center: center, halfExtent: .zero, uvScale: SIMD2(1, 1),
                    alpha: Float(layer.alpha), alphaAnimation: layer.alphaAnimation, tint: SIMD3(1, 1, 1),
                    isAdditive: false, parallaxDepth: SIMD2(Float(layer.parallaxDepth.x), Float(layer.parallaxDepth.y)),
                    originAnimation: layer.originAnimation, originScale: SIMD2(Float(2 / orthoW), Float(2 / orthoH)),
                    rotA: SIMD2(1, 0), rotB: SIMD2(0, 1), effects: [], videoTrack: nil, puppet: nil, text: prepText,
                    scriptGroup: nil))
                continue
            }
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
            let halfExtent = SIMD2(Float(sizeW * layer.scale.x / orthoW), Float(sizeH * layer.scale.y / orthoH))
            // `origin` is the layer's centre by default, but `alignment` can anchor it to an edge or corner
            // (a "bottomleft"-aligned full-screen image puts its bottom-left at origin and extends up-right).
            // Shift the quad centre by a half-extent toward the anchored side so the anchor lands on origin.
            var center = SIMD2(Float(layer.origin.x / orthoW * 2 - 1), Float(layer.origin.y / orthoH * 2 - 1))
            if let a = layer.alignment, a != "center" {
                if a.contains("left")  { center.x += halfExtent.x }
                if a.contains("right") { center.x -= halfExtent.x }
                if a.contains("bottom") { center.y += halfExtent.y }   // scene/NDC y is up
                if a.contains("top")    { center.y -= halfExtent.y }
            }
            let tint = SIMD3(Float(layer.color.x), Float(layer.color.y), Float(layer.color.z))

            // The layer's roll (angles.z, radians) about its centre. The corner offset is in NDC, which is
            // anisotropic on a non-square target, so the rotation is conjugated by the ortho aspect (a) to
            // rotate in square pixel space: M = diag(1,a)·R·diag(1,1/a) → rows (cos, -sin/a), (sin·a, cos).
            let roll = Float(layer.angles.z)
            let aspect = Float(orthoW / orthoH)
            let cosR = cos(roll), sinR = sin(roll)
            let rotA = SIMD2<Float>(cosR, -sinR / aspect)
            let rotB = SIMD2<Float>(sinR * aspect, cosR)

            // A video-backed texture animates. Decoding its frames is slow (seeks + per-frame decode),
            // so it happens off the render thread: the static `texture` above (the first frame) shows
            // immediately, and the looping frames swap in once the background decode delivers them.
            var videoTrack: VideoFrameTrack?
            if !isSolidFill, let path = layer.texturePath, let entry = package.entry(named: path),
               SceneTexture.isVideoTexture(entry.data) {
                // Frames are capped to a 1280 bounding box (aspect-preserving) when decoded; estimate
                // that size to charge the VRAM budget before committing to load this one.
                let scale = min(1.0, 1280.0 / max(textureW, textureH, 1))
                let estBytes = Int(textureW * scale) * Int(textureH * scale) * 4 * videoFrameCount
                if videoVRAMUsed + estBytes <= videoVRAMBudget {
                    videoVRAMUsed += estBytes
                    let track = VideoFrameTrack()
                    let data = entry.data
                    DispatchQueue.global(qos: .utility).async {
                        if let video = SceneTexture.videoFrames(data, count: videoFrameCount) {
                            track.deliver(video.frames, duration: video.duration)
                        }
                    }
                    videoTrack = track
                } else {
                    NSLog("Lumora: video texture kept static — scene VRAM budget reached")
                }
            }
            // A puppet layer draws its assembled skeletal mesh (sprite-atlas parts) instead of a quad. The
            // model-space positions are placed by the object's origin/scale; the mesh UVs are scaled by the
            // texture's content ratio so a padded (POT) atlas samples the right region, like the quad path.
            // The mesh is only built when the skeleton assembled into a verified-good figure (`mesh.assembled`,
            // which the parser gates on finite matrices + a non-torn result); a layer that doesn't decode
            // leaves `puppet` nil, marking the scene not puppet-ready so the caller keeps the static preview.
            var puppet: PreparedPuppet?
            if let puppetPath = layer.puppetPath {
                puppetLayerCount += 1
                if let entry = package.entry(named: puppetPath),
                   let mesh = PuppetModel.parseMesh(entry.data), mesh.indices.count >= 3,
                   mesh.assembled || ProcessInfo.processInfo.environment["LUMORA_PUPPET_RAW"] != nil {
                    var verts = [Float](); verts.reserveCapacity(mesh.positions.count * 4)
                    for i in 0 ..< mesh.positions.count {
                        let p = mesh.positions[i], uv = mesh.uvs[i]
                        verts.append(contentsOf: [p.x, p.y, uv.x * uvScale.x, uv.y * uvScale.y])
                    }
                    if let vbuf = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared),
                       let ibuf = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 4, options: .storageModeShared) {
                        puppet = PreparedPuppet(vertexBuffer: vbuf, indexBuffer: ibuf, indexCount: mesh.indices.count,
                                                origin: SIMD2(Float(layer.origin.x), Float(layer.origin.y)),
                                                scale: SIMD2(Float(layer.scale.x), Float(layer.scale.y)),
                                                ortho: SIMD2(Float(orthoW), Float(orthoH)))
                    }
                }
                if puppet != nil { puppetReadyCount += 1 }
            }
            // A layer with a scene-graph SceneScript (an audio visualiser) clones itself into bars: build the
            // runtime, seeding `thisLayer` with this layer's placement, and keep it only if its init() actually
            // produced more than the base layer (otherwise it's an ordinary layer and draws as one quad). The
            // bar half-extent is captured at the script's scale = 1; the per-frame scale comes from the script.
            var scriptGroup: PreparedScriptGroup?
            if let driver = layer.driverScript,
               let runtime = SceneScriptRuntime(
                   script: driver,
                   baseOrigin: SIMD3(Float(layer.origin.x), Float(layer.origin.y), Float(layer.origin.z)),
                   baseColor: SIMD3(Float(layer.color.x), Float(layer.color.y), Float(layer.color.z)),
                   baseAlpha: Float(layer.alpha)),
               runtime.drivesLayers, runtime.scriptedLayers().count > 1 {
                let baseHalf = SIMD2(Float(sizeW / orthoW), Float(sizeH / orthoH))
                scriptGroup = PreparedScriptGroup(
                    runtime: runtime, texture: texture, baseHalfExtent: baseHalf, uvScale: uvScale,
                    isAdditive: layer.blending == "additive" || layer.blending == "add",
                    orthoW: orthoW, orthoH: orthoH)
            }
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
                rotA: rotA,
                rotB: rotB,
                effects: puppet != nil ? [] : prepareEffects(layer.effects, package: package, base: texture,
                                        center: center, halfExtent: halfExtent, uvScale: uvScale, tint: tint),
                videoTrack: videoTrack,
                puppet: puppet,
                text: nil,
                scriptGroup: scriptGroup))
        }

        var preparedParticles: [PreparedParticles] = []
        for system in document.particleSystems {
            guard let sprite = particleSprite(system, package: package) else { continue }
            // Steady-state live count ≈ spawn rate × longest lifetime, capped to the system's maxcount.
            let count = SceneRenderer.particleInstanceCount(rate: system.rate, lifetimeUpper: system.lifetime.upperBound,
                                                            maxCount: system.maxCount)
            // One instance buffer per system, allocated once and refilled each frame, instead of a fresh
            // allocation every frame for the life of the wallpaper.
            guard let instanceBuffer = device.makeBuffer(length: MemoryLayout<ParticleInstance>.stride * count,
                                                         options: .storageModeShared) else { continue }
            preparedParticles.append(PreparedParticles(system: system, texture: sprite.texture,
                                                       normalTexture: sprite.normal, count: count,
                                                       isAdditive: sprite.isAdditive, isRefractive: sprite.isRefractive,
                                                       instanceBuffer: instanceBuffer))
        }
        return PreparedScene(layers: prepared, clearColor: document.clearColor,
                             particles: preparedParticles, orthoWidth: orthoW, orthoHeight: orthoH,
                             puppetReady: puppetLayerCount > 0 && puppetReadyCount == puppetLayerCount)
    }

    /// The sprite a particle system draws — its material's first bound texture and blend mode
    /// (additive for glowy sparks/embers, alpha-over for solid sprites like petals/butterflies). Returns
    /// nil if the sprite can't be resolved, so the system is skipped rather than drawn as white squares.
    private func particleSprite(_ system: ParticleSystem, package: ScenePackage)
        -> (texture: MTLTexture, normal: MTLTexture?, isAdditive: Bool, isRefractive: Bool)? {
        guard let materialPath = system.materialPath, let entry = package.entry(named: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: entry.data)) as? [String: Any],
              let pass = (material["passes"] as? [[String: Any]])?.first
        else { return nil }
        let names = (pass["textures"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let first = names.first, let texture = spriteTexture(named: first, package: package) else { return nil }
        // Rain-on-glass droplets (REFRACT combo + a normal map) distort the scene behind each sprite. We
        // refract by sampling the composited background displaced by the droplet's normal map (see the
        // refractive render branch). Needs the second texture; without it we can't refract faithfully, so
        // skip (a plain albedo blob would just obscure the scene — worse than the effect's absence).
        if (pass["combos"] as? [String: Any])?["REFRACT"] as? Int == 1 {
            guard names.count >= 2, let normal = spriteTexture(named: names[1], package: package) else { return nil }
            return (texture, normal, false, true)
        }
        let blending = (pass["blending"] as? String) ?? "normal"
        return (texture, nil, blending == "additive" || blending == "add", false)
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
        // WE's unshipped built-in sprites: blob-like glows (halo, fog, dot, flare, …) approximate well as a
        // soft radial glow tinted by the particle's colour. Two families we DON'T approximate, because a
        // wrong stand-in is worse than the effect's absence: elongated shapes (shafts, beams, lightning,
        // debris), and FIRE/ember/spark — WE ships a flame sprite that scenes recolour per-emitter (a
        // "Wildfire" can be orange in one scene, blue energy in another), so a fixed white/orange blob is as
        // often wrong as right and just obscures the scene. Skip both rather than draw a wrong blob.
        if name.hasPrefix("particle/") {
            let skip = ["shaft", "beam", "lightning", "bolt", "ray", "trail", "streak", "debris",
                        "fire", "flame", "ember", "spark", "lava", "magma", "wildfire"]
            let blob = ["halo", "glow", "drop", "dot", "fog", "flare", "smoke", "star", "bokeh", "circle"]
            if blob.contains(where: name.contains), !skip.contains(where: name.contains) {
                return haloTexture
            }
        }
        return nil
    }

    /// Built-in uniform values the renderer supplies to every effect stage: the animation clock, an
    /// identity model-view-projection (the effect quad already spans NDC), and each bound sampler's
    /// resolution as (w, h, w, h) — the render targets are exact-size, so the padded-atlas ratio the
    /// shaders derive from `.zw / .xy` is 1, and a downsample/blur sees its INPUT's real size.
    private static func effectOverrides(time: Float, resolutions: [Int: SIMD2<Int>]) -> [String: [Float]] {
        var overrides: [String: [Float]] = [
            "g_Time": [time],
            "g_ModelViewProjectionMatrix": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
        ]
        for (number, size) in resolutions {
            let w = Float(size.x), h = Float(size.y)
            overrides["g_Texture\(number)Resolution"] = [w, h, w, h]
        }
        return overrides
    }

    /// The audio spectrum overrides for a frame, keyed by the WE uniform names an audio-reactive shader
    /// declares (`uniform float g_AudioSpectrum16Left[16];` etc.). The packer lays each out as a float[N].
    private static func audioOverrides(_ audio: AudioSpectrumProvider) -> [String: [Float]] {
        [
            "g_AudioSpectrum16Left": audio.spectrum(bands: 16, channel: .left),
            "g_AudioSpectrum16Right": audio.spectrum(bands: 16, channel: .right),
            "g_AudioSpectrum32Left": audio.spectrum(bands: 32, channel: .left),
            "g_AudioSpectrum32Right": audio.spectrum(bands: 32, channel: .right),
            "g_AudioSpectrum64Left": audio.spectrum(bands: 64, channel: .left),
            "g_AudioSpectrum64Right": audio.spectrum(bands: 64, channel: .right),
        ]
    }

    /// Run one prepared effect over `input` at `time`, executing its pass graph: allocate the named
    /// intermediate buffers at their scaled size, run each pass (binding `previous`/buffers/aux per slot,
    /// packing the stage uniforms fresh so it animates) into its target, and return the final full-size
    /// output. A separable blur is x→buffer→y→output; a downsample chain ping-pongs the quarter buffers.
    /// Borrow an effect render target from the per-frame pool (a reused texture for the requested size/format,
    /// or a freshly made one), tracking it so `recycleEffectTextures()` can return it after compositing.
    private func borrowEffectTarget(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let key = (width &* 73_856_093) ^ (height &* 19_349_663) ^ (Int(pixelFormat.rawValue) &* 83_492_791)
        let texture: MTLTexture
        if var free = effectTexturePool[key], let reused = free.popLast() {
            effectTexturePool[key] = free
            texture = reused
        } else if let made = effectRenderer?.makeTarget(width: width, height: height, pixelFormat: pixelFormat) {
            texture = made
        } else {
            return nil
        }
        effectTexturesInUse.append(texture)
        return texture
    }

    /// Return every target borrowed this frame to the pool. Call once the frame is fully composited and read
    /// back (rendering is synchronous, so the GPU is done with them).
    private func recycleEffectTextures() {
        for texture in effectTexturesInUse {
            let key = (texture.width &* 73_856_093) ^ (texture.height &* 19_349_663) ^ (Int(texture.pixelFormat.rawValue) &* 83_492_791)
            effectTexturePool[key, default: []].append(texture)
        }
        effectTexturesInUse.removeAll(keepingCapacity: true)
    }

    private func applyEffect(_ effect: PreparedEffect, to input: MTLTexture, time: Float,
                             width: Int, height: Int,
                             allocTarget: (Int, Int, MTLPixelFormat) -> MTLTexture?) -> MTLTexture? {
        guard let effectRenderer else { return nil }
        var buffers: [String: MTLTexture] = [:]
        for fbo in effect.fbos {
            let scale = max(1, fbo.scale)
            guard let target = allocTarget(width / scale, height / scale,
                                           EffectRenderer.pixelFormat(for: fbo.format)) else { return nil }
            buffers[fbo.name] = target
        }
        var result = input
        for pass in effect.passes {
            var inputs: [(index: Int, texture: MTLTexture)] = []
            var resolutions: [Int: SIMD2<Int>] = [:]
            for sampler in pass.samplers {
                let texture: MTLTexture
                switch sampler.input {
                case .previous: texture = input
                case .buffer(let name): texture = buffers[name] ?? whiteTexture
                case .aux(let aux): texture = aux
                }
                inputs.append((index: sampler.slot, texture: texture))
                resolutions[sampler.number] = SIMD2(texture.width, texture.height)
            }
            let overrides = Self.effectOverrides(time: time, resolutions: resolutions)
                .merging(currentAudioOverrides) { _, audio in audio }
            let fragmentUniforms = UniformPacker.pack(pass.scalars, values: pass.constants, overrides: overrides)
            let vertexUniforms = pass.hasVertex ? UniformPacker.pack(pass.vertexScalars, values: pass.constants, overrides: overrides) : Data()

            let output: MTLTexture
            if let target = pass.target, let buffer = buffers[target] { output = buffer }
            else if let made = allocTarget(width, height, .rgba8Unorm) { output = made }
            else { return nil }

            guard effectRenderer.renderPass(pipeline: pass.pipeline, hasVertex: pass.hasVertex, inputs: inputs,
                                            vertexUniforms: vertexUniforms.isEmpty ? nil : vertexUniforms,
                                            fragmentUniforms: fragmentUniforms.isEmpty ? nil : fragmentUniforms,
                                            into: output) else { return nil }
            if pass.target == nil { result = output }   // a full-size output pass advances the effect result
        }
        return result
    }

    /// Compile a layer's effects and keep only the ones that actually contribute. Each pass is paired with
    /// its own transpiled vertex shader where it ships one (so rotation/shake/scroll and the blur-tap
    /// offsets link and run), falling back to a fixed full-screen vertex for fragment-only passes; an effect
    /// whose graph can't be fully built is dropped. Then the chain is dry-run at low resolution and any
    /// effect that blanks the layer is skipped, so it degrades gracefully instead of going transparent.
    private func prepareEffects(_ effects: [LayerEffect], package: ScenePackage, base: MTLTexture,
                                center: SIMD2<Float>, halfExtent: SIMD2<Float>, uvScale: SIMD2<Float>,
                                tint: SIMD3<Float>) -> [PreparedEffect] {
        guard let effectRenderer, !effects.isEmpty else { return [] }
        var compiled: [PreparedEffect] = []
        for effect in effects {
            var preparedPasses: [PreparedPass] = []
            var graphOK = true
            for pass in effect.passes {
                guard let fragmentEntry = package.entry(named: pass.fragmentShaderPath) else { graphOK = false; break }
                let fragmentSource = String(decoding: fragmentEntry.data, as: UTF8.self)
                let vertexSource = package.entry(named: pass.vertexShaderPath).map { String(decoding: $0.data, as: UTF8.self) }
                // The pass renders into its target FBO (so the pipeline's colour format must match it), or
                // the full-size rgba8 effect output for the final, target-less pass.
                let outputFormat: MTLPixelFormat = pass.target
                    .flatMap { name in effect.fbos.first { $0.name == name } }
                    .map { EffectRenderer.pixelFormat(for: $0.format) } ?? .rgba8Unorm

                // Both stages of a pass — and the uniform parse — must see the SAME combos, or the vertex and
                // fragment disagree on which `#if`-gated varyings exist and the pipeline fails to link. A combo
                // is often declared (with its default) in only ONE stage, so use the union of both shaders'
                // defaults, with the effect instance's explicit combos winning.
                var combos = ShaderPreprocessor.comboDefaults(fragmentSource)
                if let vertexSource { combos.merge(ShaderPreprocessor.comboDefaults(vertexSource)) { a, _ in a } }
                combos.merge(pass.combos) { _, b in b }

                var pipeline: MTLRenderPipelineState?
                var hasVertex = false
                var vertexScalars: [ShaderUniform] = []
                if let vertexSource {
                    if let made = effectRenderer.makeVertexPipeline(vertexShader: vertexSource, fragmentShader: fragmentSource,
                                                                    combos: combos, pixelFormat: outputFormat) {
                        pipeline = made
                        hasVertex = true
                        let vertexResolved = ShaderPreprocessor.resolve(vertexSource, combos: combos)
                        vertexScalars = ShaderUniforms.parse(vertexResolved).filter { !$0.type.hasPrefix("sampler") }
                    }
                }
                if pipeline == nil { pipeline = effectRenderer.makePipeline(fragmentShader: fragmentSource, combos: combos, pixelFormat: outputFormat) }
                guard let pipeline else { graphOK = false; break }

                let resolved = ShaderPreprocessor.resolve(fragmentSource, combos: combos)
                let uniforms = ShaderUniforms.parse(resolved)
                // Each declared sampler binds at its enumeration slot; its WE g_Texture<number> decides
                // whether it reads `previous` (the effect input, the implicit default for number 0), a named
                // buffer, or a resolved aux texture (noise/normal/mask) for the rest.
                let samplerUniforms = uniforms.filter { $0.type.hasPrefix("sampler") }
                var samplers: [(slot: Int, number: Int, input: EffectInput)] = []
                for (slot, sampler) in samplerUniforms.enumerated() {
                    let number = Int(sampler.name.dropFirst("g_Texture".count)) ?? slot
                    let resolvedInput: EffectInput
                    if let bind = pass.binds.first(where: { $0.index == number }) {
                        resolvedInput = bind.name == "previous" ? .previous : .buffer(bind.name)
                    } else if number == 0 {
                        resolvedInput = .previous
                    } else {
                        let bound = (number >= 0 && number < pass.textures.count) ? pass.textures[number] : nil
                        resolvedInput = .aux(resolveAuxTexture(bound ?? sampler.defaultValue, package: package))
                    }
                    samplers.append((slot: slot, number: number, input: resolvedInput))
                }
                preparedPasses.append(PreparedPass(
                    pipeline: pipeline, hasVertex: hasVertex,
                    scalars: uniforms.filter { !$0.type.hasPrefix("sampler") },
                    vertexScalars: vertexScalars, constants: effect.constants,
                    target: pass.target, samplers: samplers))
            }
            guard graphOK, !preparedPasses.isEmpty else { continue }
            compiled.append(PreparedEffect(passes: preparedPasses, fbos: effect.fbos))
        }
        guard !compiled.isEmpty else { return [] }

        // Dry-run the chain on a small copy of the layer and keep only passes that preserve the layer's
        // coverage at every sampled time. An effect this renderer can't yet do (multi-pass blur, mesh
        // displacement past the grid) punches the layer out to the clear colour — sometimes only at certain
        // phases of its animation — so a pass is dropped unless it stays stable across the whole sample set.
        let probeW = 320, probeH = 180
        let times: [Float] = [0, 1.3, 2.6, 4.1, 5.7]
        guard var probe = renderQuadToTexture(base, center: center, halfExtent: halfExtent, uvScale: uvScale,
                                               tint: tint, width: probeW, height: probeH) else { return compiled }
        let probeRGBA = effectRenderer.readback(probe)
        var probeCoverage = coverage(probeRGBA)
        var probeDetail = detail(probeRGBA)
        var kept: [PreparedEffect] = []
        // A real WE glow/bloom/godray lifts the layer's mean luma only modestly (measured ≤ ~9 across the
        // library). An effect that screen-blends against a white placeholder aux texture we don't have washes
        // it toward white — sometimes in one +22…+255 jump, sometimes as a slow +5-per-pass creep that no
        // single-step check catches. Cap the CUMULATIVE rise above the un-effected layer so the wallpaper
        // keeps the look it has in Wallpaper Engine either way.
        let baseLuma = lumaStats(probeRGBA).mean
        // Measured across the library: genuine glow/bloom/godray chains raise the layer's mean luma by at
        // most ~8; the white-placeholder washes land at +18 and up, with nothing legitimate in between.
        let washThreshold = 12.0
        for effect in compiled {
            var stableOutput: MTLTexture?
            var stableRGBA: Data?
            var stable = true
            for time in times {
                // The one-time dry run allocates targets directly (not from the per-frame render pool).
                guard let output = applyEffect(effect, to: probe, time: time, width: probeW, height: probeH,
                    allocTarget: { w, h, fmt in effectRenderer.makeTarget(width: w, height: h, pixelFormat: fmt) }) else { stable = false; break }
                let rgba = effectRenderer.readback(output)
                // Drop a pass that erases the layer's coverage, flattens it to near-uniform colour, OR washes
                // it toward white (a screen blend against the missing aux placeholder) — all three otherwise
                // pass a coverage-only check while looking nothing like the wallpaper does in WE.
                guard coverage(rgba) >= probeCoverage / 2, detail(rgba) >= probeDetail / 5,
                      lumaStats(rgba).mean - baseLuma <= washThreshold else { stable = false; break }
                if time == 0 { stableOutput = output; stableRGBA = rgba }
            }
            guard stable, let stableOutput, let stableRGBA else { continue }   // unstable / erasing / flattening / washing
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

    /// Mean luma (0–255) and the fraction of near-black pixels (luma < 40) in an RGBA readback. A bloom or
    /// glow that washes the layer out raises the mean and collapses the dark fraction (lifted blacks).
    private func lumaStats(_ rgba: Data) -> (mean: Double, darkFraction: Double) {
        var sum = 0.0, dark = 0.0, n = 0.0
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            let l = 0.299 * Double(rgba[i]) + 0.587 * Double(rgba[i + 1]) + 0.114 * Double(rgba[i + 2])
            sum += l; if l < 40 { dark += 1 }; n += 1
        }
        guard n > 0 else { return (0, 0) }
        return (sum / n, dark / n)
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
                                   orthoW: Double, orthoH: Double) -> Int {
        let s = prepared.system
        // Write straight into the system's reused (shared-storage) instance buffer, which is sized for
        // `count`, and return how many live sprites were written — no per-frame staging array is allocated
        // or copied. `n` never exceeds `count` (one write per slot at most), so the buffer can't overflow.
        let dst = prepared.instanceBuffer.contents().assumingMemoryBound(to: ParticleInstance.self)
        var n = 0
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
            // turbulentvelocityrandom: a noise-seeded kick on the spawn velocity (a per-particle constant).
            if s.turbVelScale != 0 {
                let spd = s.turbVelSpeed.upperBound > 0 ? lerp(s.turbVelSpeed.lowerBound, s.turbVelSpeed.upperBound, rand(seed, 30)) : 100
                velX += (rand(seed, 31) * 2 - 1 + s.turbVelOffset) * s.turbVelScale * spd
                velY += (rand(seed, 32) * 2 - 1 + s.turbVelOffset) * s.turbVelScale * spd
            }
            let baseSize = lerp(s.size.lowerBound, s.size.upperBound, rand(seed, 5))
            let alpha0 = lerp(s.alpha.lowerBound, s.alpha.upperBound, rand(seed, 6))
            var color = SIMD3<Float>(Float(lerp(s.color.min.x, s.color.max.x, rand(seed, 7)) / 255),
                                     Float(lerp(s.color.min.y, s.color.max.y, rand(seed, 8)) / 255),
                                     Float(lerp(s.color.min.z, s.color.max.z, rand(seed, 9)) / 255))

            // Drag (movement operator) damps the initial velocity exponentially: the distance travelled from
            // velocity over `age` is ∫v₀e^(-drag·t)dt = v₀·(1-e^(-drag·age))/drag, falling back to v₀·age when
            // there's no drag (the limit as drag→0), so an undragged system is byte-identical.
            let travel = s.drag > 0 ? (1 - exp(-s.drag * age)) / s.drag : age
            var posX = spawnX + velX * travel + 0.5 * s.gravity.x * age * age
            var posY = spawnY + velY * travel + 0.5 * s.gravity.y * age * age
            let lifeFrac = age / life
            // Alpha over life. A universal birth/death envelope softens every sprite at spawn and death — this
            // is what keeps dense additive crowds from saturating to a flat wash. A system's explicit alphafade
            // (fade in over [0,fadeIn], out over [fadeOut,1]) multiplies ON TOP of that envelope; a system
            // without one gets just the envelope (unchanged). Note an alphafade of (0,1) means "no fade" — the
            // envelope must still apply, or the crowd washes out (regression guard).
            let env = Float(smoothstep(0, 0.15, lifeFrac) * (1 - smoothstep(0.85, 1, lifeFrac)))
            var fade: Float = env
            if s.hasAlphaFade {
                var a = 1.0
                if s.fadeInTime > 0, lifeFrac < s.fadeInTime { a = lifeFrac / s.fadeInTime }
                if s.fadeOutTime < 1, lifeFrac > s.fadeOutTime { a = min(a, (1 - lifeFrac) / max(1e-4, 1 - s.fadeOutTime)) }
                fade = Float(max(0, a)) * env
            }
            // Size over life (sizechange): ramp the multiplier between its start/end across the configured
            // life-fraction span, holding flat outside it. Default ramp (1→1) leaves the size unchanged.
            let sizeT = s.sizeEndTime > s.sizeStartTime
                ? max(0, min(1, (lifeFrac - s.sizeStartTime) / (s.sizeEndTime - s.sizeStartTime))) : 1
            var size = baseSize * lerp(s.sizeStart, s.sizeEnd, sizeT)
            // Oscillators (oscillatealpha/size/position): a per-particle sine at frequency f, phase ph. Alpha
            // and size map the 0…1 envelope into their multiplier range; position displaces along its mask by
            // amp·sin. Each picks f/phase/amp from its parsed ranges via its own rand channels (20–26).
            func oscPhase(_ o: ParticleSystem.Oscillator, _ fc: UInt32, _ pc: UInt32) -> Float {
                let f = lerp(o.freq.lowerBound, o.freq.upperBound, rand(seed, fc))
                let ph = 2 * .pi * lerp(o.phase.lowerBound, o.phase.upperBound, rand(seed, pc))
                return Float(2 * .pi * f * age + ph)
            }
            if let o = s.oscillateAlpha {
                let env = 0.5 + 0.5 * Double(sin(oscPhase(o, 20, 21)))
                fade *= Float(max(0, min(4, lerp(o.scale.lowerBound, o.scale.upperBound, env))))
            }
            if let o = s.oscillateSize {
                let env = 0.5 + 0.5 * Double(sin(oscPhase(o, 22, 23)))
                size *= max(0, min(4, lerp(o.scale.lowerBound, o.scale.upperBound, env)))
            }
            if let o = s.oscillatePosition {
                let amp = max(-5000, min(5000, lerp(o.scale.lowerBound, o.scale.upperBound, rand(seed, 26))))
                let disp = amp * Double(sin(oscPhase(o, 24, 25)))
                posX += o.mask.x * disp
                posY += o.mask.y * disp
            }
            // colorchange: animate the tint from start→end (0…1) across [startTime, endTime] of life. Multiply
            // (rather than replace) so it composes with any colorrandom base; a white base makes it a replace.
            if s.hasColorChange {
                let ct = s.colorChangeEndTime > s.colorChangeStartTime
                    ? max(0, min(1, (lifeFrac - s.colorChangeStartTime) / (s.colorChangeEndTime - s.colorChangeStartTime))) : 1
                color = SIMD3(color.x * Float(lerp(s.colorChangeStart.x, s.colorChangeEnd.x, ct)),
                              color.y * Float(lerp(s.colorChangeStart.y, s.colorChangeEnd.y, ct)),
                              color.z * Float(lerp(s.colorChangeStart.z, s.colorChangeEnd.z, ct)))
            }
            // Screen-plane spin: a random starting orientation plus a constant angular velocity over the
            // particle's age (radians). Clamp the rate defensively so no malformed value can strobe.
            let angle0 = lerp(s.initialRotation.lowerBound, s.initialRotation.upperBound, rand(seed, 13))
            let spin = max(-12, min(12, lerp(s.angularVelocity.lowerBound, s.angularVelocity.upperBound, rand(seed, 14))))
            // angularmovement adds a constant angular acceleration: θ = θ₀ + ω·age + ½·force·age².
            let angle = Float(angle0 + spin * age + 0.5 * s.angularForce * age * age)
            dst[n] = ParticleInstance(
                center: SIMD2(Float(posX / orthoW * 2 - 1), Float(posY / orthoH * 2 - 1)),
                halfExtent: SIMD2(Float(size / orthoW), Float(size / orthoH)),
                color: SIMD4(color, Float(alpha0) * fade),
                rotor: SIMD2(cos(angle), sin(angle)))
            n += 1
        }
        return n
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

    /// The per-axis clip-space scale that makes a scene of `sceneAspect` COVER a target of `targetAspect`
    /// (fill both axes, crop the overflow) without stretching — identity when the aspects match or are
    /// degenerate. The axis that would otherwise letterbox is grown past the clip bounds so it crops.
    public static func coverScale(sceneAspect: Double, targetAspect: Double) -> SIMD2<Float> {
        guard sceneAspect > 0, targetAspect > 0, sceneAspect.isFinite, targetAspect.isFinite else { return SIMD2(1, 1) }
        if targetAspect > sceneAspect { return SIMD2(1, Float(targetAspect / sceneAspect)) }
        return SIMD2(Float(sceneAspect / targetAspect), 1)
    }

    /// Render a prepared scene at `time` seconds, applying a gentle automatic camera parallax so layers
    /// configured with depth drift slightly — the wallpaper breathes instead of sitting perfectly still.
    /// `time = 0` is the still composite (no sway).
    public func render(_ scene: PreparedScene, width: Int, height: Int, time: Double = 0,
                       audio: AudioSpectrumProvider = SilentSpectrum()) -> RenderedFrame? {
        // Snapshot this frame's audio spectra as packer overrides (only non-zero when something is playing
        // and capture permission is granted; otherwise the arrays are zeros and audio shaders read flat).
        currentAudioOverrides = Self.audioOverrides(audio)
        // How many target pixels each scene unit covers (the larger axis, since cover-fit scales one axis up):
        // text rasterises at this density so it's sharp on the real display rather than upscaled from 1×.
        currentPixelScale = max(Double(width) / max(1, scene.orthoWidth), Double(height) / max(1, scene.orthoHeight))
        let swayX = Float(0.012 * sin(time * 0.6))
        let swayY = Float(0.009 * sin(time * 0.45))

        // Fill the target without distortion: cover its aspect and crop the overflow rather than stretching
        // a 16:9-authored scene onto a differently-shaped display.
        let aspectScale = Self.coverScale(sceneAspect: scene.orthoWidth / scene.orthoHeight,
                                          targetAspect: Double(width) / Double(height))

        // Pass 1: a layer with effects is rendered to its own texture and run through its effect chain.
        // The result is keyed by layer index; layers without effects are drawn directly in the main pass.
        // Setting LUMORA_NO_EFFECTS skips this and composites every layer flat (a safety/debug switch).
        var effectResult: [Int: MTLTexture] = [:]
        if effectRenderer != nil, ProcessInfo.processInfo.environment["LUMORA_NO_EFFECTS"] == nil {
            for (index, layer) in scene.layers.enumerated() where !layer.effects.isEmpty {
                let center = animatedCenter(layer, time: time, swayX: swayX, swayY: swayY)
                guard var texture = renderQuadToTexture(currentTexture(layer, time: time), center: center,
                                                        halfExtent: layer.halfExtent, uvScale: layer.uvScale,
                                                        tint: layer.tint, width: width, height: height,
                                                        rotA: layer.rotA, rotB: layer.rotB) else { continue }
                for effect in layer.effects {
                    guard let output = applyEffect(effect, to: texture, time: Float(time), width: width, height: height,
                        allocTarget: { w, h, fmt in self.borrowEffectTarget(width: w, height: h, pixelFormat: fmt) }) else { break }
                    texture = output
                }
                effectResult[index] = texture
            }
        }

        // Pass 2: composite layers in painter's order — the effect result full-screen for effect layers,
        // the layer quad directly otherwise.
        let frame: RenderedFrame?
        if scene.hasRefractiveParticles,
           let background = renderBackground(scene, time: time, aspectScale: aspectScale,
                                             swayX: swayX, swayY: swayY, effectResult: effectResult,
                                             width: width, height: height) {
            // Two-pass: the scene minus the droplets is composed to `background`; the final pass copies it,
            // then draws the refractive droplets sampling that background with normal-map displacement.
            var viewport = SIMD2<Float>(Float(width), Float(height))
            frame = withRenderPass(clearColor: scene.clearColor, width: width, height: height) { encoder in
                var quad = QuadUniform(center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1))
                var bgAlpha: Float = 1
                var bgTint = SIMD3<Float>(1, 1, 1)
                encoder.setRenderPipelineState(pipelineOver)
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
                encoder.setFragmentTexture(background, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setFragmentBytes(&bgAlpha, length: MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentBytes(&bgTint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

                var pAspect = aspectScale
                for prepared in scene.particles where prepared.isRefractive {
                    let n = simulateParticles(prepared, time: time, orthoW: scene.orthoWidth, orthoH: scene.orthoHeight)
                    guard n > 0, let normal = prepared.normalTexture else { continue }
                    encoder.setRenderPipelineState(particleRefract)
                    encoder.setVertexBuffer(prepared.instanceBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&pAspect, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                    encoder.setFragmentTexture(prepared.texture, index: 0)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    encoder.setFragmentTexture(normal, index: 1)
                    encoder.setFragmentTexture(background, index: 2)
                    encoder.setFragmentBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
                }
            }
        } else {
            frame = withRenderPass(clearColor: scene.clearColor, width: width, height: height) { encoder in
                drawSceneContent(encoder, scene: scene, time: time, aspectScale: aspectScale,
                                 swayX: swayX, swayY: swayY, effectResult: effectResult)
            }
        }
        // The frame is composited and read back (synchronous), so the effect targets are free to reuse next
        // frame instead of being reallocated.
        recycleEffectTextures()
        return frame
    }

    /// Draw the scene's image layers (painter's order) and its NON-refractive particles into `encoder`.
    /// The single-pass render path and the refractive scenes' background pass both use this; refractive
    /// droplets are drawn separately (they need the composited background as an input).
    private func drawSceneContent(_ encoder: MTLRenderCommandEncoder, scene: PreparedScene, time: Double,
                                  aspectScale: SIMD2<Float>, swayX: Float, swayY: Float,
                                  effectResult: [Int: MTLTexture]) {
        for (index, layer) in scene.layers.enumerated() {
            var alpha = layer.alphaAnimation.map { Float($0.value(at: time)) } ?? layer.alpha

            // An audio-visualiser layer drives its own scene graph: feed this frame's spectrum to the script,
            // run it, and draw the bars it produced (instead of the single base quad).
            if let group = layer.scriptGroup {
                drawScriptGroup(encoder, group: group, layerAlpha: alpha, aspectScale: aspectScale)
                continue
            }
            // A puppet layer draws its assembled mesh (indexed triangles) textured with the atlas,
            // instead of a flat quad.
            if let pup = layer.puppet {
                var pu = PuppetU(origin: pup.origin, scale: pup.scale, ortho: pup.ortho, aspectScale: aspectScale)
                var tint = layer.tint
                encoder.setRenderPipelineState(pipelinePuppet)
                encoder.setVertexBuffer(pup.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&pu, length: MemoryLayout<PuppetU>.stride, index: 1)
                encoder.setFragmentTexture(layer.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: pup.indexCount,
                                              indexType: .uint32, indexBuffer: pup.indexBuffer, indexBufferOffset: 0)
                continue
            }
            // A text layer rasterises its (possibly script-driven) string this frame and draws it as a quad
            // sized to the glyphs; an empty string draws nothing. The font is sized in scene units, so the
            // pixel dimensions map ≈1:1 to scene units for the quad half-extent.
            if let textLayer = layer.text {
                guard let (textTexture, w, h) = textLayer.currentTexture(pixelScale: currentPixelScale) else { continue }
                let half = SIMD2(Float(Double(w) / scene.orthoWidth), Float(Double(h) / scene.orthoHeight))
                // Honour the text's horizontal alignment: the origin is the string's left edge / centre / right
                // edge. Left-aligned text extends right of origin (centre shifts right by a half-width), etc.
                var center = animatedCenter(layer, time: time, swayX: swayX, swayY: swayY)
                switch textLayer.horizontalAlign {
                case "left":  center.x += half.x
                case "right": center.x -= half.x
                default: break
                }
                var quad = QuadUniform(center: center,
                                       halfExtent: half, uvScale: SIMD2(1, 1), aspectScale: aspectScale,
                                       rotA: layer.rotA, rotB: layer.rotB)
                var tint = layer.tint
                encoder.setRenderPipelineState(pipelineOver)
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
                encoder.setFragmentTexture(textTexture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                continue
            }
            encoder.setRenderPipelineState(layer.isAdditive ? pipelineAdditive : pipelineOver)
            var quad: QuadUniform
            var tint: SIMD3<Float>
            let texture: MTLTexture
            if let effected = effectResult[index] {   // effect output sits at the layer's placement in
                // scene-NDC (Pass 1 samples 1:1), so the composite carries the same cover scale as the
                // direct path — otherwise an effected layer would stretch while the rest is cropped.
                quad = QuadUniform(center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1), aspectScale: aspectScale)
                tint = SIMD3(1, 1, 1)
                texture = effected
            } else {
                quad = QuadUniform(center: animatedCenter(layer, time: time, swayX: swayX, swayY: swayY),
                                   halfExtent: layer.halfExtent, uvScale: layer.uvScale, aspectScale: aspectScale,
                                   rotA: layer.rotA, rotB: layer.rotB)
                tint = layer.tint
                texture = currentTexture(layer, time: time)
            }
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Particles draw on top of the composited layers, additively, as instanced sprite quads.
        for prepared in scene.particles where !prepared.isRefractive {
            // simulateParticles writes the live sprites directly into prepared.instanceBuffer and
            // returns how many — no staging array, no per-frame copy.
            let n = simulateParticles(prepared, time: time,
                                      orthoW: scene.orthoWidth, orthoH: scene.orthoHeight)
            guard n > 0 else { continue }
            encoder.setRenderPipelineState(prepared.isAdditive ? particleAdditive : particleAlpha)
            encoder.setVertexBuffer(prepared.instanceBuffer, offset: 0, index: 0)
            var pAspect = aspectScale
            encoder.setVertexBytes(&pAspect, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentTexture(prepared.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
    }

    /// Drive an audio-visualiser script group for this frame and draw the bars it produces. The script reads
    /// `audioBuffer.average[i]` (64 bands); feed it this frame's spectrum (left/right averaged), run update(),
    /// then draw each scripted layer as a quad. Each bar grows upward from its origin baseline — the universal
    /// visualiser convention — so it never sinks below where it sits at rest. With no audio every band is 0,
    /// the script leaves each bar at height 0, and nothing is drawn (graceful: an idle visualiser is empty,
    /// never wrong).
    private func drawScriptGroup(_ encoder: MTLRenderCommandEncoder, group: PreparedScriptGroup,
                                 layerAlpha: Float, aspectScale: SIMD2<Float>) {
        let left = currentAudioOverrides["g_AudioSpectrum64Left"] ?? []
        let right = currentAudioOverrides["g_AudioSpectrum64Right"] ?? []
        if !left.isEmpty || !right.isEmpty {
            let n = max(left.count, right.count)
            var bands = [Float](repeating: 0, count: n)
            for i in 0 ..< n {
                bands[i] = ((i < left.count ? left[i] : 0) + (i < right.count ? right[i] : 0)) * 0.5
            }
            group.runtime.setAudioSpectrum(bands)
        }
        group.runtime.runUpdate()
        encoder.setRenderPipelineState(group.isAdditive ? pipelineAdditive : pipelineOver)
        for bar in group.runtime.scriptedLayers() {
            let half = SIMD2(group.baseHalfExtent.x * bar.scale.x, group.baseHalfExtent.y * bar.scale.y)
            guard half.x > 0.0001, half.y > 0.0001 else { continue }   // a zero-height bar draws nothing
            let baseX = Float(Double(bar.origin.x) / group.orthoW * 2 - 1)
            let baseY = Float(Double(bar.origin.y) / group.orthoH * 2 - 1)
            // Honour the bar's pivot: a 'bottom' bar keeps its bottom edge at the baseline and grows up, a
            // 'top' bar keeps its top edge there and grows down, and 'centre' (the default) scales about the
            // baseline. Y is up in scene space, so a bottom pivot raises the centre by the half-height.
            let centerY: Float
            switch bar.alignment {
            case "bottom": centerY = baseY + half.y
            case "top":    centerY = baseY - half.y
            default:       centerY = baseY
            }
            var quad = QuadUniform(center: SIMD2(baseX, centerY), halfExtent: half,
                                   uvScale: group.uvScale, aspectScale: aspectScale)
            var tint = bar.color
            var a = bar.alpha * layerAlpha
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
            encoder.setFragmentTexture(group.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&a, length: MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Compose the scene (layers + non-refractive particles) into a reused offscreen texture that the
    /// refractive droplets then sample. Returns nil if the target can't be made (caller falls back to the
    /// single-pass path).
    private func renderBackground(_ scene: PreparedScene, time: Double, aspectScale: SIMD2<Float>,
                                  swayX: Float, swayY: Float, effectResult: [Int: MTLTexture],
                                  width: Int, height: Int) -> MTLTexture? {
        let target: MTLTexture
        if let pooled = pooledBackground, pooled.width == width, pooled.height == height {
            target = pooled
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
            target = made
            pooledBackground = made
        }
        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: scene.clearColor.x, green: scene.clearColor.y, blue: scene.clearColor.z, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        drawSceneContent(encoder, scene: scene, time: time, aspectScale: aspectScale,
                         swayX: swayX, swayY: swayY, effectResult: effectResult)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return target
    }

    /// The layer's texture at `time`: the looping video frame for a video-backed layer, else its static
    /// texture.
    private func currentTexture(_ layer: PreparedLayer, time: Double) -> MTLTexture {
        guard let track = layer.videoTrack else { return layer.texture }
        let frames = track.frames(device: device)   // uploads the decoded batch on first use (this thread)
        guard frames.count >= 2, track.frameDuration > 0 else { return layer.texture }
        let total = track.frameDuration * Double(frames.count)
        let loopTime = time.truncatingRemainder(dividingBy: total)
        let index = min(frames.count - 1, max(0, Int(loopTime / track.frameDuration)))
        return frames[index]
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
                                     uvScale: SIMD2<Float>, tint: SIMD3<Float>, width: Int, height: Int,
                                     rotA: SIMD2<Float> = SIMD2(1, 0), rotB: SIMD2<Float> = SIMD2(0, 1)) -> MTLTexture? {
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

        var quad = QuadUniform(center: center, halfExtent: halfExtent, uvScale: uvScale, rotA: rotA, rotB: rotB)
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
