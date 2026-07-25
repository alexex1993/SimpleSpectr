//
//  SpectrogramVideoRenderer.swift
//  SimpleSpectr
//
//  Offscreen Metal renderer for the "3D flyover" video export. Turns the cached
//  dB grid into a colored height-field (a landscape: X = frequency, Z = time,
//  Y = magnitude) and renders it one frame at a time into a CVPixelBuffer that
//  the AVAssetWriter pipeline consumes (see SpectrogramVideoExport.swift).
//
//  Motion style: the camera is fixed near the front; the whole landscape is
//  translated along -Z each frame so upcoming audio rises out of the distance,
//  flows toward the camera, passes the glowing "now" line, then slides under and
//  behind the camera. A distance fog dissolves the far edge into the background.
//
//  The Metal shaders are compiled from source at runtime, so no `.metal` file
//  (and no build-system change) is needed — the file drops straight into the
//  auto-synchronized SimpleSpectr group like every other `.swift` source.
//

import Foundation
import Metal
import CoreVideo
import simd

// MARK: - GPU-facing types (must match the shader struct layout below)

/// One landscape vertex. `SIMD3<Float>` has a 16-byte stride in Swift, matching
/// Metal's `float3`, so this struct maps 1:1 onto the shader's `SpectroVertex`.
nonisolated struct SpectroVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD3<Float>   // linear RGB (the sRGB target re-encodes on store)
}

/// Per-frame uniforms, shared by the background and landscape passes. Everything
/// is packed into 16-byte-aligned vectors so the Swift and Metal layouts agree
/// without padding surprises.
nonisolated private struct VideoUniforms {
    var viewProj: simd_float4x4    // projection * view (model translate is applied in-shader)
    var viewProjInv: simd_float4x4 // inverse, for unprojecting the background grid
    var cameraPos: SIMD4<Float>    // xyz
    var lightDir: SIMD4<Float>     // xyz, normalized, pointing toward the light
    var skyTop: SIMD4<Float>       // rgb (linear) at the top of the frame
    var skyBottom: SIMD4<Float>    // rgb (linear) at the horizon
    var gridColor: SIMD4<Float>    // rgb (linear) of the neon floor grid
    var params: SIMD4<Float>       // x fogStart, y fogEnd, z glowStrength, w ambient
    var params2: SIMD4<Float>      // x tzModel, y nowZWorld, z glowWidth, w time
    var params3: SIMD4<Float>      // x level (pulse), y gridY, z gridSpacing, w starsAmount
    var params4: SIMD4<Float>      // x viewportW, y viewportH, z gridAmount, w swayX
}

// MARK: - Background styling

/// Look of everything behind the landscape. The colors are derived from the
/// user's palette (see `VideoGridSnapshot`) so the backdrop always belongs to the
/// same picture as the terrain; the three amounts are user toggles.
nonisolated struct FlyoverBackground: Sendable {
    /// Deep tint at the top of the frame (linear RGB).
    var skyTop = SIMD3<Float>(0.010, 0.010, 0.018)
    /// Brighter tint at the horizon, so the terrain gets a colored glow behind it.
    var skyBottom = SIMD3<Float>(0.030, 0.026, 0.055)
    /// Neon floor-grid color (linear RGB).
    var gridColor = SIMD3<Float>(0.35, 0.16, 0.55)
    /// Star field intensity (0 = off).
    var stars: Float = 1
    /// Floor grid intensity (0 = off).
    var grid: Float = 1
    /// How strongly the audio level modulates the backdrop (0 = static).
    var pulse: Float = 1
    /// World-space height of the neon grid plane — below the landscape's floor.
    var gridY: Float = -0.55
    /// Spacing between grid lines in world units.
    var gridSpacing: Float = 0.75
}

// MARK: - Camera / look configuration

