//
//  SpectrogramVideoExport.swift
//  SimpleSpectr
//
//  "3D flyover" video export. Renders the cached spectrogram as a moving 3D
//  landscape (SpectrogramVideoRenderer) and muxes it with the original audio via
//  AVAssetWriter into an .mp4 (H.264 up to 1080p, HEVC above) — a share-ready
//  clip for social media: the camera watches the track's spectrogram rise out of
//  the distance and flow past a glowing "now" line, in time with the music.
//

import Foundation
import AVFoundation
import CoreVideo
import simd

// MARK: - Options

/// Aspect ratio of the exported clip, framed for where it will be posted.
nonisolated enum VideoAspect: String, CaseIterable, Identifiable, Sendable {
    case landscape   // 16:9 — YouTube / desktop
    case vertical    // 9:16 — Reels / TikTok / Shorts
    case square      // 1:1  — feed posts

    var id: String { rawValue }
    @MainActor var displayName: String {
        switch self {
        case .landscape: return L("video.aspect.landscape")
        case .vertical:  return L("video.aspect.vertical")
        case .square:    return L("video.aspect.square")
        }
    }

    /// Landscape freq axis is wide; a vertical frame needs a narrower world so
    /// the spectrum still fits across the screen.
    var worldWidth: Float {
        switch self {
        case .landscape: return 4.7
        case .square:    return 3.7
        case .vertical:  return 2.9
        }
    }
}

/// Resolution tier. The short/long sides are derived per aspect ratio.
nonisolated enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case p720, p1080, p1440, p2160

    var id: String { rawValue }
    @MainActor var displayName: String {
        switch self {
        case .p720:  return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }
    /// The tier's reference (long-edge) size in pixels.
    var longEdge: Int {
        switch self {
        case .p720:  return 1280
        case .p1080: return 1920
        case .p1440: return 2560
        case .p2160: return 3840
        }
    }
}

/// Everything the exporter needs except the audio data itself.
nonisolated struct VideoExportOptions: Sendable {
    var aspect: VideoAspect = .vertical
    var quality: VideoQuality = .p1080
    var fps: Int32 = 60
    /// User-facing "drama" controls (0…1-ish multipliers).
    var heightExaggeration: Float = 1.0   // scales peak height
    var cameraTilt: Float = 0.5           // 0 = low & flat, 1 = high & steep
    var sway: Float = 0.35                // gentle camera drift
    var freqLines: Int = 220              // landscape frequency resolution

    // Backdrop layers. The palette-derived sky gradient is always on; these three
    // sit on top of it and can be switched off individually.
    var showStars = true
    var showGrid = true
    var pulseWithAudio = true

    /// Backdrop styling: palette colors from the snapshot, amounts from the user.
    func background(from snapshot: VideoGridSnapshot) -> FlyoverBackground {
        var bg = snapshot.background
        bg.stars = showStars ? 1 : 0
        bg.grid = showGrid ? 1 : 0
        bg.pulse = pulseWithAudio ? 1 : 0
        return bg
    }

    /// Output pixel size (even numbers), derived from aspect + quality.
    var pixelSize: (width: Int, height: Int) {
        let long = quality.longEdge
        func even(_ v: Double) -> Int { let i = Int(v.rounded()); return i - (i % 2) }
        let short = even(Double(long) * 9.0 / 16.0)   // the 16:9 short edge
        switch aspect {
        case .landscape: return (long, short)
        case .vertical:  return (short, long)
        case .square:    return (short, short)        // e.g. 1080 → 1080×1080
        }
    }

    /// HEVC above 1080p (better compression for big frames); H.264 otherwise.
    var codec: AVVideoCodecType {
        max(pixelSize.width, pixelSize.height) > 1920 ? .hevc : .h264
    }

    /// Target average bitrate (bits/s), scaled by pixels · fps.
    var bitrate: Int {
        let (w, h) = pixelSize
        let bpp = codec == .hevc ? 0.075 : 0.11
        return Int(Double(w * h) * Double(fps) * bpp)
    }

    /// Camera/landscape shape for the renderer, folding in the user controls.
    func camera() -> FlyoverCamera {
        var c = FlyoverCamera()
        c.worldWidth = aspect.worldWidth
        c.heightScale = 1.15 * max(0.2, heightExaggeration)
        // Tilt: higher & further back with a steeper look-down as it grows.
        c.cameraHeight = 1.05 + cameraTilt * 1.2
        c.cameraBack = 2.5 + cameraTilt * 0.9
        c.lookAheadZ = 8.0 - cameraTilt * 2.5
        c.lookY = 0.2 - cameraTilt * 0.35
        c.sway = max(0, min(1, sway))
        // A vertical frame sees further; push the fog back a little.
        if aspect == .vertical { c.fogStart = 7.5; c.fogEnd = 20.0 }
        return c
    }
}

// MARK: - Grid snapshot

