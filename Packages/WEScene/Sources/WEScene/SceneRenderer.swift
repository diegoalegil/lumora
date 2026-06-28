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
    let uvScale: SIMD2<Float>        // content/POT crop of the sprite (as layers use), so a padded sprite
                                     // samples only its content region instead of stretching it over the quad
    let instanceBuffers: [MTLBuffer] // one per in-flight slot (ring-buffered); refilled each frame, not reallocated
}

/// How a pass's sampler slot gets its texture each frame: the effect's input ("previous"), a named
/// intermediate buffer, or a fixed aux texture (noise/mask) resolved once at prepare time.
private enum EffectInput {
    case previous
    case buffer(String)
    case aux(MTLTexture, content: SIMD2<Int>)   // a packaged aux (mask/normal) may be padded: carry its
                                                // content dims so g_Texture<n>Resolution.zw is the real size
    case background   // _rt_FullFrameBuffer: the scene composited so far (copybackground glass/water/refraction),
                      // bound per-frame to a backdrop texture; resolves to the effect input when none is supplied
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
    /// True if any pass samples `_rt_FullFrameBuffer` (copybackground) — the renderer must hand it the scene
    /// composited so far as the background input.
    var needsBackground: Bool {
        passes.contains { $0.samplers.contains { if case .background = $0.input { return true }; return false } }
    }
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
    // WE's per-object colorBlendMode (raw enum). 0 = Normal (alpha-over) and 31 = Additive use the fixed-function
    // fast paths; any other value composites through the framebuffer-fetch blend pipeline against the destination.
    var colorBlendMode: Int = 0
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
    // A WE composition layer: it has no quad of its own. Its `effects` run over an input built from its
    // `dependencyIndices` (the prepared layers it consumes), and the result composites full-screen at its place.
    var isComposition: Bool = false
    var dependencyIndices: [Int] = []
    // This layer is consumed by a composition layer (it feeds that layer's input), so it is NOT drawn directly.
    var consumed: Bool = false
    // A composition layer with no dependencies whose (allowlisted) effects run as a final post-process over the
    // whole composited scene — a procedural vignette. Applied after compositing rather than over named deps.
    var isFramebufferPostProcess: Bool = false
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
    fileprivate let bloomStrength: Float    // scene-level bloom; 0 = none (the extra pass is skipped entirely)
    fileprivate let bloomThreshold: Float
    fileprivate let zoom: Float             // general.zoom: scales the whole composite about its centre (1 = none)
    fileprivate let cameraPath: SceneCameraPath?   // animated scene camera (pan+zoom); nil = static framing
    /// True only if some layer can READ the audio spectrum — an audio-visualiser script group, or an effected
    /// layer (an effect may declare g_AudioSpectrum*). When false the renderer skips building the six per-frame
    /// audio-override arrays, since nothing would consume them. Computed once so it costs nothing per frame.
    fileprivate let usesAudio: Bool

    fileprivate init(layers: [PreparedLayer], clearColor: SceneVec3, particles: [PreparedParticles],
                     orthoWidth: Double, orthoHeight: Double, puppetReady: Bool,
                     bloomStrength: Float, bloomThreshold: Float, zoom: Float = 1, cameraPath: SceneCameraPath? = nil) {
        self.layers = layers
        self.clearColor = clearColor
        self.particles = particles
        self.orthoWidth = orthoWidth
        self.orthoHeight = orthoHeight
        self.puppetReady = puppetReady
        self.bloomStrength = bloomStrength
        self.bloomThreshold = bloomThreshold
        self.zoom = zoom
        self.cameraPath = cameraPath
        self.usesAudio = layers.contains { $0.scriptGroup != nil || !$0.effects.isEmpty }
        self.framebufferPostProcessIndices = layers.enumerated().filter { $0.element.isFramebufferPostProcess }.map { $0.offset }
    }

    /// Indices (painter order) of composition layers that post-process the whole composited scene (a vignette).
    /// Their effects run after the scene is composited; empty for almost every scene.
    fileprivate let framebufferPostProcessIndices: [Int]
    fileprivate var hasFramebufferPostProcess: Bool { !framebufferPostProcessIndices.isEmpty }

    /// How many layers will be drawn (0 means nothing resolved — the caller should show a fallback).
    public var layerCount: Int { layers.count }

    /// How many particle systems will be drawn (systems whose sprite couldn't be resolved faithfully are dropped).
    public var particleCount: Int { particles.count }

    /// True if the scene has anything to draw — image layers or particles. A particle-only scene has no
    /// layers but still renders its sprites over the clear colour.
    public var isRenderable: Bool { !layers.isEmpty || !particles.isEmpty }

    /// True if any particle system refracts the background (rain-on-glass) — the renderer takes a two-pass
    /// path for these, composing the scene to a texture the droplets then sample with displacement.
    fileprivate var hasRefractiveParticles: Bool { particles.contains { $0.isRefractive } }

    /// True if the scene has a WE composition layer (projectlayer/composelayer/…) that consumes other layers.
    /// Gates the composition path so a scene WITHOUT one renders exactly as before (byte-identical).
    fileprivate var hasCompositionLayers: Bool { layers.contains { $0.isComposition } }