/// Framing + landscape shape. Sensible defaults live in `VideoExportOptions`; a
/// couple of these are surfaced to the user (height exaggeration, camera tilt).
nonisolated struct FlyoverCamera: Sendable {
    var verticalFOV: Float = 55 * .pi / 180
    var cameraHeight: Float = 1.5
    var cameraBack: Float = 2.9        // distance the camera sits behind the now-line (world -Z)
    var lookAheadZ: Float = 7.0        // where the camera aims down the +Z axis
    var lookY: Float = 0.25
    var worldWidth: Float = 4.4        // freq axis spans [-w/2, w/2]
    var heightScale: Float = 1.25      // magnitude → world Y
    var columnSpacing: Float = 0.06    // dz between time columns
    var fogStart: Float = 6.5
    var fogEnd: Float = 17.0
    var sway: Float = 0.0              // gentle side-to-side camera drift (0…1)
}

// MARK: - Landscape mesh

/// A built height-field ready to hand to the GPU, plus the geometry constants the
/// per-frame camera math needs.
nonisolated struct SpectroMesh {
    var vertices: [SpectroVertex]
    var indices: [UInt32]
    let columns: Int          // time columns along Z
    let freqLines: Int        // frequency lines along X
    let columnSpacing: Float  // dz
    let length: Float         // columns * dz (full landscape depth)

    /// Build the landscape from a snapshot of the cached dB grid.
    ///
    /// - Parameters:
    ///   - magnitudes: column-major dB grid `[col * bins + bin]` (linear bins).
    ///   - freqLines: number of frequency lines to sample across the axis.
    ///   - axis: frequency-axis mapping (so the X layout matches the on-screen plot).
    ///   - lut: 256-entry palette LUT in *linear* RGB.
    static func build(magnitudes: [Float],
                      columns: Int,
                      bins: Int,
                      minDB: Float,
                      maxDB: Float,
                      freqLines requestedLines: Int,
                      axis: FrequencyAxis,
                      lut: [SIMD3<Float>],
                      camera: FlyoverCamera) -> SpectroMesh {
        let nf = max(2, min(requestedLines, bins))
        let nc = max(2, columns)
        let invRange = 1.0 / max(1e-6, maxDB - minDB)
        let dz = camera.columnSpacing
        let hScale = camera.heightScale
        // Frequency lines are evenly spaced along X, so the central-difference
        // step is constant.
        let dxStep = 2 * camera.worldWidth / Float(nf - 1)

        // Precompute, for each frequency line, the fractional bin it samples and
        // its X coordinate — shared by every time column.
        var fracBins = [Double](repeating: 0, count: nf)
        var xs = [Float](repeating: 0, count: nf)
        for j in 0..<nf {
            let f = Double(j) / Double(nf - 1)             // 0 = bottom of axis
            let freq = axis.frequency(forFraction: f)
            fracBins[j] = freq * Double(axis.fftSize) / axis.sampleRate
            xs[j] = (Float(f) - 0.5) * camera.worldWidth
        }

        /// Linearly interpolate the dB value at a fractional bin in one column.
        func sample(colBase: Int, at fbin: Double) -> Float {
            let lo = max(0, min(bins - 1, Int(fbin)))
            let hi = min(bins - 1, lo + 1)
            let t = Float(max(0, min(1, fbin - Double(lo))))
            let a = magnitudes[colBase + lo]
            let b = magnitudes[colBase + hi]
            return a + (b - a) * t
        }

        /// Normalized magnitude 0…1 through the color window.
        func norm(_ db: Float) -> Float {
            var t = (db - minDB) * invRange
            if !t.isFinite { t = 0 }
            return min(max(t, 0), 1)
        }

        // First pass: heights (drives both Y and color).
        var heights = [Float](repeating: 0, count: nc * nf)
        for c in 0..<nc {
            let colBase = c * bins
            let rowBase = c * nf
            for j in 0..<nf {
                heights[rowBase + j] = norm(sample(colBase: colBase, at: fracBins[j]))
            }
        }

        // Second pass: vertices with central-difference normals + palette color.
        var vertices = [SpectroVertex]()
        vertices.reserveCapacity(nc * nf)
        for c in 0..<nc {
            let rowBase = c * nf
            let z = Float(c) * dz
            for j in 0..<nf {
                let h = heights[rowBase + j]
                let y = h * hScale

                // Neighboring heights for the surface normal (clamped at edges).
                let hL = heights[rowBase + max(0, j - 1)]
                let hR = heights[rowBase + min(nf - 1, j + 1)]
                let hD = heights[max(0, c - 1) * nf + j]
                let hU = heights[min(nc - 1, c + 1) * nf + j]
                let dHx = (hR - hL) * hScale
                let dHz = (hU - hD) * hScale
                // Tangents: (dxStep,dHx,0) along X, (0,dHz,2dz) along Z. Normal = Tz × Tx.
                var n = simd_cross(SIMD3<Float>(0, dHz, 2 * dz),
                                   SIMD3<Float>(dxStep, dHx, 0))
                let len = simd_length(n)
                n = len > 1e-6 ? n / len : SIMD3<Float>(0, 1, 0)
                if n.y < 0 { n = -n }

                let color = lut[Int(h * 255)]
                vertices.append(SpectroVertex(position: SIMD3<Float>(xs[j], y, z),
                                              normal: n,
                                              color: color))
            }
        }

        // Index buffer: two triangles per quad cell.
        var indices = [UInt32]()
        indices.reserveCapacity((nc - 1) * (nf - 1) * 6)
        for c in 0..<(nc - 1) {
            let row0 = UInt32(c * nf)
            let row1 = UInt32((c + 1) * nf)
            for j in 0..<(nf - 1) {
                let a = row0 + UInt32(j)
                let b = row0 + UInt32(j + 1)
                let cc = row1 + UInt32(j)
                let d = row1 + UInt32(j + 1)
                indices.append(contentsOf: [a, cc, b, b, cc, d])
            }
        }

        return SpectroMesh(vertices: vertices,
                           indices: indices,
                           columns: nc,
                           freqLines: nf,
                           columnSpacing: dz,
                           length: Float(nc) * dz)
    }
}

