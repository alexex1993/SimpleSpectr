//
//  AudioFileInfo.swift
//  SimpleSpectr
//
//  Lightweight container metadata for the loaded audio file, shown in the
//  "File Info" popover. Read from the *source* file format (not the Float32
//  processing format) plus the file system, so it reflects the real codec,
//  sample rate, bit depth and bitrate the user cares about.
//

import Foundation
import AVFoundation
import AudioToolbox

struct AudioFileInfo: Sendable {
    var sampleRate: Double      // Hz (source)
    var channels: Int
    var bitDepth: Int?          // bits per sample for PCM; nil for compressed codecs
    var codec: String           // human-readable codec name (e.g. "MP3", "Linear PCM")
    var bitrate: Double?        // bits per second (file size derived if not intrinsic)
    var fileSize: Int64?        // bytes
    var duration: Double        // seconds

    /// Read metadata for the file at `url`. Performs its own security-scoped
    /// access (the app is sandboxed), so it is safe to call independently of the
    /// spectrogram engine. Returns `nil` if the file cannot be opened.
    static func load(url: URL) -> AudioFileInfo? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let format = file.fileFormat      // the *source* format, not processingFormat
        let asbd = format.streamDescription.pointee
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let frames = file.length
        let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64

        // Bit depth only applies to (integer or float) PCM. For compressed
        // formats mBitsPerChannel is 0 — report nil there.
        let bitDepth: Int? = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil

        // Bitrate: prefer the encoder's nominal value, otherwise derive from the
        // file size and duration (good enough for a metadata readout).
        let bitrate: Double? = {
            if duration > 0, let size = fileSize {
                return Double(size) * 8 / duration
            }
            return nil
        }()

        return AudioFileInfo(sampleRate: sampleRate,
                             channels: channels,
                             bitDepth: bitDepth,
                             codec: codecName(formatID: asbd.mFormatID),
                             bitrate: bitrate,
                             fileSize: fileSize,
                             duration: duration)
    }

    /// Maps a Core Audio format ID to a short readable codec name.
    private static func codecName(formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatLinearPCM:       return "Linear PCM"
        case kAudioFormatMPEGLayer1:      return "MP1"
        case kAudioFormatMPEGLayer2:      return "MP2"
        case kAudioFormatMPEGLayer3:      return "MP3"
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:    return "AAC"
        case kAudioFormatAppleLossless:   return "Apple Lossless"
        case kAudioFormatFLAC:            return "FLAC"
        case kAudioFormatOpus:            return "Opus"
        case kAudioFormatAC3:             return "AC-3"
        case kAudioFormatAppleIMA4:       return "IMA 4:1"
        case kAudioFormatALaw:            return "A-law"
        case kAudioFormatULaw:            return "µ-law"
        default:
            // Fall back to the 4-char code (e.g. " in24") so unknown formats are
            // still identifiable rather than blank.
            return fourCharString(formatID)
        }
    }

    private static func fourCharString(_ code: AudioFormatID) -> String {
        let bytes = [UInt8(truncatingIfNeeded: code >> 24),
                     UInt8(truncatingIfNeeded: code >> 16),
                     UInt8(truncatingIfNeeded: code >> 8),
                     UInt8(truncatingIfNeeded: code)]
        let scalars = bytes.filter { $0 >= 0x20 && $0 < 0x7F }
        let s = String(bytes: scalars, encoding: .ascii) ?? ""
        return s.isEmpty ? String(format: "0x%08X", code) : s.trimmingCharacters(in: .whitespaces)
    }
}