    /// True if any layer animates (parallax, alpha/position keyframes, effects) or the scene emits
    /// particles — i.e. it moves over time and is worth driving with a render loop.
    public var hasAnimation: Bool {
        cameraPath?.isAnimated == true || !particles.isEmpty || layers.contains {
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
    /// The pixel format the final composite is written in. A CAMetalLayer hosting the live frame binds its
    /// drawable to this, so render(into:) can target the drawable directly with no channel swap or blit.
    public let compositePixelFormat: MTLPixelFormat = .rgba8Unorm
    /// On a GPU that can't sample block-compressed textures natively (Apple silicon doesn't support BCn),
    /// decompress DXT1/DXT5 to RGBA8 on the CPU at decode time so those textures still render instead of
    /// failing to upload. On a GPU that does support BCn (Intel/AMD) we keep the cheaper native upload.
    private let expandBlockTextures: Bool
    private let queue: MTLCommandQueue
    private let pipelineOver: MTLRenderPipelineState
    private let pipelineAdditive: MTLRenderPipelineState
    // Per-channel colorBlendMode composite (multiply/screen/overlay/…). Reads the destination via framebuffer
    // fetch, so it exists only on GPUs that support programmable blending (Apple silicon); nil elsewhere, where
    // non-trivial blend modes fall back to alpha-over (today's behaviour).
    private let pipelineBlend: MTLRenderPipelineState?
    private let pipelineBloom: MTLRenderPipelineState   // scene-level bloom combine (composite + bright glow)
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
    private var auxCache: [String: (texture: MTLTexture, content: SIMD2<Int>)] = [:]   // resolved aux, by name
    /// Optional on-disk fallback for textures a scene references but doesn't ship in its own package (WE's
    /// shared `materials/` assets live outside individual wallpapers). When set, a sampler name that isn't a
    /// built-in and isn't in the package is looked up at `<dir>/materials/<name>.tex` before defaulting to white.
    /// Defaults from `LUMORA_SHARED_ASSETS_DIR`; no-op (and zero cost) when unset or the file is absent.
    public var sharedAssetsDir: String? = ProcessInfo.processInfo.environment["LUMORA_SHARED_ASSETS_DIR"]
    private var pooledOutput: MTLTexture?              // reused frame target (readback path is synchronous)
    private var pooledBackground: MTLTexture?          // reused composited-scene target for refractive scenes
    private var pooledCopyBackground: MTLTexture?      // separate backdrop target for copybackground glass/water layers
    // Async present pipeline. The live path (compositeFrame with a present closure) no longer blocks the CPU on
    // the GPU each frame, so the CPU can encode the next frame while the GPU runs this one. `inFlightSemaphore`
    // caps the frames in flight at `maxFramesInFlight`. The only resource the CPU rewrites per frame is each
    // particle system's instance buffer, so those are ring-buffered (one copy per in-flight slot, indexed by
    // `currentParticleSlot`); every other reused target is a Metal-tracked texture, so the GPU automatically
    // orders a later frame's reuse after the earlier frame's reads — no CPU stall needed. The readback path
    // (withRenderPass) stays synchronous and always uses slot 0.
    private static let maxFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: SceneRenderer.maxFramesInFlight)
    private var frameSlotCounter = 0
    private var currentParticleSlot = 0
    // Effect render targets are reused across frames instead of reallocated every frame. They are Metal-tracked
    // textures recycled at the end of the frame; a later frame that borrows one writes into it only after the
    // GPU finishes the earlier frame's reads (automatic hazard tracking on the shared queue), so it is never
    // aliased while still in use even though the live path no longer waits on the GPU.
    private var effectTexturePool: [Int: [MTLTexture]] = [:]
    private var effectTexturesInUse: [MTLTexture] = []
    // The render size the pooled textures match. The pool is keyed by width/height, so after a display resize
    // the old-size textures (each tens of MB at 4K) are never borrowed again — clear them on a size change
    // instead of leaking them for the life of the wallpaper.
    private var effectPoolSize = (width: 0, height: 0)
    // The audio spectra (g_AudioSpectrum16/32/64 Left/Right) for the frame being rendered, as packer
    // overrides keyed by uniform name. Set at the top of render() from the AudioSpectrumProvider; merged
    // into every effect pass's uniforms. Empty (no audio uniforms touched) when the source is silent.
    private var currentAudioOverrides: [String: [Float]] = [:]
    // Target pixels per scene unit for the frame being rendered, set at the top of render(). Text layers
    // rasterise at this density so glyphs stay crisp on a Retina/4K target instead of being magnified 1×.
    private var currentPixelScale: Double = 1
    // The `time` (elapsed seconds) passed to the previous frame's script update, used to reconstruct the
    // per-frame delta for `engine.frametime`/getFrameTime() without a second clock — the engine stays a pure
    // function of `time`, so deterministic batch/golden renders reproduce exactly. nil before the first frame.
    private var lastScriptTime: Double?
    // This frame's reconstructed script delta (engine.frametime), computed ONCE per frame in render() and
    // shared by every scripted layer — so a scene with several visualiser/script groups feeds them all the
    // same real dt, instead of the 2nd..Nth group seeing `time == lastScriptTime` and falling back to 1/60.
    private var currentScriptFrameDelta: Double = 0.0166667
    // This frame's camerapath pan offset in clip space (already divided out of the camera zoom so it isn't
    // double-scaled by aspectScale). (0,0) for a static-camera scene, so animatedCenter is unchanged there.
    private var currentCamOffset: SIMD2<Float> = .zero

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
    // Per-channel layer blend for Wallpaper Engine's colorBlendMode. The maths is the standard Photoshop / W3C
    // compositing set (multiply, screen, overlay, soft-light, …) implemented clean-room from the public
    // per-channel formulas — no GPL/WE shader source is transcribed. A = destination (the scene composited so
    // far, read via framebuffer fetch), B = this layer's colour, op = the layer's opacity (texture alpha ×
    // layerAlpha). MSL select(falseVal, trueVal, cond) chooses per channel.
    inline float3 we_overlay(float3 a, float3 b) {
        return select(1.0 - 2.0 * (1.0 - a) * (1.0 - b), 2.0 * a * b, a < 0.5);
    }
    inline float3 we_softlight(float3 a, float3 b) {
        float3 d = select(((16.0 * a - 12.0) * a + 4.0) * a, sqrt(a), a > 0.25);
        return select(a + (2.0 * b - 1.0) * (d - a), a - (1.0 - 2.0 * b) * a * (1.0 - a), b <= 0.5);
    }
    inline float3 we_colorburn(float3 a, float3 b) {
        return select(max(1.0 - (1.0 - a) / b, 0.0), float3(0.0), b == 0.0);
    }
    inline float3 we_colordodge(float3 a, float3 b) {
        return select(min(a / (1.0 - b), 1.0), float3(1.0), b == 1.0);
    }
    inline float3 we_reflect(float3 a, float3 b) {
        return select(min(a * a / (1.0 - b), 1.0), float3(1.0), b == 1.0);
    }
    inline float3 we_apply_blend(int mode, float3 A, float3 B, float op) {
        // The handful of modes WE evaluates without the opacity mix.
        if (mode == 31) return A + B * op;          // Additive (weighted sum)
        if (mode == 10) return max(A, B);           // max
        if (mode == 5)  return min(A, B);           // min
        float3 f;
        switch (mode) {
            case 1:  f = min(A, B); break;                       // Darken
            case 2:  f = A * B; break;                           // Multiply
            case 3:  f = we_colorburn(A, B); break;              // ColorBurn
            case 4:  f = max(A + B - 1.0, 0.0); break;           // Subtract
            case 6:  f = max(A, B); break;                       // Lighten
            case 7:  f = 1.0 - (1.0 - A) * (1.0 - B); break;     // Screen
            case 8:  f = we_colordodge(A, B); break;             // ColorDodge
            case 9:  f = min(A + B, 1.0); break;                 // Add (clamped)
            case 11: f = we_overlay(A, B); break;                // Overlay
            case 12: f = we_softlight(A, B); break;              // SoftLight
            case 13: f = we_overlay(B, A); break;                // HardLight
            case 18: f = abs(A - B); break;                      // Difference
            case 19: f = A + B - 2.0 * A * B; break;             // Exclusion
            case 20: f = max(A + B - 1.0, 0.0); break;           // Subtract (alt index)
            case 21: f = we_reflect(A, B); break;                // Reflect
            case 22: f = we_reflect(B, A); break;                // Glow (Reflect, args swapped)
            case 23: f = min(A, B) - max(A, B) + 1.0; break;     // Phoenix
            case 24: f = (A + B) * 0.5; break;                   // Average
            case 25: f = 1.0 - abs(1.0 - A - B); break;          // Negation
            case 30: f = max(max(A.r, A.g), A.b) * B; break;     // Tint
            case 32: f = A + A * B; break;                       // glow-mult
            default: f = B; break;                               // Normal / unmapped → plain over
        }
        return mix(A, f, op);
    }
    fragment float4 lumora_scene_blend(VOut in [[stage_in]],
                                       float4 dst [[color(0)]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler samp [[sampler(0)]],
                                       constant float &layerAlpha [[buffer(0)]],
                                       constant float3 &tint [[buffer(1)]],
                                       constant int &mode [[buffer(2)]]) {
        float4 c = tex.sample(samp, in.uv);
        float3 B = c.rgb * tint;
        float op = clamp(c.a * layerAlpha, 0.0, 1.0);
        float3 outRGB = we_apply_blend(mode, dst.rgb, B, op);
        return float4(outRGB, dst.a);   // keep the destination alpha (WE preserves the background's alpha)
    }
    // Scene-level bloom: box-blur the bright-pass (luma/colour above `params.x`) and add it back scaled by
    // strength `params.y`. The base image is preserved; only highlights above the threshold glow, so the
    // threshold keeps mid-tones (a character, a background) untouched. Composite is opaque, so alpha = 1.
    fragment float4 lumora_scene_bloom(VOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler samp [[sampler(0)]],
                                       constant float2 &params [[buffer(0)]]) {
        float3 base = tex.sample(samp, in.uv).rgb;
        float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
        float3 bloom = float3(0.0);
        for (int dy = -3; dy <= 3; dy++) {
            for (int dx = -3; dx <= 3; dx++) {
                float3 s = tex.sample(samp, in.uv + float2(dx, dy) * texel * 6.0).rgb;
                bloom += max(float3(0.0), s - params.x);
            }
        }
        bloom /= 49.0;
        return float4(base + bloom * params.y, 1.0);
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
                                       constant float2 &aspectScale [[buffer(1)]],
                                       constant float2 &uvScale [[buffer(2)]]) {
        float2 corner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]    = { float2(0, 1),  float2(1, 1),  float2(0, 0),  float2(1, 0) };
        PInst p = insts[iid];
        POut out;
        // Scale the unit corner by halfExtent (local axes), THEN rotate by the sprite's rotor (cos, sin). For a
        // round sprite (halfExtent isotropic) this is identical to rotating first; for a velocity-aligned trail
        // (anisotropic halfExtent: length on local x, width on local y) it produces a ribbon oriented along the
        // rotor instead of an axis-aligned box that was merely spun.
        float2 c = corner[vid] * p.halfExtent;
        float2 r = float2(c.x * p.rotor.x - c.y * p.rotor.y, c.x * p.rotor.y + c.y * p.rotor.x);
        out.position = float4((p.center + r) * aspectScale, 0, 1);
        out.uv = uvs[vid] * uvScale;   // sample only the content region of a padded (POT) sprite
        out.color = p.color;
        return out;
    }
    fragment float4 lumora_particle_fragment(POut in [[stage_in]],
                                             texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]]) {
        float4 t = tex.sample(samp, in.uv);
        return float4(t.rgb * in.color.rgb, t.a * in.color.a);
    }
    // Glow particles use a SCREEN blend, not a raw additive one: Wallpaper Engine accumulates glows in HDR and
    // tone-maps the frame, so a cluster of overlapping glows reads as a soft bright spot, not a hard flat-white
    // disc. Screen — result = glow·(1-dst) + dst = 1-(1-glow)(1-dst) — reproduces that: identical to additive for
    // a lone faint glow on a dark area, but it soft-saturates where many glows pile up instead of clamping to a
    // blown-out white blob (the "flash on the character's face" case). Output is premultiplied by alpha so the
    // pipeline's `oneMinusDestinationColor` source factor forms the screen equation.
    fragment float4 lumora_particle_screen(POut in [[stage_in]],
                                           texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]]) {
        float4 t = tex.sample(samp, in.uv);
        float a = t.a * in.color.a;
        return float4(t.rgb * in.color.rgb * a, a);
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
        self.expandBlockTextures = !device.supportsBCTextureCompression
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "lumora_scene_vertex"),
                  let fragmentFunction = library.makeFunction(name: "lumora_scene_fragment"),
                  let particleVertex = library.makeFunction(name: "lumora_particle_vertex"),
                  let particleFragment = library.makeFunction(name: "lumora_particle_fragment"),
                  let particleScreenFragment = library.makeFunction(name: "lumora_particle_screen"),
                  let over = Self.makePipeline(device: device, vertex: vertexFunction,
                                               fragment: fragmentFunction, additive: false),
                  let additive = Self.makePipeline(device: device, vertex: vertexFunction,
                                                   fragment: fragmentFunction, additive: true),
                  let particleAdd = Self.makeParticlePipeline(device: device, vertex: particleVertex,
                                                              fragment: particleScreenFragment, additive: true, screen: true),
                  let particleOver = Self.makeParticlePipeline(device: device, vertex: particleVertex,
                                                               fragment: particleFragment, additive: false),
                  let particleRefractFragment = library.makeFunction(name: "lumora_particle_refract"),
                  let particleRefractPipe = Self.makeParticlePipeline(device: device, vertex: particleVertex,
                                                                      fragment: particleRefractFragment, additive: false),
                  let puppetVertex = library.makeFunction(name: "lumora_puppet_vertex"),
                  let puppet = Self.makePuppetPipeline(device: device, vertex: puppetVertex, fragment: fragmentFunction),
                  let bloomFragment = library.makeFunction(name: "lumora_scene_bloom"),
                  let bloom = Self.makePipeline(device: device, vertex: vertexFunction, fragment: bloomFragment, additive: false) else { return nil }
            self.pipelineOver = over
            self.pipelineAdditive = additive
            self.particleAdditive = particleAdd
            self.particleAlpha = particleOver
            self.particleRefract = particleRefractPipe
            self.pipelinePuppet = puppet
            self.pipelineBloom = bloom
            // Optional: the framebuffer-fetch blend pipeline for per-object colorBlendMode. Built only on GPUs
            // with programmable blending (Apple silicon); on others it stays nil and the non-trivial modes fall
            // back to alpha-over. Not in the guard above, so its absence never fails renderer construction.
            if device.supportsFamily(.apple1), let blendFragment = library.makeFunction(name: "lumora_scene_blend") {
                self.pipelineBlend = Self.makeBlendPipeline(device: device, vertex: vertexFunction, fragment: blendFragment)
            } else {
                self.pipelineBlend = nil
            }
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

        // Share the compositor's command queue so effect passes and the final composite sit on one queue —
        // Metal then orders their tracked-texture dependencies itself, no per-pass CPU wait needed.
        self.effectRenderer = EffectRenderer(device: device, queue: queue)   // nil only if the device can't build it
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
    private func resolveAuxTexture(_ name: String?, package: ScenePackage) -> (texture: MTLTexture, content: SIMD2<Int>) {
        // A procedural/full-content texture's content fills its whole buffer, so content == storage (ratio 1).
        func full(_ t: MTLTexture) -> (texture: MTLTexture, content: SIMD2<Int>) { (t, SIMD2(t.width, t.height)) }
        guard let name, !name.isEmpty else { return full(whiteTexture) }
        switch name {
        case "util/white": return full(whiteTexture)
        case "util/black": return full(blackTexture)
        case let n where n.hasPrefix("util/noise") || n.hasSuffix("noise"): return full(noiseTexture)
        default:
            if let cached = auxCache[name] { return cached }
            if let entry = package.entry(named: "materials/\(name).tex"),
               let decoded = try? SceneTexture.decodeFirstMip(entry.data, expandBlocks: expandBlockTextures),
               let texture = MetalTexture.make(decoded, device: device) {
                // A packaged mask/normal is stored in a POT buffer; its content sub-rect (imageWidth/Height)
                // is what a shader's g_Texture<n>Resolution.zw/.xy remap needs, not the padded storage size.
                let resolved = (texture, SIMD2(decoded.imageWidth, decoded.imageHeight))
                auxCache[name] = resolved
                return resolved
            }
            // Not in this package: try the shared-assets folder (WE keeps common materials outside each wallpaper).
            // Reject path-traversal names so a scene can't read outside the configured root.
            if let dir = sharedAssetsDir, !name.contains(".."), !name.hasPrefix("/"),
               let resolved = loadSharedAux(name, dir: dir) {
                auxCache[name] = resolved
                return resolved
            }
            return full(whiteTexture)
        }
    }

    /// Decode a `.tex` from the shared-assets folder, if present. Returns nil (→ white fallback) when the folder
    /// or file doesn't exist, so a missing shared pack is a silent no-op. Separated for unit testing.
    public func loadSharedAux(_ name: String, dir: String) -> (texture: MTLTexture, content: SIMD2<Int>)? {
        guard !name.contains(".."), !name.hasPrefix("/") else { return nil }
        let path = (dir as NSString).appendingPathComponent("materials/\(name).tex")
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? SceneTexture.decodeFirstMip(data, expandBlocks: expandBlockTextures),
              let texture = MetalTexture.make(decoded, device: device) else { return nil }
        return (texture, SIMD2(decoded.imageWidth, decoded.imageHeight))
    }

    /// Load a custom font's raw bytes from the shared-assets folder at `<dir>/<fontPath>` (e.g.
    /// `fonts/Foo.ttf`). Returns nil (→ system fallback) when absent. Path-traversal-guarded; unit-tested.
    public func loadSharedFontData(_ fontPath: String, dir: String) -> Data? {
        guard !fontPath.contains(".."), !fontPath.hasPrefix("/") else { return nil }
        let path = (dir as NSString).appendingPathComponent(fontPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
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

    /// The per-channel colorBlendMode pipeline: the fragment reads the destination via framebuffer fetch and
    /// returns the fully-composited colour, so hardware blending is DISABLED (the shader is the blend). Returns
    /// nil on a GPU without programmable blending — the caller then leaves those layers on the alpha-over path.
    private static func makeBlendPipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .rgba8Unorm
        color.isBlendingEnabled = false
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

    /// The instanced particle pipeline: a glow blend (screen, soft-saturating) or alpha-over (solid sprites).
    /// `screen` glows take a SCREEN blend — `glow·(1-dst) + dst` — fed a premultiplied fragment, so dense
    /// overlapping glows compress toward white instead of hard-clamping to a flat blown-out disc; for a lone
    /// faint glow it is indistinguishable from a raw additive blend. `additive` without `screen` is the legacy
    /// raw add (kept for callers that pass it); alpha-over is straight transparency for solid sprites.
    private static func makeParticlePipeline(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction,
                                             additive: Bool, screen: Bool = false) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .rgba8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        if screen {
            // Premultiplied source × (1 − dst) + dst = 1 − (1 − glow)(1 − dst): soft additive that can't blow out.
            color.sourceRGBBlendFactor = .oneMinusDestinationColor
            color.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
            color.destinationRGBBlendFactor = .one
            color.destinationAlphaBlendFactor = .one
        } else {
            color.sourceRGBBlendFactor = .sourceAlpha
            color.sourceAlphaBlendFactor = .one   // straight-alpha: don't square the source alpha
            color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        }
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
        // De-overlap piled text: some wallpapers bake several text components (author credits, clock parts) at
        // the SAME origin because their per-component positioning is a SceneScript Lumora can't fully run, so
        // they superimpose into an unreadable smear. Where ≥3 visible text layers share one exact origin, stack
        // them vertically by their heights so they read as a list. A shadow/outline pair (2 layers) is below the
        // threshold and left untouched, and a scene with no such pile is unaffected (byte-identical).
        var textStackOffset: [Int: Double] = [:]
        do {
            var groups: [Int64: [(idx: Int, height: Double)]] = [:]
            for (i, l) in document.layers.enumerated() where l.visible && l.isTextLayer {
                let key = Int64(l.origin.x.rounded()) &* 1_000_000 &+ Int64(l.origin.y.rounded())
                let h = max(1, (l.size?.y ?? l.pointSize) * Double(abs(l.scale.y) > 0 ? abs(l.scale.y) : 1))
                groups[key, default: []].append((idx: i, height: h))
            }
            for members in groups.values where members.count >= 3 {
                var cumulative = 0.0
                for m in members { textStackOffset[m.idx] = cumulative; cumulative += m.height }
            }
        }
        // A WE composition layer (projectlayer/composelayer/…) consumes the layers named in its `dependencies`:
        // those are rendered into the composition layer's input instead of being drawn directly. Collect the
        // consumed object ids, and map every object id to its prepared-layer index so the dependencies (and the
        // consumed flags) resolve after the prepare loop, regardless of layer order.
        let consumedIDs = Set(document.layers.filter { $0.isCompositionLayer }.flatMap { $0.dependencyIDs })
        var objectIDToPreparedIndex: [Int: Int] = [:]
        var compositionDeps: [Int: [Int]] = [:]   // prepared comp-layer index → the object ids it depends on
        var representativeBase: MTLTexture?       // first content layer's texture — the probe base for a post-process
        for (layerIndex, layer) in document.layers.enumerated() where layer.visible {
            // A composition layer carries no texture; its effects run over an input built from the layers it
            // consumes (resolved after the loop). Prepare its effect chain (skipping the opaque-layer stability
            // probe, which would drop a legitimate projection/grade) and emit a placeholder layer the render pass
            // fills from its dependencies. If it ends up with no usable effects it contributes nothing (the draw
            // pass skips a composition layer that produced no result), so it can never paint its placeholder quad.
            if layer.isCompositionLayer {
                // Probe the composition effects against a representative base — a dependency for a projection (it
                // precedes its composition layer), or the first content layer for a whole-composite post-process —
                // so the wash guard can catch an effect that blows the scene to white. A composition layer with NO
                // dependencies post-processes the whole composite, but only effects on a verified, aux-free
                // allowlist (a procedural vignette) run there: a colour grade / lens flare needs WE aux LUT
                // textures Lumora can't ship (license firewall) and would grey/haze the scene, so it stays off.
                let depBaseIndex = layer.dependencyIDs.lazy.compactMap { objectIDToPreparedIndex[$0] }.first
                let isPostProcess = depBaseIndex == nil
                let sourceEffects = isPostProcess
                    ? layer.effects.filter { isAllowlistedPostProcess($0, package: package) }
                    : layer.effects
                let probeBase = depBaseIndex.map { prepared[$0].texture } ?? representativeBase
                let compEffects = (sourceEffects.isEmpty ? nil : probeBase).map {
                    prepareEffects(sourceEffects, package: package, base: $0,
                                   center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1),
                                   tint: SIMD3(1, 1, 1), compositionProbe: !isPostProcess)
                } ?? []
                if let oid = layer.objectID { objectIDToPreparedIndex[oid] = prepared.count }
                if !layer.dependencyIDs.isEmpty { compositionDeps[prepared.count] = layer.dependencyIDs }
                var comp = PreparedLayer(
                    texture: whiteTexture, center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1),
                    alpha: Float(layer.alpha), alphaAnimation: layer.alphaAnimation, tint: SIMD3(1, 1, 1),
                    isAdditive: layer.blending == "additive" || layer.blending == "add",
                    parallaxDepth: SIMD2(0, 0), originAnimation: nil,
                    originScale: SIMD2(Float(2 / orthoW), Float(2 / orthoH)),
                    rotA: SIMD2(1, 0), rotB: SIMD2(0, 1), effects: compEffects,
                    videoTrack: nil, puppet: nil, text: nil, scriptGroup: nil)
                comp.isComposition = true
                // No dependencies but surviving allowlisted effects → a whole-composite post-process applied after
                // the scene is composited. With dependencies it's the projection path handled in Pass 1.
                comp.isFramebufferPostProcess = isPostProcess && !compEffects.isEmpty
                prepared.append(comp)
                continue
            }
            // A text layer (clock, label) draws rendered glyphs: build its font + (optional) script runtime;
            // the quad's size is derived at render time from the rasterised string. No packed texture.
            if layer.isTextLayer {
                // The font: from the package, else the shared-assets folder (a custom .ttf the wallpaper expects
                // to be installed), else CoreText's system fallback inside makeFont.
                var fontData = layer.fontPath.flatMap { package.entry(named: $0)?.data }
                if fontData == nil, let fp = layer.fontPath, let dir = sharedAssetsDir {
                    fontData = loadSharedFontData(fp, dir: dir)
                }
                let font = PreparedTextLayer.makeFont(data: fontData, pointSize: layer.pointSize)
                let runtime = layer.textScript.flatMap { SceneScriptRuntime(script: $0) }
                let prepText = PreparedTextLayer(runtime: runtime, staticText: layer.textValue ?? "",
                                                 font: font, color: SIMD3(Float(layer.color.x), Float(layer.color.y), Float(layer.color.z)),
                                                 device: device, horizontalAlign: layer.horizontalAlign, verticalAlign: layer.verticalAlign)
                // Stack downward by the de-overlap offset (scene y is up, so subtract) when this text is part of
                // a same-origin pile; 0 for everything else.
                let stackY = textStackOffset[layerIndex] ?? 0
                let center = SIMD2(Float(layer.origin.x / orthoW * 2 - 1), Float((layer.origin.y - stackY) / orthoH * 2 - 1))
                // A text/clock layer can be rolled too (angles.z): apply the same aspect-corrected rotation the
                // image path uses, so a tilted clock/label renders tilted instead of snapping axis-aligned.
                let textRoll = Float(layer.angles.z)
                let textAspect = Float(orthoW / orthoH)
                let textCos = cos(textRoll), textSin = sin(textRoll)
                prepared.append(PreparedLayer(
                    texture: whiteTexture, center: center, halfExtent: .zero, uvScale: SIMD2(1, 1),
                    alpha: Float(layer.alpha), alphaAnimation: layer.alphaAnimation, tint: SIMD3(1, 1, 1),
                    isAdditive: false, parallaxDepth: SIMD2(Float(layer.parallaxDepth.x), Float(layer.parallaxDepth.y)),
                    originAnimation: layer.originAnimation, originScale: SIMD2(Float(2 / orthoW), Float(2 / orthoH)),
                    rotA: SIMD2(textCos, -textSin / textAspect), rotB: SIMD2(textSin * textAspect, textCos),
                    effects: [], videoTrack: nil, puppet: nil, text: prepText,
                    scriptGroup: nil))
                continue
            }
            var texture: MTLTexture?
            var textureW = 0.0, textureH = 0.0
            var uvScale = SIMD2<Float>(1, 1)
            var isSolidFill = false
            if let path = layer.texturePath,
               let entry = package.entry(named: path),
               let decoded = try? SceneTexture.decodeFirstMip(entry.data, expandBlocks: expandBlockTextures),
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
            // The first real content layer is the probe base for any whole-composite post-process layer.
            if representativeBase == nil { representativeBase = texture }

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
                colorBlendMode: layer.colorBlendMode,
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
            if let oid = layer.objectID { objectIDToPreparedIndex[oid] = prepared.count - 1 }
        }
        // Resolve each composition layer's dependencies to prepared-layer indices, and flag the consumed layers
        // (those feed a composition layer's input, so the draw pass must not draw them directly). Done after the
        // loop so a dependency declared later in the object list still resolves.
        for (compIdx, depIDs) in compositionDeps {
            prepared[compIdx].dependencyIndices = depIDs.compactMap { objectIDToPreparedIndex[$0] }
        }
        for (oid, idx) in objectIDToPreparedIndex where consumedIDs.contains(oid) {
            prepared[idx].consumed = true
        }

        var preparedParticles: [PreparedParticles] = []
        for system in document.particleSystems {
            guard let sprite = particleSprite(system, package: package) else { continue }
            // Steady-state live count ≈ spawn rate × longest lifetime, capped to the system's maxcount.
            let count = SceneRenderer.particleInstanceCount(rate: system.rate, lifetimeUpper: system.lifetime.upperBound,
                                                            maxCount: system.maxCount)
            // One instance buffer per in-flight slot, allocated once and refilled each frame (never reallocated).
            // The async present path can have `maxFramesInFlight` frames running at once, so the CPU refills the
            // current slot while the GPU may still read an earlier frame's slot — they must not be the same buffer.
            let instanceBuffers = (0 ..< SceneRenderer.maxFramesInFlight).compactMap { _ in
                device.makeBuffer(length: MemoryLayout<ParticleInstance>.stride * count, options: .storageModeShared)
            }
            guard instanceBuffers.count == SceneRenderer.maxFramesInFlight else { continue }
            preparedParticles.append(PreparedParticles(system: system, texture: sprite.texture,
                                                       normalTexture: sprite.normal, count: count,
                                                       isAdditive: sprite.isAdditive, isRefractive: sprite.isRefractive,
                                                       uvScale: sprite.uvScale, instanceBuffers: instanceBuffers))
        }
        return PreparedScene(layers: prepared, clearColor: document.clearColor,
                             particles: preparedParticles, orthoWidth: orthoW, orthoHeight: orthoH,
                             puppetReady: puppetLayerCount > 0 && puppetReadyCount == puppetLayerCount,
                             bloomStrength: Float(document.bloomStrength), bloomThreshold: Float(document.bloomThreshold),
                             zoom: Float(document.zoom), cameraPath: document.cameraPath)
    }

    /// The sprite a particle system draws — its material's first bound texture and blend mode
    /// (additive for glowy sparks/embers, alpha-over for solid sprites like petals/butterflies). Returns
    /// nil if the sprite can't be resolved, so the system is skipped rather than drawn as white squares.
    private func particleSprite(_ system: ParticleSystem, package: ScenePackage)
        -> (texture: MTLTexture, normal: MTLTexture?, isAdditive: Bool, isRefractive: Bool, uvScale: SIMD2<Float>)? {
        guard let materialPath = system.materialPath, let entry = package.entry(named: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: entry.data)) as? [String: Any],
              let pass = (material["passes"] as? [[String: Any]])?.first
        else { return nil }
        let names = (pass["textures"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let first = names.first else { return nil }
        // Light-shaft / god-ray / beam sprites: WE draws these additively as faint volumetric rays whose look
        // depends on the layer behind them and a soft falloff we don't reproduce; a packaged shaft sprite drawn
        // straight is a hard bright streak/flare nothing like the scene in WE. The built-in procedural path
        // already omits these (worse to draw a wrong bright blob than to leave the effect out); apply the same
        // rule to a PACKAGED shaft sprite so it isn't rendered as a blown-out flare. (Halo/fog/glow/ember stay.)
        let shaftLike = ["shaft", "beam", "godray", "god_ray", "lightray", "light_ray", "light_shaft"]
        if shaftLike.contains(where: first.lowercased().contains) { return nil }
        guard let sprite = spriteTexture(named: first, package: package) else { return nil }
        // Rain-on-glass droplets (REFRACT combo + a normal map) distort the scene behind each sprite. We
        // refract by sampling the composited background displaced by the droplet's normal map (see the
        // refractive render branch). Needs the second texture; without it we can't refract faithfully, so
        // skip (a plain albedo blob would just obscure the scene — worse than the effect's absence).
        if (pass["combos"] as? [String: Any])?["REFRACT"] as? Int == 1 {
            guard names.count >= 2, let normal = spriteTexture(named: names[1], package: package) else { return nil }
            return (sprite.texture, normal.texture, false, true, sprite.uvScale)
        }
        let blending = (pass["blending"] as? String) ?? "normal"
        return (sprite.texture, nil, blending == "additive" || blending == "add", false, sprite.uvScale)
    }

    /// Load a particle sprite: WE's common built-in shapes procedurally (they aren't shipped in the
    /// package), packaged sprites from the scene, else nil so the system is skipped. `uvScale` is the
    /// content/POT crop (the sprite's content sub-rect of a power-of-two texture); (1,1) for a procedural
    /// or full-content sprite.
    private func spriteTexture(named name: String, package: ScenePackage) -> (texture: MTLTexture, uvScale: SIMD2<Float>)? {
        if name.hasPrefix("util/") { return (resolveAuxTexture(name, package: package).texture, SIMD2(1, 1)) }
        // Packaged sprite from the scene takes priority.
        if let entry = package.entry(named: "materials/\(name).tex"),
           let decoded = try? SceneTexture.decodeFirstMip(entry.data, expandBlocks: expandBlockTextures),
           let made = MetalTexture.make(decoded, device: device) {
            let uvScale = decoded.width > 0 && decoded.height > 0
                ? SIMD2(Float(min(1.0, Double(decoded.imageWidth) / Double(decoded.width))),
                        Float(min(1.0, Double(decoded.imageHeight) / Double(decoded.height))))
                : SIMD2<Float>(1, 1)
            return (made, uvScale)
        }
        // WE's unshipped built-in sprites: blob-like glows (halo, fog, dot, flare, …) approximate well as a
        // soft radial glow tinted by the particle's colour. Two families we DON'T approximate, because a
        // wrong stand-in is worse than the effect's absence: elongated shapes (shafts, beams, lightning,
        // debris), and FIRE/ember/spark — WE ships a flame sprite that scenes recolour per-emitter (a
        // "Wildfire" can be orange in one scene, blue energy in another), so a fixed white/orange blob is as
        // often wrong as right and just obscures the scene. Skip both rather than draw a wrong blob.
        if name.hasPrefix("particle/") {
            // Match at TOKEN boundaries (split the filename on non-letters), not as raw substrings, so "fire"
            // in "firefly" or "ray" in "spray" no longer wrongly skips a glow that names a blob word too.
            let tokens = Set(name.dropFirst("particle/".count).lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init))
            let skip: Set = ["shaft", "beam", "lightning", "bolt", "ray", "trail", "streak", "debris",
                             "fire", "flame", "ember", "spark", "lava", "magma", "wildfire"]
            let blob = ["halo", "glow", "drop", "dot", "fog", "flare", "smoke", "star", "bokeh", "circle"]
            // SKIP words match at token boundaries (so "fire" in "firefly" / "ray" in "spray" don't wrongly
            // skip a glow), but BLOB words match as a substring: a compound name like "chromaticdot" IS a round
            // glow and should get the procedural sprite, not be dropped because the token didn't split on "dot".
            if blob.contains(where: { name.contains($0) }), tokens.isDisjoint(with: skip) {
                return (haloTexture, SIMD2(1, 1))   // procedural glow fills its texture: no crop
            }
            // Nature petals/leaves (rosepetals, sakura, leaves): WE ships a soft alpha sprite per family that we
            // don't have. Unlike fire/debris (which recolour unpredictably per emitter), a falling-petal field is
            // a small soft shape tinted by the particle's own colour — a colour-tinted soft sprite at the right
            // place/colour is closer to WE than dropping the emitter and leaving the scene bare.
            let nature: Set = ["rosepetals", "petal", "petals", "leaf", "leaves", "blossom", "sakura"]
            if name.contains("/nature/") || !tokens.isDisjoint(with: nature) {
                return (haloTexture, SIMD2(1, 1))
            }
        }
        // Diagnostic (off by default): surface which sprites are being skipped so the silent drops that leave a
        // scene missing its snow/rain/petals/etc. become visible data instead of an invisible gap.
        if ProcessInfo.processInfo.environment["LUMORA_LOG_DROPS"] != nil {
            FileHandle.standardError.write(Data("DROP-SPRITE \(name)\n".utf8))
        }
        return nil
    }

    /// Built-in uniform values the renderer supplies to every effect stage: the animation clock, an
    /// identity model-view-projection (the effect quad already spans NDC), and each bound sampler's
    /// resolution as (storageW, storageH, contentW, contentH). `.xy` is the texel-size basis a downsample/
    /// blur needs; `.zw` is the content sub-rect a padded aux mask/normal remaps UVs into (`.zw / .xy`). For
    /// exact-size render targets the two are equal, so the ratio stays 1; for a POT-padded aux it's < 1.
    /// Pure, so the supplied built-in set (and the new live g_Frametime/g_Screen/g_TexelSize) is unit-testable.
    public static func effectOverrides(time: Float, frameDelta: Float, width: Int, height: Int,
                                       resolutions: [Int: (storage: SIMD2<Int>, content: SIMD2<Int>)]) -> [String: [Float]] {
        var overrides: [String: [Float]] = [
            "g_Time": [time],
            // Seconds since the previous frame (g_Frametime), the render size in pixels (g_Screen) and its
            // reciprocal (g_TexelSize = 1/size). A blur/downsample reads g_TexelSize for its per-pixel tap
            // offset and a fluid/advection pass scales motion by g_Frametime; left unbound they default to zero,
            // collapsing the taps to a zero offset (an identity no-op) so the effect silently does nothing.
            // Deterministic per frame, so the offscreen byte-identity oracle stays reproducible. A pass that
            // samples a downsampled FBO gets its own texel basis from g_Texture<n>Resolution (.xy) below.
            "g_Frametime": [frameDelta],
            "g_Screen": [Float(width), Float(height)],
            "g_TexelSize": [1.0 / Float(max(1, width)), 1.0 / Float(max(1, height))],
            // Half a texel (g_TexelSizeHalf) is what WE's separable-blur/downsample taps offset by; unbound it
            // defaults to zero and the bilinear taps land on the same texel (a passthrough). Same basis as
            // g_TexelSize, halved.
            "g_TexelSizeHalf": [0.5 / Float(max(1, width)), 0.5 / Float(max(1, height))],
            "g_ModelViewProjectionMatrix": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            // The inverse MVP defaults to a ZERO matrix when unbound, and an effect that unprojects through it
            // divides by a zero w → a NaN UV that blanks the layer. The effect quad is full-screen with an
            // identity MVP, so its inverse is identity too.
            "g_ModelViewProjectionMatrixInverse": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            // The pointer rests at the screen centre: a cursor-reactive effect (e.g. iris-follow-cursor) reads
            // these to nudge a region toward the mouse, and on a desktop wallpaper there's no live pointer to
            // track. Centre + an identity projection make the displacement evaluate to zero, so the effect is a
            // no-op rather than dividing by a zero matrix's w (which produced a NaN UV that blanked the layer).
            "g_PointerPosition": [0.5, 0.5],
            "g_PointerPositionLast": [0.5, 0.5],
            "g_EffectTextureProjectionMatrixInverse": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
        ]
        for (number, res) in resolutions {
            overrides["g_Texture\(number)Resolution"] =
                [Float(res.storage.x), Float(res.storage.y), Float(res.content.x), Float(res.content.y)]
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

    /// Return every target borrowed this frame to the pool. A recycled texture can be borrowed by the next
    /// frame before this one's GPU work finishes; that's safe because the targets are Metal-tracked, so the
    /// next frame's write into a reused texture is automatically ordered after this frame's last read of it.
    private func recycleEffectTextures() {
        for texture in effectTexturesInUse {
            let key = (texture.width &* 73_856_093) ^ (texture.height &* 19_349_663) ^ (Int(texture.pixelFormat.rawValue) &* 83_492_791)
            effectTexturePool[key, default: []].append(texture)
        }
        effectTexturesInUse.removeAll(keepingCapacity: true)
    }

    private func applyEffect(_ effect: PreparedEffect, to input: MTLTexture, time: Float,
                             width: Int, height: Int, background: MTLTexture? = nil,
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
        // `previous` ping-pongs: it starts at the effect input, then tracks the output of each full-size pass
        // (target == nil). WE swaps FBOs between such passes, so a chained blur→tint or separable blur reads the
        // PRIOR pass's result, not the original input. Reading `input` every time (the old behaviour) lost every
        // intermediate pass — the second full-size pass re-processed the raw layer instead of the first's output.
        var previousOutput = input
        for pass in effect.passes {
            var inputs: [(index: Int, texture: MTLTexture)] = []
            var resolutions: [Int: (storage: SIMD2<Int>, content: SIMD2<Int>)] = [:]
            for sampler in pass.samplers {
                let texture: MTLTexture
                let content: SIMD2<Int>
                switch sampler.input {
                // Render targets (the effect input and intermediate FBOs) are exact-size: content == storage.
                case .previous: texture = previousOutput; content = SIMD2(previousOutput.width, previousOutput.height)
                // copybackground: the scene composited so far. Falls back to the effect input when no backdrop is
                // supplied (e.g. the dry-run probe), so a copybackground effect never samples a stale/white texture.
                case .background: texture = background ?? input; content = SIMD2((background ?? input).width, (background ?? input).height)
                case .buffer(let name): texture = buffers[name] ?? whiteTexture; content = SIMD2(texture.width, texture.height)
                case .aux(let aux, let auxContent): texture = aux; content = auxContent
                }
                inputs.append((index: sampler.slot, texture: texture))
                resolutions[sampler.number] = (SIMD2(texture.width, texture.height), content)
            }
            let overrides = Self.effectOverrides(time: time, frameDelta: Float(currentScriptFrameDelta),
                                                 width: width, height: height, resolutions: resolutions)
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
            if pass.target == nil { result = output; previousOutput = output }   // a full-size output pass advances the effect result + the ping-pong cursor
        }
        return result
    }

    /// Compile a layer's effects and keep only the ones that actually contribute. Each pass is paired with
    /// its own transpiled vertex shader where it ships one (so rotation/shake/scroll and the blur-tap
    /// offsets link and run), falling back to a fixed full-screen vertex for fragment-only passes; an effect
    /// whose graph can't be fully built is dropped. Then the chain is dry-run at low resolution and any
    /// effect that blanks the layer is skipped, so it degrades gracefully instead of going transparent.
    /// Effect shaders verified to reproduce a wallpaper as a whole-composite post-process WITHOUT needing a WE
    /// aux LUT/gradient texture (which the license firewall keeps Lumora from shipping). Default-DENY: only a
    /// substring match here lets an implicit composition layer's effect run, mirroring the conservative
    /// colorBlendMode-31-only mapping. A colour grade / lens flare that maps colours through a missing LUT would
    /// grey or haze the scene, so it stays off until proven (extend this list only after a per-scene preview check).
    private static let postProcessAllowlist = ["cutout_vignette"]
    private func isAllowlistedPostProcess(_ effect: LayerEffect, package: ScenePackage) -> Bool {
        effect.passes.contains { pass in
            Self.postProcessAllowlist.contains { pass.fragmentShaderPath.contains($0) }
        }
    }

    private func prepareEffects(_ effects: [LayerEffect], package: ScenePackage, base: MTLTexture,
                                center: SIMD2<Float>, halfExtent: SIMD2<Float>, uvScale: SIMD2<Float>,
                                tint: SIMD3<Float>, compositionProbe: Bool = false) -> [PreparedEffect] {
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
                // WE turns a combo ON when a texture is bound to the sampler annotated with it — e.g. an
                // opacity-mask sampler `// {"combo":"MASK"}` enables the shader's `#if MASK` masked branch so a
                // water/displacement effect only distorts the masked region instead of the whole layer. The
                // scene rarely lists these combos explicitly, so derive them: for each sampler declaration with
                // a combo whose g_Texture<n> has a non-null bound texture, force the combo on. The explicit
                // pass combos still win (merged last).
                let samplerDecls = (ShaderUniforms.parse(fragmentSource)
                    + (vertexSource.map(ShaderUniforms.parse) ?? [])).filter { $0.type.hasPrefix("sampler") }
                for decl in samplerDecls {
                    guard let combo = decl.combo, !combo.isEmpty else { continue }
                    let number = Int(decl.name.dropFirst("g_Texture".count)) ?? -1
                    let bound = number == 0 || (number > 0 && number < pass.textures.count && pass.textures[number] != nil)
                    if bound { combos[combo] = 1 }
                }
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
                        let name = bound ?? sampler.defaultValue ?? ""
                        if name.contains("_rt_FullFrameBuffer") || name.contains("_rt_MipMappedFrameBuffer") {
                            // copybackground: this sampler reads the scene composited so far, bound per-frame.
                            resolvedInput = .background
                        } else {
                            let aux = resolveAuxTexture(bound ?? sampler.defaultValue, package: package)
                            resolvedInput = .aux(aux.texture, content: aux.content)
                        }
                    }
                    samplers.append((slot: slot, number: number, input: resolvedInput))
                }
                preparedPasses.append(PreparedPass(
                    pipeline: pipeline, hasVertex: hasVertex,
                    scalars: uniforms.filter { !$0.type.hasPrefix("sampler") },
                    vertexScalars: vertexScalars, constants: effect.constants,
                    target: pass.target, samplers: samplers))
            }
            guard graphOK, !preparedPasses.isEmpty else {
                if ProcessInfo.processInfo.environment["LUMORA_LOG_DROPS"] != nil {
                    FileHandle.standardError.write(Data("DROP-EFFECT \(effect.name)\n".utf8))
                }
                continue
            }
            compiled.append(PreparedEffect(passes: preparedPasses, fbos: effect.fbos))
        }
        guard !compiled.isEmpty else { return [] }

        // Diagnostic (off by default): keep every compiled pass, bypassing the dry-run drop gate, to measure the
        // ceiling of "all effects on" against the oracle. The gate below otherwise drops passes this renderer
        // can't yet do faithfully (they wash/erase the layer).
        if ProcessInfo.processInfo.environment["LUMORA_NO_DROP_GATE"] != nil { return compiled }

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
                // A composition layer's effect may legitimately thin coverage/detail (a perspective projection
                // spreads a small tile across the sky), so relax those two checks for it — but KEEP the wash
                // guard, which is exactly what stops a screen-blend-against-missing-aux effect from painting the
                // whole scene white (the failure that blanked the Zenitsu scene 3319713168).
                let minCoverage = compositionProbe ? probeCoverage * 0 : probeCoverage / 2
                let minDetail = compositionProbe ? probeDetail * 0 : probeDetail / 5
                guard coverage(rgba) >= minCoverage, detail(rgba) >= minDetail,
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
        let dst = prepared.instanceBuffers[currentParticleSlot].contents().assumingMemoryBound(to: ParticleInstance.self)
        var n = 0
        for i in 0 ..< prepared.count {
            let slot = UInt32(truncatingIfNeeded: i)
            let life = lerp(s.lifetime.lowerBound, s.lifetime.upperBound, rand(slot, 101))
            guard life > 0.001 else { continue }
            let t = time + rand(slot, 102) * life          // staggered so they don't all spawn at once
            let cycle = (t / life).rounded(.down)
            let age = t - cycle * life
            // `cycle` can exceed Int.max (a tiny lifetime at a huge or non-finite render time), where `Int(cycle)`
            // would trap. Only its low bits seed the per-cycle hash, so fold it into range without trapping —
            // bit-identical to the old conversion for every realistic (sub-2^53) cycle.
            let cycleSeed = cycle.isFinite ? UInt32(truncatingIfNeeded: Int(cycle.truncatingRemainder(dividingBy: 4_294_967_296))) : 0
            let seed = hash(slot, cycleSeed)

            // A sphere/disc emitter fills a disc (uniform by area: radius ∝ √rand) instead of a square box, with
            // distancemin hollowing the centre into a ring. WE's sphererandom is the common burst emitter, so the
            // square box mis-shaped most particle fields. A box emitter keeps the uniform per-axis spread.
            let spawnX: Double, spawnY: Double
            if s.isSphere {
                let ang = rand(seed, 1) * 2 * .pi
                let rmin = min(s.radiusMin, s.boxSize.x)
                let rr = (rmin * rmin + (s.boxSize.x * s.boxSize.x - rmin * rmin) * rand(seed, 2)).squareRoot()
                spawnX = s.origin.x + rr * cos(ang)
                spawnY = s.origin.y + rr * sin(ang) * (s.boxSize.x > 0 ? s.boxSize.y / s.boxSize.x : 1)
            } else {
                spawnX = s.origin.x + s.boxSize.x * (rand(seed, 1) * 2 - 1)
                spawnY = s.origin.y + s.boxSize.y * (rand(seed, 2) * 2 - 1)
            }
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
            // WE's `size` is a particle DIAMETER, halved into the radius the sprite quad extends from its centre
            // (the quad spans ±halfExtent = the full diameter). Without the halving every sprite drew at twice WE's
            // size, over-filling dense fields; the /2 matches WE and lifts ~20 particle scenes against the oracle.
            let baseSize = lerp(s.size.lowerBound, s.size.upperBound, rand(seed, 5)) * 0.5
            let alpha0 = lerp(s.alpha.lowerBound, s.alpha.upperBound, rand(seed, 6))
            var color = SIMD3<Float>(Float(lerp(s.color.min.x, s.color.max.x, rand(seed, 7)) / 255),
                                     Float(lerp(s.color.min.y, s.color.max.y, rand(seed, 8)) / 255),
                                     Float(lerp(s.color.min.z, s.color.max.z, rand(seed, 9)) / 255))

            // Drag (movement operator) damps the initial velocity exponentially: the distance travelled from
            // velocity over `age` is ∫v₀e^(-drag·t)dt = v₀·(1-e^(-drag·age))/drag, falling back to v₀·age when
            // there's no drag (the limit as drag→0), so an undragged system is byte-identical.
            let travel = s.drag > 0 ? (1 - exp(-s.drag * age)) / s.drag : age
            // Gravity is damped by the SAME drag — a dragged particle approaches terminal velocity g/drag
            // instead of accelerating forever. Position from constant gravity under linear drag is
            // (g/drag)·(age − travel); with no drag this is the familiar ½·g·age² (the drag→0 limit), so an
            // undragged system stays byte-identical.
            let gx = s.drag > 0 ? (s.gravity.x / s.drag) * (age - travel) : 0.5 * s.gravity.x * age * age
            let gy = s.drag > 0 ? (s.gravity.y / s.drag) * (age - travel) : 0.5 * s.gravity.y * age * age
            var posX = spawnX + velX * travel + gx
            var posY = spawnY + velY * travel + gy
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
            // A negative size (a malformed `sizerandom` min/max or a negative sizechange in untrusted .pkg JSON)
            // would flip the sprite quad's half-extent and render it inverted/garbled — clamp to non-negative.
            var size = max(0, baseSize * lerp(s.sizeStart, s.sizeEnd, sizeT))
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
            // controlpointattract: drift toward (or, for a negative scale, away from) a control point at the
            // emitter origin + offset. Modelled as a first-order relaxation — displacement = direction · force ·
            // (1-e^(-age)) — so it eases to a bounded terminal offset instead of integrating to an explosion;
            // the force falls off with distance past the threshold. A system may carry SEVERAL attractors (e.g.
            // a short-range repel + a long-range attract that hold a flock around a point); their displacements
            // SUM. Each push is clamped, then the accumulated displacement is clamped again to half the ortho so
            // N attractors can never push a sprite past the same bound a single one could.
            if !s.attractors.isEmpty {
                var cpDX = 0.0, cpDY = 0.0
                for a in s.attractors where a.scale != 0 {
                    let rx = spawnX - (s.origin.x + a.offset.x), ry = spawnY - (s.origin.y + a.offset.y)
                    let dist = max(1, (rx * rx + ry * ry).squareRoot())
                    let strength = a.scale / (1 + dist * dist / (a.threshold * a.threshold))
                    let push = max(-orthoW * 0.5, min(orthoW * 0.5, strength * (1 - exp(-age)) * 0.02))
                    cpDX += rx / dist * push
                    cpDY += ry / dist * push
                }
                // Bound the SUM by the same ±orthoW*0.5 each push already obeys, so a single-attractor system
                // is byte-identical (the sum equals its one push, already in range → the clamp is a no-op).
                posX += max(-orthoW * 0.5, min(orthoW * 0.5, cpDX))
                posY += max(-orthoW * 0.5, min(orthoW * 0.5, cpDY))
            }
            // vortex: orbit the particle about the centre. Tangential speed blends inner→outer by radius; the
            // angular speed ω = v/r is clamped so a large WE speed near the centre can't strobe. Rotation
            // preserves radius, so it can't explode — we add the rotated-minus-original offset to the position.
            if let v = s.vortex {
                let ox = spawnX - (s.origin.x + v.offset.x), oy = spawnY - (s.origin.y + v.offset.y)
                let dist = max(1, (ox * ox + oy * oy).squareRoot())
                let rt = max(0, min(1, (dist - v.distanceInner) / (v.distanceOuter - v.distanceInner)))
                let tangential = lerp(v.speedInner, v.speedOuter, rt)
                let omega = max(-6, min(6, tangential / dist))   // rad/s, clamped against strobing
                let a = omega * age, ca = cos(a), sa = sin(a)
                posX += (ox * ca - oy * sa) - ox
                posY += (ox * sa + oy * ca) - oy
            }
            // turbulence: a stateless curl-noise drift. A two-octave sum-of-sines flow field sampled at the
            // spawn position (·scale) and age (·timescale) gives a coherent wander that neighbours share then
            // peel away from; ∝age keeps it bounded, and the result is clamped so a bad scale/speed can't fling
            // sprites off-screen. Closed-form in (seed, age), so it stays deterministic like the rest of the sim.
            if let t = s.turbulence {
                let phase = rand(seed, 33) * (t.phaseMax > 0 ? t.phaseMax : 1)
                let tt = age * t.timescale + phase
                let spd = lerp(t.speed.lowerBound, t.speed.upperBound, rand(seed, 34))
                let fx = spawnX * t.scale, fy = spawnY * t.scale
                let dx = sin(fy + 0.9 * tt) + 0.5 * sin(2.1 * fy - 1.3 * tt + 1.7)
                let dy = cos(fx - 1.1 * tt) + 0.5 * cos(1.9 * fx + 1.2 * tt + 0.4)
                posX += max(-orthoW, min(orthoW, t.mask.x * spd * dx * age))
                posY += max(-orthoH, min(orthoH, t.mask.y * spd * dy * age))
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
            // Default round sprite: isotropic half-extent, oriented by the spin angle.
            var halfExtent = SIMD2(Float(size / orthoW), Float(size / orthoH))
            var rotor = SIMD2(cos(angle), sin(angle))
            // A spritetrail stretches the sprite into a ribbon along its velocity: local-x carries the streak
            // length (clamped speed·trailLength), local-y the sprite width, and the rotor aligns local-x to the
            // velocity direction. Slow particles fall back to the round sprite (atan2 is undefined at zero speed).
            if s.renderMode == .spriteTrail {
                let speed = (velX * velX + velY * velY).squareRoot()
                if speed > 1e-4 {
                    let len = max(s.trailMinLength, min(s.trailMaxLength, speed * s.trailLength))
                    let phi = Float(atan2(velY, velX))
                    halfExtent = SIMD2(Float(len * 0.5 / orthoW), Float(size / orthoH))
                    rotor = SIMD2(cos(phi), sin(phi))
                }
            }
            dst[n] = ParticleInstance(
                center: SIMD2(Float(posX / orthoW * 2 - 1), Float(posY / orthoH * 2 - 1)),
                halfExtent: halfExtent,
                color: SIMD4(color, Float(alpha0) * fade),
                rotor: rotor)
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
                       audio: AudioSpectrumProvider = SilentSpectrum(),
                       into target: MTLTexture? = nil,
                       present: ((MTLCommandBuffer) -> Void)? = nil) -> RenderedFrame? {
        // A zero (or negative) render size makes Metal abort the whole process on the texture descriptor — a
        // view's bounds can momentarily be 0 during window setup/teardown or a display reconfiguration. There's
        // nothing to draw at that size, so report no frame instead of crashing.
        guard width > 0, height > 0 else { return nil }
        // A non-finite time (a NaN/inf from a misbehaving clock) flows into time-derived index math — the video
        // frame pick (loopTime / frameDuration) and animation samplers — where Int(...) would trap. The app's
        // clock is always finite; sanitise here so the whole render is robust to a degenerate time, not just the
        // particle path. Time 0 is the still composite.
        let time = time.isFinite ? time : 0
        // The effect-texture pool is keyed by render size; after a display resize/rotation the old-size targets
        // (tens of MB each at 4K) would be retained but never borrowed again. Drop the pool on a size change so
        // it can't grow for the life of the wallpaper. (Within a size, it's reused frame-to-frame as intended.)
        if effectPoolSize.width != width || effectPoolSize.height != height {
            effectTexturePool.removeAll(keepingCapacity: true)
            effectPoolSize = (width, height)
        }
        // Snapshot this frame's audio spectra as packer overrides (only non-zero when something is playing
        // and capture permission is granted; otherwise the arrays are zeros and audio shaders read flat).
        // Skip the six array allocations entirely for a scene that can't read them (no script/effect layers).
        currentAudioOverrides = scene.usesAudio ? Self.audioOverrides(audio) : [:]
        // How many target pixels each scene unit covers (the larger axis, since cover-fit scales one axis up):
        // text rasterises at this density so it's sharp on the real display rather than upscaled from 1×.
        currentPixelScale = max(Double(width) / max(1, scene.orthoWidth), Double(height) / max(1, scene.orthoHeight))
        // Reconstruct this frame's script delta ONCE here (not per scripted group), so every scripted layer in a
        // multi-visualiser scene gets the same real per-frame dt for engine.frametime / getFrameTime().
        currentScriptFrameDelta = scriptFrameDelta(time)
        // WE relaxes its parallax to zero when the cursor sits centred (the state the WE reference frames were
        // captured in — default props, no audio, cursor centred). lumora's synthetic sway invented a perpetual
        // drift on every layer with parallaxDepth, which desynchronises the planes from WE. Hold the sway at
        // zero so the centred-cursor composite matches WE; keyframed originAnimation still plays.
        let swayX = Float(0)
        let swayY = Float(0)

        // Fill the target without distortion: cover its aspect and crop the overflow rather than stretching
        // a 16:9-authored scene onto a differently-shaped display.
        // Cover the target aspect, then apply the scene's camera zoom (general.zoom; 1 = none): WE scales the
        // whole composite about its centre, cropping the overflow. A zoomed scene (e.g. 1.1) renders ~10% tighter
        // on its subject — without it the frame reads as zoomed out versus WE.
        var aspectScale = Self.coverScale(sceneAspect: scene.orthoWidth / scene.orthoHeight,
                                          targetAspect: Double(width) / Double(height)) * Float(scene.zoom)
        // Animated scene camera (camerapath): zoom multiplies the composite scale (in addition to general.zoom),
        // and the origin offset pans every layer. Both gated on a present cameraPath, so a static-camera scene is
        // byte-identical. The pan is pre-divided by the camera zoom so folding zoom into aspectScale doesn't
        // double-scale the pan distance (aspectScale multiplies center+offset in the vertex shader).
        currentCamOffset = .zero
        if let cam = scene.cameraPath, cam.isAnimated {
            let camZoom = Float(cam.zoom(at: time))
            let off = cam.offset(at: time)
            aspectScale *= camZoom
            let z = camZoom != 0 ? camZoom : 1
            currentCamOffset = SIMD2(Float(-2 * off.x / scene.orthoWidth) / z, Float(-2 * off.y / scene.orthoHeight) / z)
        }

        // Pass 1: a layer with effects is rendered to its own texture and run through its effect chain.
        // The result is keyed by layer index; layers without effects are drawn directly in the main pass.
        // Setting LUMORA_NO_EFFECTS skips this and composites every layer flat (a safety/debug switch).
        var effectResult: [Int: MTLTexture] = [:]
        if effectRenderer != nil, ProcessInfo.processInfo.environment["LUMORA_NO_EFFECTS"] == nil {
            // copybackground: a glass/water/refraction layer samples the scene composited behind it
            // (_rt_FullFrameBuffer). Render that backdrop once — the other layers, EXCLUDING the copybackground
            // layers themselves (so glass doesn't sample its own quad) — into a separate pool, and feed it to
            // those effects. Only built when some layer actually needs it, so non-copybackground scenes are
            // byte-identical.
            let copyBgIndices = Set(scene.layers.enumerated()
                .filter { !$0.element.isComposition && $0.element.effects.contains { $0.needsBackground } }
                .map { $0.offset })
            var copyBg: MTLTexture? = nil
            if !copyBgIndices.isEmpty {
                copyBg = renderBackground(scene, time: time, aspectScale: aspectScale, swayX: swayX, swayY: swayY,
                                          effectResult: [:], width: width, height: height,
                                          skip: copyBgIndices, intoCopyPool: true)
            }
            for (index, layer) in scene.layers.enumerated() where !layer.effects.isEmpty {
                // A composition layer's effect input is its dependency layers composited into one transient
                // (built below), not a quad of its own; everything else renders its own quad exactly as before.
                let effectInput: MTLTexture
                if layer.isComposition {
                    guard let depInput = renderCompositionInput(layer, scene: scene, effectResult: effectResult,
                                                                time: time, swayX: swayX, swayY: swayY,
                                                                aspectScale: aspectScale, width: width, height: height) else { continue }
                    effectInput = depInput
                } else {
                    let center = animatedCenter(layer, time: time, swayX: swayX, swayY: swayY)
                    // The effect-input quad is a full-size transient target consumed entirely within this layer's
                    // synchronous effect chain (the chain's output replaces it and lands in effectResult). Borrow
                    // it from the per-frame pool instead of allocating a fresh ~33 MB texture every frame; it's
                    // returned by recycleEffectTextures() once the frame is composited.
                    // A single-layer scene has nothing behind this layer but the scene's clear colour, so clear the
                    // effect input to it (opaque) — the effect then blends its edge into that colour instead of a
                    // transparent void, killing the stray seam. A multi-layer scene keeps the transparent clear so
                    // the effect result composites correctly over the layers underneath.
                    let backdrop: SIMD3<Float>? = scene.layers.count == 1
                        ? SIMD3(Float(scene.clearColor.x), Float(scene.clearColor.y), Float(scene.clearColor.z)) : nil
                    guard let quadTexture = renderQuadToTexture(currentTexture(layer, time: time), center: center,
                                                               halfExtent: layer.halfExtent, uvScale: layer.uvScale,
                                                               tint: layer.tint, width: width, height: height,
                                                               rotA: layer.rotA, rotB: layer.rotB, backdrop: backdrop,
                                                               allocTarget: { w, h, fmt in self.borrowEffectTarget(width: w, height: h, pixelFormat: fmt) }) else { continue }
                    effectInput = quadTexture
                }
                var texture = effectInput
                for effect in layer.effects {
                    guard let output = applyEffect(effect, to: texture, time: Float(time), width: width, height: height,
                        background: effect.needsBackground ? copyBg : nil,
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
            frame = compositeFrame(into: target, present: present, clearColor: scene.clearColor, width: width, height: height) { encoder in
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
                    encoder.setVertexBuffer(prepared.instanceBuffers[currentParticleSlot], offset: 0, index: 0)
                    encoder.setVertexBytes(&pAspect, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                    var pUVScale = prepared.uvScale
                    encoder.setVertexBytes(&pUVScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                    encoder.setFragmentTexture(prepared.texture, index: 0)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    encoder.setFragmentTexture(normal, index: 1)
                    encoder.setFragmentTexture(background, index: 2)
                    encoder.setFragmentBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
                }
            }
        } else if scene.hasFramebufferPostProcess,
                  var composite = renderBackground(scene, time: time, aspectScale: aspectScale,
                                                   swayX: swayX, swayY: swayY, effectResult: effectResult,
                                                   width: width, height: height) {
            // An allowlisted whole-composite post-process (a procedural vignette): the scene is composited to a
            // texture, then each such layer's effects run over it in order, mirroring WE's composelayer/post-process
            // layers. Scene-level bloom, if any, is the same final present pass.
            for idx in scene.framebufferPostProcessIndices {
                for effect in scene.layers[idx].effects {
                    guard let out = applyEffect(effect, to: composite, time: Float(time), width: width, height: height,
                        allocTarget: { w, h, fmt in self.borrowEffectTarget(width: w, height: h, pixelFormat: fmt) }) else { break }
                    composite = out
                }
            }
            let postComposite = composite
            let useBloom = scene.bloomStrength > 0.1
            var params = SIMD2<Float>(scene.bloomThreshold, scene.bloomStrength)
            frame = compositeFrame(into: target, present: present, clearColor: scene.clearColor, width: width, height: height) { encoder in
                var quad = QuadUniform(center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1))
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
                encoder.setFragmentTexture(postComposite, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                if useBloom {
                    encoder.setRenderPipelineState(pipelineBloom)
                    encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                } else {
                    var bgAlpha: Float = 1
                    var bgTint = SIMD3<Float>(1, 1, 1)
                    encoder.setRenderPipelineState(pipelineOver)
                    encoder.setFragmentBytes(&bgAlpha, length: MemoryLayout<Float>.size, index: 0)
                    encoder.setFragmentBytes(&bgTint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                }
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        } else if scene.bloomStrength > 0.1,
                  let composite = renderBackground(scene, time: time, aspectScale: aspectScale,
                                                   swayX: swayX, swayY: swayY, effectResult: effectResult,
                                                   width: width, height: height) {
            // Scene-level bloom: the scene is composited to a texture, then a final pass adds a blurred
            // bright-pass glow over it. Only scenes whose `general.bloom` ships a real strength take this path;
            // every other scene falls through to the single-pass branch below, unchanged.
            var params = SIMD2<Float>(scene.bloomThreshold, scene.bloomStrength)
            frame = compositeFrame(into: target, present: present, clearColor: scene.clearColor, width: width, height: height) { encoder in
                var quad = QuadUniform(center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1))
                encoder.setRenderPipelineState(pipelineBloom)
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
                encoder.setFragmentTexture(composite, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        } else {
            frame = compositeFrame(into: target, present: present, clearColor: scene.clearColor, width: width, height: height) { encoder in
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
                                  effectResult: [Int: MTLTexture], skip: Set<Int> = []) {
        for (index, layer) in scene.layers.enumerated() {
            // A consumed dependency feeds a composition layer's input — it is never drawn directly to the screen.
            if layer.consumed { continue }
            // Excluded from a backdrop pass (the copybackground layers themselves, so glass doesn't sample itself).
            if skip.contains(index) { continue }
            // A composition layer contributes only through its full-screen effect result; if it produced none
            // (no usable effects), skip it so it never paints its placeholder quad over the scene.
            if layer.isComposition && effectResult[index] == nil { continue }
            var alpha = layer.alphaAnimation.map { Float($0.value(at: time)) } ?? layer.alpha

            // An audio-visualiser layer drives its own scene graph: feed this frame's spectrum to the script,
            // run it, and draw the bars it produced (instead of the single base quad).
            if let group = layer.scriptGroup {
                drawScriptGroup(encoder, group: group, layer: layer, layerAlpha: alpha, aspectScale: aspectScale,
                                time: time, swayX: swayX, swayY: swayY)
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
                guard let (textTexture, w, h) = textLayer.currentTexture(pixelScale: currentPixelScale, time: time) else { continue }
                let half = SIMD2(Float(Double(w) / scene.orthoWidth), Float(Double(h) / scene.orthoHeight))
                // Honour the text's horizontal alignment: the origin is the string's left edge / centre / right
                // edge. Left-aligned text extends right of origin (centre shifts right by a half-width), etc.
                var center = animatedCenter(layer, time: time, swayX: swayX, swayY: swayY)
                switch textLayer.horizontalAlign {
                case "left":  center.x += half.x
                case "right": center.x -= half.x
                default: break
                }
                // Vertical alignment anchors a string edge at the origin (scene y is up): a top-anchored
                // string hangs below origin, a bottom-anchored one rises above it.
                switch textLayer.verticalAlign {
                case "top":    center.y -= half.y
                case "bottom": center.y += half.y
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
            // A non-trivial colorBlendMode (anything but Normal=0 and Additive=31, which have fixed-function
            // fast paths) composites through the framebuffer-fetch blend pipeline, overriding the material blend
            // exactly as WE's injected passthroughblend pass does. Falls back to alpha-over where that pipeline
            // is unavailable (a GPU without programmable blending).
            let blendMode = layer.colorBlendMode
            let useShaderBlend = pipelineBlend != nil && blendMode != 0 && blendMode != 31
            encoder.setRenderPipelineState(useShaderBlend ? pipelineBlend! : (layer.isAdditive ? pipelineAdditive : pipelineOver))
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
            if useShaderBlend {
                var mode = Int32(blendMode)
                encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.size, index: 2)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Particles draw on top of the composited layers, additively, as instanced sprite quads.
        for prepared in scene.particles where !prepared.isRefractive {
            // simulateParticles writes the live sprites directly into this frame's instance buffer slot and
            // returns how many — no staging array, no per-frame copy.
            let n = simulateParticles(prepared, time: time,
                                      orthoW: scene.orthoWidth, orthoH: scene.orthoHeight)
            guard n > 0 else { continue }
            encoder.setRenderPipelineState(prepared.isAdditive ? particleAdditive : particleAlpha)
            encoder.setVertexBuffer(prepared.instanceBuffers[currentParticleSlot], offset: 0, index: 0)
            var pAspect = aspectScale
            encoder.setVertexBytes(&pAspect, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            var pUVScale = prepared.uvScale
            encoder.setVertexBytes(&pUVScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
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
    /// The per-frame script delta (seconds): the advance from the previous frame's `time` to this one, with a
    /// 1/60 default for the first frame or a non-advancing/backward time (a still, or a reload that resets
    /// elapsed to 0) — never a zero or negative dt. Pure, so the branch behaviour is unit-testable.
    public static func scriptFrameDelta(time: Double, lastTime: Double?) -> Double {
        guard let last = lastTime, time > last else { return 0.0166667 }
        return time - last
    }

    /// Reconstruct this frame's script delta from successive `time` values (no second wall-clock) and remember
    /// the time for next frame. Called ONCE per frame in render(), not per scripted group.
    private func scriptFrameDelta(_ time: Double) -> Double {
        defer { lastScriptTime = time }
        return Self.scriptFrameDelta(time: time, lastTime: lastScriptTime)
    }

    private func drawScriptGroup(_ encoder: MTLRenderCommandEncoder, group: PreparedScriptGroup,
                                 layer: PreparedLayer, layerAlpha: Float, aspectScale: SIMD2<Float>,
                                 time: Double, swayX: Float, swayY: Float) {
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
        // Feed the live engine clock before running update() so a time-driven script (a sweep/rotation that
        // reads engine.time, or one accumulating engine.getFrameTime()) advances instead of reading a frozen 0.
        group.runtime.setTime(time)
        group.runtime.setFrameTime(currentScriptFrameDelta)
        group.runtime.runUpdate()
        // The host layer's per-frame motion (parallax sway + origin keyframes) shifts every bar — the bars'
        // origins are relative to the host's base, so add the host's animated NDC delta to each.
        let hostOffset = animatedCenter(layer, time: time, swayX: swayX, swayY: swayY) - layer.center
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
            var quad = QuadUniform(center: SIMD2(baseX + hostOffset.x, centerY + hostOffset.y), halfExtent: half,
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
                                  width: Int, height: Int, skip: Set<Int> = [], intoCopyPool: Bool = false) -> MTLTexture? {
        // copybackground uses a SEPARATE pooled texture so a glass effect's read of the backdrop in Pass 1 can't
        // race the refractive-droplet path re-writing the main pooledBackground later in the same frame.
        let pool = intoCopyPool ? pooledCopyBackground : pooledBackground
        let target: MTLTexture
        if let pooled = pool, pooled.width == width, pooled.height == height {
            target = pooled
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
            target = made
            if intoCopyPool { pooledCopyBackground = made } else { pooledBackground = made }
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
                         swayX: swayX, swayY: swayY, effectResult: effectResult, skip: skip)
        encoder.endEncoding()
        commandBuffer.commit()
        // `target` is a tracked texture on the shared queue; the refractive-droplet pass that samples it is
        // ordered after this write automatically, and the frame's final readback wait is the barrier. No
        // CPU stall here (see EffectRenderer.renderPass for the rationale).
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
        // Camerapath pan: shift every layer by the camera offset (zero for a static-camera scene).
        center += currentCamOffset
        return center
    }

    /// Render one quad (a layer's texture at its placement, tint baked in, full opacity) onto a target, to
    /// feed an effect chain. Returns nil if the target can't be made. The target comes from `allocTarget` (the
    /// per-frame pool in the live path, a fresh texture in the one-time dry run); the pass clears it before
    /// drawing, so a recycled (dirty) texture is safe. The target clears to TRANSPARENT by default so the
    /// effect result composites over the layers below; a `backdrop` (the scene clear colour, passed only for a
    /// single-layer scene) clears it OPAQUE instead, so an effect that samples across the layer's edge blends
    /// into that colour rather than leaving a semi-transparent fringe — the stray seam against a flat
    /// background the owner flagged on the single-image scene 2636878454.
    /// Build a composition layer's effect input: draw each of its dependency layers into one full-screen
    /// transient (cleared transparent), in dependency order. A dependency that already ran its own effect chain
    /// (Pass 1 reached it first, since it precedes the composition layer) is drawn full-screen from its result;
    /// one without effects is drawn at its own placement. The composition layer's effects then project/grade
    /// this. Returns nil if it has no resolved dependencies (the caller then skips the layer).
    private func renderCompositionInput(_ comp: PreparedLayer, scene: PreparedScene,
                                        effectResult: [Int: MTLTexture], time: Double, swayX: Float, swayY: Float,
                                        aspectScale: SIMD2<Float>, width: Int, height: Int) -> MTLTexture? {
        let deps = comp.dependencyIndices.filter { $0 >= 0 && $0 < scene.layers.count }
        guard !deps.isEmpty,
              let target = borrowEffectTarget(width: width, height: height, pixelFormat: .rgba8Unorm),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        for depIndex in deps {
            let dep = scene.layers[depIndex]
            // A dependency that is itself a composition layer contributes only through its effect result; if it
            // produced none, skip it rather than drawing its white placeholder quad (which would wash the input).
            if dep.isComposition && effectResult[depIndex] == nil { continue }
            var quad: QuadUniform
            let texture: MTLTexture
            var tint: SIMD3<Float>
            if let effected = effectResult[depIndex] {
                // The dependency's effect result is already full-screen (placement baked in), like an effect layer.
                quad = QuadUniform(center: SIMD2(0, 0), halfExtent: SIMD2(1, 1), uvScale: SIMD2(1, 1), aspectScale: aspectScale)
                texture = effected
                tint = SIMD3(1, 1, 1)
            } else {
                quad = QuadUniform(center: animatedCenter(dep, time: time, swayX: swayX, swayY: swayY),
                                   halfExtent: dep.halfExtent, uvScale: dep.uvScale, aspectScale: aspectScale,
                                   rotA: dep.rotA, rotB: dep.rotB)
                texture = currentTexture(dep, time: time)
                tint = dep.tint
            }
            var alpha = dep.alphaAnimation.map { Float($0.value(at: time)) } ?? dep.alpha
            encoder.setRenderPipelineState(dep.isAdditive ? pipelineAdditive : pipelineOver)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniform>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        return target
    }

    private func renderQuadToTexture(_ source: MTLTexture, center: SIMD2<Float>, halfExtent: SIMD2<Float>,
                                     uvScale: SIMD2<Float>, tint: SIMD3<Float>, width: Int, height: Int,
                                     rotA: SIMD2<Float> = SIMD2(1, 0), rotB: SIMD2<Float> = SIMD2(0, 1),
                                     backdrop: SIMD3<Float>? = nil,
                                     allocTarget: ((Int, Int, MTLPixelFormat) -> MTLTexture?)? = nil) -> MTLTexture? {
        let texture: MTLTexture?
        if let allocTarget {
            texture = allocTarget(width, height, .rgba8Unorm)
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture,
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = backdrop.map {
            MTLClearColor(red: Double($0.x), green: Double($0.y), blue: Double($0.z), alpha: 1)
        } ?? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
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
        // Live path (allocTarget set, from the per-frame pool): `texture` is a tracked target on the shared
        // queue feeding this layer's effect chain, so Metal orders those reads after this write and the frame's
        // final readback wait is the only barrier needed — don't stall the CPU here. The one-time dry run
        // (allocTarget nil) reads the result straight back on the CPU to test the chain, so it must finish first.
        if allocTarget == nil { commandBuffer.waitUntilCompleted() }
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

    /// Block until every frame the live present path still has in flight has finished on the GPU. Acquiring all
    /// the semaphore's permits means every outstanding completion handler has run; releasing them leaves the
    /// pipeline empty and ready. Used to flush before reading a presented target back (tests) or at teardown.
    public func waitForInFlight() {
        for _ in 0 ..< Self.maxFramesInFlight { inFlightSemaphore.wait() }
        for _ in 0 ..< Self.maxFramesInFlight { inFlightSemaphore.signal() }
    }

    /// Encode a clear-then-`draw` render pass into `target` on `commandBuffer` — no commit, wait, or readback.
    /// Shared by the readback path (withRenderPass) and the direct-to-drawable present path (composite).
    private func encodeComposite(into target: MTLTexture, clearColor: SceneVec3,
                                 commandBuffer: MTLCommandBuffer, draw: (MTLRenderCommandEncoder) -> Void) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: clearColor.x, green: clearColor.y, blue: clearColor.z, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        draw(encoder)
        encoder.endEncoding()
        return true
    }

    /// Run the final composite either into the reusable readback target (returns a RenderedFrame — the
    /// offscreen / Checks path, synchronous) or straight into an external `target` (a CAMetalLayer drawable)
    /// that `present` then schedules, with NO CPU readback and NO wait — the live path pipelines the GPU behind
    /// the CPU and a completion handler frees the in-flight slot.
    private func compositeFrame(into target: MTLTexture?, present: ((MTLCommandBuffer) -> Void)?,
                                clearColor: SceneVec3, width: Int, height: Int,
                                draw: (MTLRenderCommandEncoder) -> Void) -> RenderedFrame? {
        guard let target else {
            return withRenderPass(clearColor: clearColor, width: width, height: height, draw: draw)
        }
        guard width > 0, height > 0 else { return nil }
        guard let present else {
            // An external target but no drawable to present: the caller reads `target` back on the CPU right
            // after this returns (the byte-identity oracle, previews), so finish the frame synchronously.
            currentParticleSlot = 0
            guard let commandBuffer = queue.makeCommandBuffer(),
                  encodeComposite(into: target, clearColor: clearColor, commandBuffer: commandBuffer, draw: draw)
            else { return nil }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return nil
        }
        // Live drawable present. Hold the CPU to at most `maxFramesInFlight` frames ahead of the GPU. Pick this
        // frame's particle-buffer slot before encoding (the draw closure refills it); the slot only comes round
        // again after `maxFramesInFlight` frames, by when the semaphore guarantees that older frame has finished.
        inFlightSemaphore.wait()
        currentParticleSlot = frameSlotCounter
        frameSlotCounter = (frameSlotCounter + 1) % Self.maxFramesInFlight
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeComposite(into: target, clearColor: clearColor, commandBuffer: commandBuffer, draw: draw)
        else { inFlightSemaphore.signal(); return nil }
        present(commandBuffer)               // commandBuffer.present(drawable) — scheduled, not read back
        // Free the slot when the GPU finishes this frame rather than blocking the CPU on it now. The composite
        // is the frame's only barrier (it reads every earlier pass), so its completion means the whole frame —
        // and its particle slot — is done; a later frame reusing a tracked target is ordered after it by Metal.
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()
        return nil
    }

    /// Set up the reusable offscreen target, run `draw` inside a clear render pass, and read the pixels back.
    private func withRenderPass(clearColor: SceneVec3, width: Int, height: Int,
                                draw: (MTLRenderCommandEncoder) -> Void) -> RenderedFrame? {
        // Metal aborts the process if a texture descriptor has a zero dimension; the public render entries that
        // reach here (render(texture:)/render(decoded:)) take an untrusted size, so guard it here too.
        guard width > 0, height > 0 else { return nil }
        // The readback path is synchronous (one frame at a time), so a single particle-buffer slot is enough.
        currentParticleSlot = 0
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
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeComposite(into: output, clearColor: clearColor, commandBuffer: commandBuffer, draw: draw)
        else { return nil }
        commandBuffer.commit()
        // The frame's single CPU barrier: this composite reads every effect/background texture produced earlier
        // this frame, so (tracked resources, shared queue) it can't start until all of them finish, and waiting
        // on it waits on the whole frame. The earlier passes commit without their own wait, so the GPU pipelines
        // them while the CPU keeps encoding — then one stall here before the pixels are read back.
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