// MARK: - Renderer

nonisolated enum VideoRenderError: LocalizedError {
    case noDevice
    case shaderCompile(String)
    case pipeline(String)
    case textureCache
    case pixelBufferTexture

    var errorDescription: String? {
        switch self {
        case .noDevice:              return L("video.error.noGPU")
        case .shaderCompile(let m):  return "Shader compile failed: \(m)"
        case .pipeline(let m):       return "Pipeline creation failed: \(m)"
        case .textureCache:          return "Could not create Metal texture cache"
        case .pixelBufferTexture:    return "Could not wrap pixel buffer as a Metal texture"
        }
    }
}

/// Renders the flyover landscape to CVPixelBuffers. Created and used entirely
/// inside one detached export task, so it never crosses actor boundaries.
nonisolated final class SpectrogramVideoRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let backgroundDepthState: MTLDepthStencilState
    private let textureCache: CVMetalTextureCache
    private let width: Int
    private let height: Int
    private let depthTexture: MTLTexture

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0

    init(width: Int, height: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw VideoRenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw VideoRenderError.noDevice }
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw VideoRenderError.shaderCompile(error.localizedDescription)
        }
        guard let vfn = library.makeFunction(name: "flyover_vertex"),
              let ffn = library.makeFunction(name: "flyover_fragment") else {
            throw VideoRenderError.pipeline("missing shader functions")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.depthAttachmentPixelFormat = .depth32Float
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw VideoRenderError.pipeline(error.localizedDescription)
        }

        // Background pass: one full-screen triangle painting the sky, stars and
        // neon floor grid before the landscape is drawn over it.
        guard let bgV = library.makeFunction(name: "background_vertex"),
              let bgF = library.makeFunction(name: "background_fragment") else {
            throw VideoRenderError.pipeline("missing background shader functions")
        }
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = bgV
        bgDesc.fragmentFunction = bgF
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        bgDesc.depthAttachmentPixelFormat = .depth32Float
        do {
            backgroundPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
        } catch {
            throw VideoRenderError.pipeline(error.localizedDescription)
        }

        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dsDesc) else {
            throw VideoRenderError.pipeline("depth-stencil state")
        }
        depthState = ds

        // The backdrop must never occlude the terrain: always passes, never writes.
        let bgDS = MTLDepthStencilDescriptor()
        bgDS.depthCompareFunction = .always
        bgDS.isDepthWriteEnabled = false
        guard let bgState = device.makeDepthStencilState(descriptor: bgDS) else {
            throw VideoRenderError.pipeline("background depth-stencil state")
        }
        backgroundDepthState = bgState

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw VideoRenderError.textureCache
        }
        textureCache = cache

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let depthTex = device.makeTexture(descriptor: depthDesc) else {
            throw VideoRenderError.pipeline("depth texture")
        }
        depthTexture = depthTex
    }

    /// Upload the landscape mesh once, before rendering the frame sequence.
    func upload(mesh: SpectroMesh) {
        vertexBuffer = mesh.vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        indexBuffer = mesh.indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        indexCount = mesh.indices.count
    }

    /// Render one frame of the flyover into `pixelBuffer`.
    /// - Parameters:
    ///   - progress: 0…1 position along the track (drives the landscape scroll).
    ///   - time: elapsed seconds (drives the subtle camera sway).
    ///   - level: 0…1 audio loudness at this moment (drives the backdrop pulse).
    func render(into pixelBuffer: CVPixelBuffer,
                mesh: SpectroMesh,
                camera: FlyoverCamera,
                background: FlyoverBackground,
                progress: Float,
                time: Float,
                level: Float) throws {
        guard let vertexBuffer, let indexBuffer, indexCount > 0 else { return }

        // Wrap the pixel buffer as an sRGB Metal texture (GPU re-encodes linear → sRGB on store).
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm_srgb, width, height, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let colorTex = CVMetalTextureGetTexture(cvTex) else {
            throw VideoRenderError.pixelBufferTexture
        }

        // --- Camera / uniforms ---------------------------------------------------
        let aspect = Float(width) / Float(height)
        let proj = Self.perspective(fovY: camera.verticalFOV, aspect: aspect, near: 0.05, far: 200)

        // Landscape scroll: translate the world so the "now" column sits at z = 0.
        let nowCol = progress * Float(max(1, mesh.columns - 1))
        let tz = -nowCol * mesh.columnSpacing

        let swayX = camera.sway * 0.6 * sinf(time * 0.7)
        let eye = SIMD3<Float>(swayX, camera.cameraHeight, -camera.cameraBack)
        let center = SIMD3<Float>(swayX * 0.3, camera.lookY, camera.lookAheadZ)
        let view = Self.lookAt(eye: eye, center: center, up: SIMD3<Float>(0, 1, 0))
        let viewProj = proj * view

        // Pulse: a gentle boost that never fully dims the backdrop at silence.
        let pulse = 1 + background.pulse * 0.9 * min(max(level, 0), 1)

        var u = VideoUniforms(
            viewProj: viewProj,
            viewProjInv: viewProj.inverse,
            cameraPos: SIMD4<Float>(eye, 0),
            lightDir: SIMD4<Float>(simd_normalize(SIMD3<Float>(0.35, 0.9, -0.25)), 0),
            skyTop: SIMD4<Float>(background.skyTop, 0),
            skyBottom: SIMD4<Float>(background.skyBottom * pulse, 0),
            gridColor: SIMD4<Float>(background.gridColor * pulse, 0),
            params: SIMD4<Float>(camera.fogStart, camera.fogEnd, 0.85, 0.28),
            params2: SIMD4<Float>(tz, 0, 0.22, time),
            params3: SIMD4<Float>(min(max(level, 0), 1),
                                  background.gridY,
                                  background.gridSpacing,
                                  background.stars),
            params4: SIMD4<Float>(Float(width), Float(height), background.grid, swayX))

        // --- Render pass ---------------------------------------------------------
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.skyTop.x), green: Double(background.skyTop.y),
            blue: Double(background.skyTop.z), alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        // Backdrop first (depth-neutral), then the landscape draws over it.
        enc.setRenderPipelineState(backgroundPipeline)
        enc.setDepthStencilState(backgroundDepthState)
        enc.setFragmentBytes(&u, length: MemoryLayout<VideoUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<VideoUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<VideoUniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle,
                                  indexCount: indexCount,
                                  indexType: .uint32,
                                  indexBuffer: indexBuffer,
                                  indexBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        // `cvTex` retains the mapping until here; drop it after the GPU is done.
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // MARK: - Matrix helpers

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tanf(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    // MARK: - Shaders (compiled from source at runtime)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Members are non-packed float3 (16-byte aligned, 16-byte size) so the 48-byte
    // layout matches Swift's `SpectroVertex` (SIMD3<Float> has a 16-byte stride).
    struct SpectroVertex {
        float3 position;
        float3 normal;
        float3 color;
    };

    struct Uniforms {
        float4x4 viewProj;
        float4x4 viewProjInv;
        float4   cameraPos;
        float4   lightDir;
        float4   skyTop;
        float4   skyBottom;
        float4   gridColor;
        float4   params;   // x fogStart, y fogEnd, z glowStrength, w ambient
        float4   params2;  // x tzModel, y nowZWorld, z glowWidth, w time
        float4   params3;  // x level, y gridY, z gridSpacing, w starsAmount
        float4   params4;  // x viewportW, y viewportH, z gridAmount, w swayX
    };

    struct VSOut {
        float4 clip [[position]];
        float3 worldPos;
        float3 normal;
        float3 color;
    };

    // ---- Shared backdrop helpers -------------------------------------------

    // Vertical sky gradient in screen space: the deep tint at the top eases into
    // a brighter, palette-derived glow at the horizon. Both the background pass
    // and the landscape's fog read this, so terrain dissolves into exactly the
    // sky behind it instead of into a flat grey.
    static inline float3 sky_color(float2 uv, constant Uniforms& u) {
        float t = clamp(uv.y, 0.0, 1.0);          // 0 = top of frame
        float k = pow(t, 1.6);                    // keep the glow low on the frame
        return mix(u.skyTop.rgb, u.skyBottom.rgb, k);
    }

    static inline float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    // Procedural star field: one candidate star per cell, jittered inside it,
    // twinkling on its own phase. Fades out toward the horizon so the sky
    // thins out where the terrain and grid take over.
    static inline float3 star_field(float2 uv, float aspect, constant Uniforms& u) {
        float amount = u.params3.w;
        if (amount <= 0.001) { return float3(0.0); }
        float time = u.params2.w;
        // Parallax: the star sphere drifts opposite to the camera's sway.
        float2 sp = (uv * float2(aspect, 1.0)) * 110.0;
        sp.x -= u.params4.w * 26.0;
        float2 cell = floor(sp);
        float2 f = fract(sp) - 0.5;
        float h = hash21(cell);
        if (h < 0.972) { return float3(0.0); }
        float2 jitter = float2(hash21(cell + 17.0), hash21(cell + 43.0)) - 0.5;
        float d = length(f - jitter * 0.7);
        float core = smoothstep(0.085, 0.0, d);
        float twinkle = 0.55 + 0.45 * sin(time * 2.3 + h * 90.0);
        float bright = (h - 0.972) / 0.028;        // rare stars are the brightest
        // Thin the field out toward the bottom of the frame.
        float horizon = smoothstep(0.75, 0.25, uv.y);
        // Slightly cool white with a hint of the sky's own tint.
        float3 tint = mix(float3(0.85, 0.90, 1.0), normalize(u.skyBottom.rgb + 1e-4), 0.25);
        return tint * core * twinkle * bright * horizon * amount * 1.4;
    }

    // Neon floor grid on a plane below the landscape, unprojected per pixel so it
    // keeps true perspective, and scrolling with the terrain so the motion reads
    // as one continuous flight.
    static inline float3 floor_grid(float2 ndc, constant Uniforms& u) {
        float amount = u.params4.z;
        if (amount <= 0.001) { return float3(0.0); }
        float4 pNear = u.viewProjInv * float4(ndc, 0.0, 1.0);
        float4 pFar  = u.viewProjInv * float4(ndc, 1.0, 1.0);
        float3 ro = pNear.xyz / pNear.w;
        float3 rd = normalize((pFar.xyz / pFar.w) - ro);
        float gridY = u.params3.y;
        if (rd.y > -1e-4) { return float3(0.0); }   // ray never reaches the plane
        float t = (gridY - ro.y) / rd.y;
        if (t <= 0.0) { return float3(0.0); }
        float3 p = ro + rd * t;

        float spacing = max(u.params3.z, 1e-3);
        // Scroll the grid with the landscape (tzModel) so both move together.
        float2 g = float2(p.x, p.z + u.params2.x) / spacing;
        float2 w = fwidth(g);
        float2 lines = abs(fract(g - 0.5) - 0.5) / max(w, 1e-5);
        float line = 1.0 - clamp(min(lines.x, lines.y), 0.0, 1.0);

        // Distance falloff, plus a bright band right at the horizon.
        float dist = length(p - u.cameraPos.xyz);
        float fade = exp(-dist * 0.085);
        float horizonGlow = pow(clamp(1.0 - abs(rd.y) * 7.0, 0.0, 1.0), 3.0) * 0.35;
        return u.gridColor.rgb * (line * fade * 1.6 + horizonGlow) * amount;
    }

    // ---- Background pass ----------------------------------------------------

    struct BGOut {
        float4 clip [[position]];
        float2 uv;      // 0…1, y down from the top of the frame
        float2 ndc;
    };

    vertex BGOut background_vertex(uint vid [[vertex_id]]) {
        // One oversized triangle covering the whole frame — no vertex buffer.
        const float2 verts[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        float2 p = verts[vid];
        BGOut out;
        out.clip = float4(p, 1.0, 1.0);
        out.ndc = p;
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    fragment float4 background_fragment(BGOut in [[stage_in]],
                                        constant Uniforms& u [[buffer(1)]]) {
        float aspect = u.params4.x / max(u.params4.y, 1.0);
        float3 color = sky_color(in.uv, u);
        color += star_field(in.uv, aspect, u);
        color += floor_grid(in.ndc, u);
        return float4(color, 1.0);
    }

    // ---- Landscape pass -----------------------------------------------------

    vertex VSOut flyover_vertex(uint vid [[vertex_id]],
                               const device SpectroVertex* verts [[buffer(0)]],
                               constant Uniforms& u [[buffer(1)]]) {
        SpectroVertex v = verts[vid];
        float3 world = v.position;
        world.z += u.params2.x;               // scroll the landscape along Z
        VSOut out;
        out.clip = u.viewProj * float4(world, 1.0);
        out.worldPos = world;
        out.normal = v.normal;
        out.color = v.color;
        return out;
    }

    fragment float4 flyover_fragment(VSOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(1)]]) {
        float3 N = normalize(in.normal);
        float3 L = normalize(u.lightDir.xyz);
        float ambient = u.params.w;
        float diff = max(dot(N, L), 0.0);
        float shade = ambient + (1.0 - ambient) * diff;
        float3 color = in.color * shade;

        // Glowing "now" line where the currently-playing audio sits (world z = nowZ).
        float dz = in.worldPos.z - u.params2.y;
        float glowWidth = max(u.params2.z, 1e-3);
        float glow = u.params.z * exp(-(dz * dz) / (2.0 * glowWidth * glowWidth));
        color += glow * float3(1.0, 0.92, 0.78);

        // Distance fog into the *sky behind this pixel*, so the far ridges melt
        // into the gradient rather than into a flat color.
        float2 uv = in.clip.xy / max(float2(u.params4.x, u.params4.y), float2(1.0));
        float dist = length(in.worldPos - u.cameraPos.xyz);
        float fog = clamp((dist - u.params.x) / max(u.params.y - u.params.x, 1e-3), 0.0, 1.0);
        color = mix(color, sky_color(uv, u), fog);

        return float4(color, 1.0);
    }
    """
}