/// Sendable snapshot of the cached spectrogram, taken on the main actor so the
/// export can run entirely in a detached task.
nonisolated struct VideoGridSnapshot: Sendable {
    let magnitudes: [Float]
    let columns: Int
    let bins: Int
    let minDB: Float
    let maxDB: Float
    let duration: Double
    let axis: FrequencyAxis
    let lutLinear: [SIMD3<Float>]        // 256-entry palette LUT in linear RGB
    /// Palette-derived backdrop colors (sky gradient + neon grid).
    let background: FlyoverBackground
    /// Per-column loudness 0…1, driving the backdrop pulse.
    let levels: [Float]

    @MainActor
    init(result: SpectrogramResult, palette: Palette) {
        magnitudes = result.magnitudes
        columns = result.columns
        bins = result.bins
        minDB = Float(result.minDB)
        maxDB = Float(result.maxDB)
        duration = result.duration
        axis = result.frequencyAxis
        let lut = palette.lut.map { Self.srgb8ToLinear($0) }
        lutLinear = lut

        // Derive the backdrop from the palette so the sky, the grid and the
        // terrain always read as one image. The dark end of the map becomes the
        // upper sky, a mid tone becomes the horizon glow, and a bright tone the
        // neon grid — each dimmed so the landscape stays the subject.
        var bg = FlyoverBackground()
        bg.skyTop = lut[24] * 0.30 + SIMD3<Float>(0.004, 0.004, 0.007)
        bg.skyBottom = lut[112] * 0.10 + SIMD3<Float>(0.006, 0.006, 0.012)
        bg.gridColor = lut[186] * 0.28
        background = bg

        levels = Self.levels(min: result.waveformMin, max: result.waveformMax)
    }

    /// Per-column loudness from the waveform envelope, normalized to the track's
    /// own peak and smoothed with a fast attack / slow release so the pulse feels
    /// like a beat rather than a flicker.
    private static func levels(min mins: [Float], max maxs: [Float]) -> [Float] {
        let n = Swift.min(mins.count, maxs.count)
        guard n > 0 else { return [] }
        var raw = [Float](repeating: 0, count: n)
        var peak: Float = 1e-6
        for i in 0..<n {
            let a = Swift.max(abs(mins[i]), abs(maxs[i]))
            raw[i] = a
            if a > peak { peak = a }
        }
        // Normalize, then shape with a square root so quiet passages still move.
        var out = [Float](repeating: 0, count: n)
        var env: Float = 0
        for i in 0..<n {
            let v = (raw[i] / peak).squareRoot()
            env = v > env ? env + (v - env) * 0.45 : env + (v - env) * 0.06
            out[i] = Swift.min(Swift.max(env, 0), 1)
        }
        return out
    }

    /// Interpolated loudness at a 0…1 position along the track.
    func level(atProgress p: Float) -> Float {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let x = min(max(p, 0), 1) * Float(levels.count - 1)
        let i = Int(x)
        let j = min(i + 1, levels.count - 1)
        let f = x - Float(i)
        return levels[i] + (levels[j] - levels[i]) * f
    }

    private static func srgb8ToLinear(_ c: (UInt8, UInt8, UInt8)) -> SIMD3<Float> {
        func lin(_ v: UInt8) -> Float {
            let s = Float(v) / 255.0
            return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4)
        }
        return SIMD3<Float>(lin(c.0), lin(c.1), lin(c.2))
    }
}

// MARK: - Exporter

nonisolated enum VideoExportError: LocalizedError {
    case writerSetup(String)
    case noPixelBufferPool
    case pixelBufferAlloc
    case cancelled
    case appendFailed

    var errorDescription: String? {
        switch self {
        case .writerSetup(let m): return L("video.error.writer", m)
        case .noPixelBufferPool:  return L("video.error.pool")
        case .pixelBufferAlloc:   return L("video.error.pool")
        case .cancelled:          return L("video.error.cancelled")
        case .appendFailed:       return L("video.error.append")
        }
    }
}

