//
//  SpectrumBarsVideoRenderer.swift
//  SimpleSpectr
//
//  Offscreen Metal renderer for the "2D bars" video export — the flat, classic
//  audio-visualizer look: a row of segmented (LED-style) bars spread across the
//  frequency axis, growing up from a glowing baseline with a fading mirror
//  reflection underneath, over a dark palette-tinted backdrop.
//
//  Where the 3D flyover (SpectrogramVideoRenderer) uploads the whole track as a
//  static mesh and moves the camera, this mode is a full-screen fragment shader
//  driven by one small per-frame buffer of bar levels + peak caps, produced on
//  the CPU by `BarSpectrumAnimator`. Both are fed by the same
//  `VideoGridSnapshot` and drained by the same AVAssetWriter pipeline in
//  SpectrogramVideoExport.swift.
//
//  Like the flyover renderer, the shaders are compiled from source at runtime,
//  so no `.metal` file (and no build-system change) is needed.
//

import Foundation
import Metal
import CoreVideo
import simd

// MARK: - Look

/// Everything about how the bar visualizer is drawn. Colors come from the user's
/// palette (see `VideoExportOptions.barsLook(from:)`) so the clip matches the
/// on-screen spectrogram; the rest are user toggles with tuned defaults.
nonisolated struct BarsLook: Sendable {
    /// Number of bars across the frame.
    var barCount: Int = 64
    /// Multiplies how tall the bars grow. 1 = a full-scale bar exactly fills the
    /// frame; above that loud bars run off the top, which is the point.
    /// Deliberately *not* folded into `upHeight`, so the LED cells keep their
    /// size and only the bars get taller.
    var heightScale: Float = 1
    /// Chop each bar into LED-style cells instead of drawing it solid.
    var segmented = true
    /// Mirror the bars below the baseline as a fading reflection.
    var mirror = true
    /// Bloom around the bars and along the baseline (0 = flat).
    var glow: Float = 1
    /// Star-field intensity in the backdrop (0 = off).
    var stars: Float = 1
    /// How strongly the audio level lifts the backdrop (0 = static).
    var pulse: Float = 1

    // Palette-derived colors (linear RGB).
    var skyTop = SIMD3<Float>(0.007, 0.007, 0.014)      // frame edges
    var skyBottom = SIMD3<Float>(0.020, 0.016, 0.040)   // lift behind the bars
    var barLow = SIMD3<Float>(0.90, 0.05, 0.35)         // at the baseline
    var barHigh = SIMD3<Float>(0.55, 0.02, 0.42)        // at full height
    var accent = SIMD3<Float>(1.00, 0.35, 0.65)         // the baseline line

    /// Cells per full-height bar (the LED look).
    var segments: Float = 28
    /// Share of each bar's slot left empty, as a gap between bars.
    var slotGap: Float = 0.34
    /// Share of each LED cell left empty, as the gap between cells.
    var segGap: Float = 0.30

    /// Vertical position of the baseline, 0 = top of frame.
    var baseY: Float { mirror ? 0.52 : 0.94 }
    /// Height of a full-scale bar, in frame fractions.
    var upHeight: Float { mirror ? 0.50 : 0.88 }
    /// Depth of a full-scale reflection, in frame fractions.
    var downHeight: Float { mirror ? 0.46 : 0 }
}

// MARK: - Per-frame bar levels

/// Turns the cached dB grid into the per-frame bar levels the shader draws.
///
/// Bars are laid out across the *displayed* frequency axis, so they line up with
/// the spectrogram the user is looking at. A purely linear axis is the exception:
/// it crams everything musical into the first couple of bars, so those tracks get
/// a Mel spread instead (same range, perceptually even).
///
/// A class, not a struct, because the exporter steps it once per frame in order
/// and the attack/release envelope and peak caps are carried between frames.
nonisolated final class BarSpectrumAnimator {
    private let magnitudes: [Float]
    private let columns: Int
    private let bins: Int
    private let minDB: Float
    private let invRange: Float
    /// Inclusive bin range feeding each bar.
    private let ranges: [(lo: Int, hi: Int)]

    private var levels: [Float]
    private var peaks: [Float]
    private var holds: [Float]

    private let attackTime: Float
    private let releaseTime: Float
    /// Seconds a peak cap hangs before it starts falling.
    private let peakHold: Float = 0.55
    /// How fast a peak cap falls, in full scale per second.
    private let peakFall: Float = 0.55

    /// - Parameter smoothing: 0 = snappy, 1 = slow and fluid.
    init(snapshot: VideoGridSnapshot, barCount: Int, smoothing: Float) {
        magnitudes = snapshot.magnitudes
        columns = max(1, snapshot.columns)
        bins = max(1, snapshot.bins)
        minDB = snapshot.minDB
        invRange = 1 / max(1e-6, snapshot.maxDB - snapshot.minDB)

        let n = max(2, min(barCount, 256))
        let axis = Self.barAxis(for: snapshot.axis)
        let binsPerHz = Double(axis.fftSize) / axis.sampleRate
        var built = [(lo: Int, hi: Int)]()
        built.reserveCapacity(n)
        for j in 0..<n {
            let fLo = axis.frequency(forFraction: Double(j) / Double(n))
            let fHi = axis.frequency(forFraction: Double(j + 1) / Double(n))
            var lo = Int((fLo * binsPerHz).rounded(.down))
            var hi = Int((fHi * binsPerHz).rounded(.up)) - 1
            lo = max(0, min(bins - 1, lo))
            hi = max(lo, min(bins - 1, hi))
            built.append((lo, hi))
        }
        ranges = built

        levels = [Float](repeating: 0, count: n)
        peaks = [Float](repeating: 0, count: n)
        holds = [Float](repeating: 0, count: n)

        let s = min(max(smoothing, 0), 1)
        attackTime = 0.008 + s * 0.045
        releaseTime = 0.045 + s * 0.400
    }

    var barCount: Int { levels.count }

    /// Advance the envelope by `dt` seconds onto the column at `progress` (0…1).
    /// Returns levels followed by peak caps — the flat layout the shader reads.
    func step(progress: Float, dt: Float) -> [Float] {
        let n = levels.count
        let x = min(max(progress, 0), 1) * Float(columns - 1)
        let c0 = min(columns - 1, max(0, Int(x)))
        let c1 = min(columns - 1, c0 + 1)
        let f = x - Float(c0)
        let base0 = c0 * bins
        let base1 = c1 * bins

        // Time constants → per-frame coefficients (frame-rate independent).
        let a = 1 - expf(-dt / attackTime)
        let r = 1 - expf(-dt / releaseTime)

        var out = [Float](repeating: 0, count: n * 2)
        for j in 0..<n {
            let (lo, hi) = ranges[j]
            // A bar shows the loudest bin it covers — quiet neighbours must not
            // average away a narrow tone sitting inside the same band.
            var peakDB = -Float.greatestFiniteMagnitude
            for b in lo...hi {
                let v = magnitudes[base0 + b] + (magnitudes[base1 + b] - magnitudes[base0 + b]) * f
                if v > peakDB { peakDB = v }
            }
            var raw = (peakDB - minDB) * invRange
            if !raw.isFinite { raw = 0 }
            raw = min(max(raw, 0), 1)

            let lvl = levels[j]
            levels[j] = lvl + (raw - lvl) * (raw > lvl ? a : r)

            // Peak cap: jumps to a new high, hangs, then slides back down onto
            // the bar.
            if levels[j] >= peaks[j] {
                peaks[j] = levels[j]
                holds[j] = peakHold
            } else if holds[j] > 0 {
                holds[j] -= dt
            } else {
                peaks[j] = max(levels[j], peaks[j] - peakFall * dt)
            }

            out[j] = levels[j]
            out[n + j] = peaks[j]
        }
        return out
    }

    /// The axis the bars are spread across (see the class comment).
    private static func barAxis(for axis: FrequencyAxis) -> FrequencyAxis {
        guard axis.scale == .linear else { return axis }
        return FrequencyAxis.make(scale: .mel,
                                  sampleRate: axis.sampleRate,
                                  fftSize: axis.fftSize,
                                  bins: axis.bins)
    }
}

// MARK: - Renderer