nonisolated enum SpectrogramVideoExporter {

    /// Render + mux the flyover clip to `outputURL`.
    /// - Parameters:
    ///   - progress: called (off-main) with 0…1 as frames are written.
    ///   - isCancelled: polled between frames to allow a user cancel.
    static func export(snapshot: VideoGridSnapshot,
                       options: VideoExportOptions,
                       sourceURL: URL,
                       outputURL: URL,
                       progress: @escaping @Sendable (Double) -> Void,
                       isCancelled: @escaping @Sendable () -> Bool) async throws {
        let (width, height) = options.pixelSize
        let fps = max(Int32(1), options.fps)
        let camera = options.camera()
        let background = options.background(from: snapshot)

        // Build the landscape mesh from the cached grid.
        let mesh = SpectroMesh.build(magnitudes: snapshot.magnitudes,
                                     columns: snapshot.columns,
                                     bins: snapshot.bins,
                                     minDB: snapshot.minDB,
                                     maxDB: snapshot.maxDB,
                                     freqLines: options.freqLines,
                                     axis: snapshot.axis,
                                     lut: snapshot.lutLinear,
                                     camera: camera)
        try Task.checkCancellation()

        let renderer = try SpectrogramVideoRenderer(width: width, height: height)
        renderer.upload(mesh: mesh)

        // Remove any stale file so the writer can create a fresh one.
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw VideoExportError.writerSetup(error.localizedDescription)
        }

        // --- Video input ---------------------------------------------------------
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoExportError.writerSetup("cannot add video input") }
        writer.add(videoInput)

        let pbAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: pbAttributes)

        // --- Audio input (AAC, normalized to 44.1 kHz stereo) --------------------
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let audioAsset = AVURLAsset(url: sourceURL)
        let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first
        var audioInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioReaderOutput: AVAssetReaderTrackOutput?

        if let audioTrack {
            // Build the reader first; only wire up the writer's audio input if the
            // whole chain is valid, so we never leave an unfinished input dangling.
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            out.alwaysCopiesSampleData = false
            if let reader = try? AVAssetReader(asset: audioAsset), reader.canAdd(out) {
                let aacSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                aInput.expectsMediaDataInRealTime = false
                if writer.canAdd(aInput) {
                    reader.add(out)
                    writer.add(aInput)
                    audioInput = aInput
                    audioReader = reader
                    audioReaderOutput = out
                }
            }
        }

        // --- Start ---------------------------------------------------------------
        guard writer.startWriting() else {
            throw VideoExportError.writerSetup(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        if audioReader?.startReading() == false {
            // Reader refused to start — drop the audio track rather than stall the
            // muxer waiting for samples that will never arrive.
            audioInput?.markAsFinished()
            audioInput = nil
            audioReaderOutput = nil
            audioReader = nil
        }

        // --- Interleaved audio pump ---------------------------------------------
        // With two inputs, AVAssetWriter expects roughly interleaved media: if the
        // video races ahead while the audio input stays empty, the writer stops
        // accepting video frames (`isReadyForMoreMediaData` latches false) and the
        // export deadlocks. So audio is pushed alongside the frames, kept a small
        // lead ahead of the video clock.
        var audioFinished = (audioInput == nil)
        var heldSample: CMSampleBuffer?

        func pumpAudio(upTo videoTime: Double) {
            guard let aInput = audioInput, let aOut = audioReaderOutput, !audioFinished else { return }
            while aInput.isReadyForMoreMediaData {
                let next: CMSampleBuffer?
                if let held = heldSample {
                    next = held
                    heldSample = nil
                } else {
                    next = aOut.copyNextSampleBuffer()
                }
                guard let sample = next else {
                    aInput.markAsFinished()
                    audioFinished = true
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                // Hold anything more than a second ahead of the video until the
                // frames catch up, so neither track starves the other.
                if pts.isFinite && pts > videoTime + 1.0 {
                    heldSample = sample
                    return
                }
                aInput.append(sample)
            }
        }

        // --- Video frames --------------------------------------------------------
        let totalFrames = max(1, Int((snapshot.duration * Double(fps)).rounded()))
        for frame in 0..<totalFrames {
            if isCancelled() {
                writer.cancelWriting()
                audioReader?.cancelReading()
                throw VideoExportError.cancelled
            }
            // Back-pressure: wait until the encoder can take more, feeding audio
            // meanwhile — the writer will not free the video input until the audio
            // track keeps up.
            let frameTime = Double(frame) / Double(fps)
            pumpAudio(upTo: frameTime)
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 4_000_000)
                pumpAudio(upTo: frameTime)
                if isCancelled() { writer.cancelWriting(); throw VideoExportError.cancelled }
            }
            guard let pool = adaptor.pixelBufferPool else { throw VideoExportError.noPixelBufferPool }
            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess,
                  let pixelBuffer = pbOut else {
                throw VideoExportError.pixelBufferAlloc
            }

            let t = Double(frame) / Double(fps)
            let p = Float(min(1.0, t / max(snapshot.duration, 1e-6)))
            try renderer.render(into: pixelBuffer,
                                mesh: mesh,
                                camera: camera,
                                background: background,
                                progress: p,
                                time: Float(t),
                                level: snapshot.level(atProgress: p))

            let pts = CMTime(value: CMTimeValue(frame), timescale: fps)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                // `writer.error` carries the real reason (unsupported size, codec
                // refusal…); surface it instead of a bare "frame rejected".
                let reason = writer.error?.localizedDescription
                writer.cancelWriting()
                audioReader?.cancelReading()
                throw reason.map { VideoExportError.writerSetup($0) } ?? VideoExportError.appendFailed
            }
            // Video is ~92% of the reported work; audio mux gets the tail.
            progress(0.92 * Double(frame + 1) / Double(totalFrames))
        }
        videoInput.markAsFinished()

        // --- Drain the remaining audio ------------------------------------------
        while !audioFinished {
            if isCancelled() {
                writer.cancelWriting()
                audioReader?.cancelReading()
                throw VideoExportError.cancelled
            }
            // No video left to pace against, so take everything that's ready.
            pumpAudio(upTo: .greatestFiniteMagnitude)
            if !audioFinished { try await Task.sleep(nanoseconds: 4_000_000) }
        }
        progress(0.97)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed {
            throw VideoExportError.writerSetup(writer.error?.localizedDescription ?? "finishWriting failed")
        }
        if isCancelled() { throw VideoExportError.cancelled }
        progress(1.0)
    }
}