/// Per-frame uniforms. Packed into 16-byte vectors so the Swift and Metal
/// layouts agree without padding surprises (same convention as the flyover).
nonisolated private struct BarsUniforms {
    var skyTop: SIMD4<Float>
    var skyBottom: SIMD4<Float>
    var barLow: SIMD4<Float>
    var barHigh: SIMD4<Float>
    var accent: SIMD4<Float>
    var p0: SIMD4<Float>   // x barCount, y segmented, z mirror, w glow
    var p1: SIMD4<Float>   // x baseY, y upHeight, z downHeight, w time
    var p2: SIMD4<Float>   // x level, y stars, z viewportW, w viewportH
    var p3: SIMD4<Float>   // x segments, y slotGap, z segGap, w pulse
    var p4: SIMD4<Float>   // x heightScale, yzw unused
}

/// Renders the 2D bar visualizer into CVPixelBuffers. Created and used entirely
/// inside one detached export task, so it never crosses actor boundaries.
nonisolated final class SpectrumBarsVideoRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let width: Int
    private let height: Int
    /// Levels + peak caps for the current frame (2 × barCount floats).
    private let barBuffer: MTLBuffer

    /// Upper bound on bars, matching the shader's fixed buffer expectations.
    static let maxBars = 256

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
        guard let vfn = library.makeFunction(name: "bars_vertex"),
              let ffn = library.makeFunction(name: "bars_fragment") else {
            throw VideoRenderError.pipeline("missing bar shader functions")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw VideoRenderError.pipeline(error.localizedDescription)
        }

        guard let buf = device.makeBuffer(length: Self.maxBars * 2 * MemoryLayout<Float>.stride,
                                          options: .storageModeShared) else {
            throw VideoRenderError.pipeline("bar level buffer")
        }
        barBuffer = buf

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw VideoRenderError.textureCache
        }
        textureCache = cache
    }

    /// Render one frame.
    /// - Parameters:
    ///   - bars: levels followed by peak caps, as produced by `BarSpectrumAnimator`.
    ///   - time: elapsed seconds (drives the backdrop drift and the twinkle).
    ///   - level: 0…1 audio loudness now (drives the backdrop pulse).
    func render(into pixelBuffer: CVPixelBuffer,
                bars: [Float],
                look: BarsLook,
                time: Float,
                level: Float) throws {
        let n = min(bars.count / 2, Self.maxBars)
        guard n > 0 else { return }

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm_srgb, width, height, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let colorTex = CVMetalTextureGetTexture(cvTex) else {
            throw VideoRenderError.pixelBufferTexture
        }

        // Levels first, peak caps second — the shader indexes [i] and [n + i].
        let dst = barBuffer.contents().bindMemory(to: Float.self, capacity: Self.maxBars * 2)
        let src = bars.count / 2
        for i in 0..<n {
            dst[i] = bars[i]
            dst[n + i] = bars[src + i]
        }

        let clamped = min(max(level, 0), 1)
        var u = BarsUniforms(
            skyTop: SIMD4<Float>(look.skyTop, 0),
            skyBottom: SIMD4<Float>(look.skyBottom, 0),
            barLow: SIMD4<Float>(look.barLow, 0),
            barHigh: SIMD4<Float>(look.barHigh, 0),
            accent: SIMD4<Float>(look.accent, 0),
            p0: SIMD4<Float>(Float(n), look.segmented ? 1 : 0, look.mirror ? 1 : 0, look.glow),
            p1: SIMD4<Float>(look.baseY, look.upHeight, look.downHeight, time),
            p2: SIMD4<Float>(clamped, look.stars, Float(width), Float(height)),
            p3: SIMD4<Float>(look.segments, look.slotGap, look.segGap, look.pulse),
            p4: SIMD4<Float>(max(0.05, look.heightScale), 0, 0, 0))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(look.skyTop.x), green: Double(look.skyTop.y),
            blue: Double(look.skyTop.z), alpha: 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(barBuffer, offset: 0, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<BarsUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        // `cvTex` retains the mapping until here; drop it after the GPU is done.
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // MARK: - Shaders (compiled from source at runtime)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 skyTop;
        float4 skyBottom;
        float4 barLow;
        float4 barHigh;
        float4 accent;
        float4 p0;   // x barCount, y segmented, z mirror, w glow
        float4 p1;   // x baseY, y upHeight, z downHeight, w time
        float4 p2;   // x level, y stars, z viewportW, w viewportH
        float4 p3;   // x segments, y slotGap, z segGap, w pulse
        float4 p4;   // x heightScale
    };

    struct BarsOut {
        float4 clip [[position]];
        float2 uv;   // 0…1, y down from the top of the frame
    };

    vertex BarsOut bars_vertex(uint vid [[vertex_id]]) {
        // One oversized triangle covering the whole frame — no vertex buffer.
        const float2 verts[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        float2 p = verts[vid];
        BarsOut out;
        out.clip = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    static inline float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    // Procedural star field, thinned out near the bars so the backdrop stays
    // behind the subject. Same construction as the flyover's sky.
    static inline float3 star_field(float2 uv, float aspect, float baseY, constant Uniforms& u) {
        float amount = u.p2.y;
        if (amount <= 0.001) { return float3(0.0); }
        float time = u.p1.w;
        float2 sp = (uv * float2(aspect, 1.0)) * 105.0;
        sp.x -= time * 0.9;                       // very slow drift
        float2 cell = floor(sp);
        float2 f = fract(sp) - 0.5;
        float h = hash21(cell);
        if (h < 0.974) { return float3(0.0); }
        float2 jitter = float2(hash21(cell + 17.0), hash21(cell + 43.0)) - 0.5;
        float d = length(f - jitter * 0.7);
        float core = smoothstep(0.085, 0.0, d);
        float twinkle = 0.55 + 0.45 * sin(time * 2.3 + h * 90.0);
        float bright = (h - 0.974) / 0.026;
        float clear = smoothstep(0.10, 0.34, abs(uv.y - baseY));   // keep clear of the bars
        float3 tint = mix(float3(0.85, 0.90, 1.0), normalize(u.skyBottom.rgb + 1e-4), 0.3);
        return tint * core * twinkle * bright * clear * amount * 1.2;
    }

    // Dark, palette-tinted backdrop: a lift around the baseline, two slow
    // drifting blobs that breathe with the music, and a vignette.
    static inline float3 backdrop(float2 uv, float aspect, constant Uniforms& u) {
        float baseY = u.p1.x;
        float level = u.p2.x;
        float pulse = u.p3.w;
        float time  = u.p1.w;

        // Keep it dark: the bars are the subject, the backdrop only hints at the
        // palette. The lift sits *near* the baseline, not on it, so the glowing
        // line reads against darkness.
        float dy = abs(uv.y - baseY);
        float3 col = mix(u.skyTop.rgb, u.skyBottom.rgb * 0.55, smoothstep(0.55, 0.06, dy));

        float breathe = 0.6 + pulse * 0.55 * level;
        float2 a = float2((uv.x - 0.28 + 0.03 * sin(time * 0.21)) * aspect, uv.y - baseY + 0.14);
        float2 b = float2((uv.x - 0.74 - 0.03 * sin(time * 0.17)) * aspect, uv.y - baseY - 0.20);
        col += u.skyBottom.rgb * breathe * (exp(-dot(a, a) * 4.0) * 0.85 +
                                            exp(-dot(b, b) * 6.0) * 0.60);

        col += star_field(uv, aspect, baseY, u);

        float2 v = uv - 0.5;
        col *= 1.0 - 0.75 * dot(v, v);
        return col;
    }

    fragment float4 bars_fragment(BarsOut in [[stage_in]],
                                  const device float* bars [[buffer(0)]],
                                  constant Uniforms& u [[buffer(1)]]) {
        float2 uv = in.uv;
        float aspect = u.p2.z / max(u.p2.w, 1.0);
        int   n        = int(u.p0.x);
        float segOn    = u.p0.y;
        float mirrorOn = u.p0.z;
        float glow     = u.p0.w;
        float baseY    = u.p1.x;
        float upH      = u.p1.y;
        float dnH      = u.p1.z;
        float level    = u.p2.x;
        float segCount = max(u.p3.x, 1.0);
        float slotGap  = u.p3.y;
        float segGap   = u.p3.z;
        float hScale   = u.p4.x;

        float3 col = backdrop(uv, aspect, u);

        // Which bar this pixel belongs to, and where inside its slot it sits.
        float xi = uv.x * float(n);
        int bi = clamp(int(floor(xi)), 0, n - 1);
        float fx = fract(xi);
        float dx = max(fwidth(xi), 1e-5);
        float halfGap = slotGap * 0.5;
        float xMask = smoothstep(halfGap - dx, halfGap + dx, fx) *
                      smoothstep(1.0 - halfGap + dx, 1.0 - halfGap - dx, fx);

        float d = baseY - uv.y;            // > 0 above the baseline
        float dAbs = abs(d);
        float dw = max(fwidth(dAbs), 1e-5);

        // Cell height comes from the *unscaled* span, so "peak height" stretches
        // the bars without resizing the LEDs.
        float segH = upH / segCount;
        float minLen = segH;               // every bar keeps its base cell lit
        float upLen = max(bars[bi] * upH * hScale, minLen);
        float dnLen = max(bars[bi] * dnH * hScale, minLen * 0.75) * mirrorOn;

        // LED cells, shared by the bar and its reflection so they stay in step.
        float s = dAbs / segH;
        float ds = max(fwidth(s), 1e-5);
        float lit = 1.0 - segGap;
        float segMask = segOn > 0.5
            ? 1.0 - smoothstep(lit - ds, lit + ds, fract(s))
            : 1.0;

        float upMask = smoothstep(upLen + dw, upLen - dw, dAbs) * step(0.0, d);
        float dnMask = smoothstep(dnLen + dw, dnLen - dw, dAbs) * step(0.0, -d);

        // Color ramps with absolute height, so equal heights read as equal
        // colors right across the frame. The ramp stretches with the bars, so a
        // taller setting does not wash every bar out to the top color.
        float3 barCol = mix(u.barLow.rgb, u.barHigh.rgb,
                            clamp(dAbs / max(upH * hScale, 1e-4), 0.0, 1.0));

        // Bloom first: it belongs *behind* the bars, spilling into the gaps and
        // fringing the tops rather than washing out the cells themselves.
        float halo = 0.0;
        for (int k = -2; k <= 2; ++k) {
            int j = clamp(bi + k, 0, n - 1);
            float len = max(bars[j] * upH * hScale, minLen);
            halo += exp(-abs(float(k)) * 1.2) * exp(-max(0.0, dAbs - len) * 55.0);
        }
        // Below the baseline the bloom belongs to the reflection, so it dims with
        // it — and vanishes entirely when the reflection is off.
        float side = d >= 0.0 ? 1.0 : 0.40 * mirrorOn;
        col += barCol * halo * glow * side * 0.055;

        // Peak cap, then the bar itself: painted *over* the backdrop, not added
        // to it, so a lit cell is its own color — the background can never show
        // through it or tint it. (Additive compositing made the bars read as
        // translucent over anything but pure black.)
        float capLo = max(bars[n + bi] * upH * hScale, minLen);
        float cap = step(capLo, dAbs) * step(dAbs, capLo + segH * 0.55) * xMask * step(0.0, d);
        col = mix(col, barCol * 0.70, cap);
        col = mix(col, barCol, upMask * segMask * xMask);

        // The reflection, on the other hand, *is* meant to be see-through: it
        // keeps a coverage below 1 and fades away with depth.
        col = mix(col, barCol, dnMask * segMask * xMask * exp(-dAbs * 2.6) * 0.60);

        // The bright line every bar stands on: a tight core plus a narrow wash.
        // Glows stay additive — they are light on top of the picture, not paint.
        col += u.accent.rgb * exp(-dAbs * 300.0) * (0.85 + 0.55 * level) * glow;
        col += u.accent.rgb * exp(-dAbs * 70.0) * 0.06 * glow;

        // Dither so the dark gradient does not band in an 8-bit codec.
        col += (hash21(uv * float2(u.p2.z, u.p2.w)) - 0.5) * (1.5 / 255.0);
        return float4(col, 1.0);
    }
    """
}
