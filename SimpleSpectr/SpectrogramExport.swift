//
//  SpectrogramExport.swift
//  SimpleSpectr
//
//  Serializes a computed `SpectrogramResult` into data files. The image export
//  (PNG, with/without axes) stays in `PNGExport.swift`; this file handles the
//  numeric exports — the dB grid as a CSV matrix or JSON, and session markers
//  as CSV.
//
//  All builders are pure `nonisolated` value-in / `Data`-out functions so they
//  can run off the main actor for large grids (up to ~2000 × 1024 cells).
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Options

/// What the user is exporting.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv          // dB grid as a freq × time matrix
    case json         // dB grid + analysis metadata
    case png          // rendered image (with or without axes)
    case markers      // session markers (time + label)

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .csv, .markers: return "csv"
        case .json:          return "json"
        case .png:           return "png"
        }
    }

    var utType: UTType {
        switch self {
        case .csv, .markers: return .commaSeparatedText
        case .json:          return .json
        case .png:           return .png
        }
    }

    /// Suffix appended to the source file's base name.
    var filenameSuffix: String {
        switch self {
        case .csv, .json: return "-spectrogram"
        case .png:        return "-spectrogram"
        case .markers:    return "-markers"
        }
    }

    /// Whether this format reads the numeric dB grid (so range / units /
    /// decimation / number-format controls apply).
    var usesGrid: Bool { self == .csv || self == .json }
}

/// Unit the magnitude cells are written in.
nonisolated enum ExportUnits: String, CaseIterable, Identifiable, Sendable {
    case decibels     // raw dB, exactly as shown on screen
    case linear       // amplitude: 10^(dB/20)
    case normalized   // 0…1 across the color scale's [minDB, maxDB]

    var id: String { rawValue }
}

nonisolated enum CSVDelimiter: String, CaseIterable, Identifiable, Sendable {
    case comma, semicolon, tab

    var id: String { rawValue }

    var character: String {
        switch self {
        case .comma:     return ","
        case .semicolon: return ";"
        case .tab:       return "\t"
        }
    }
}

nonisolated enum DecimalSeparator: String, CaseIterable, Identifiable, Sendable {
    case point, comma

    var id: String { rawValue }

    var character: String { self == .point ? "." : "," }
}

/// User-chosen export parameters, captured from the dialog.
nonisolated struct ExportOptions: Sendable {
    var format: ExportFormat = .csv
    var units: ExportUnits = .decibels
    var pngIncludesAxes: Bool = true

    /// Inclusive time window in seconds.
    var timeRange: ClosedRange<Double>
    /// Inclusive frequency window in Hz.
    var freqRange: ClosedRange<Double>

    /// Decimation caps: at most this many time columns / frequency bins are
    /// written (the grid is strided down to fit).
    var maxColumns: Int
    var maxBins: Int

    var delimiter: CSVDelimiter = .comma
    var decimal: DecimalSeparator = .point
    var precision: Int = 2
    var includeHeaders: Bool = true

    /// A comma value separator collides with a comma decimal mark; fall back to
    /// a semicolon so the file stays parseable.
    var effectiveDelimiter: String {
        if delimiter == .comma && decimal == .comma { return ";" }
        return delimiter.character
    }

    /// Analysis metadata for the JSON header (filled in by the caller from the
    /// live render settings, which match the loaded result).
    var windowFunction: String = ""
    var overlapPercent: Double = 0
    var sourceName: String = ""
}

// MARK: - Exporter

nonisolated enum SpectrogramExporter {

    // MARK: Grid index selection

    /// Time-column indices to export, after range clamp + decimation.
    static func columnIndices(_ result: SpectrogramResult, _ options: ExportOptions) -> [Int] {
        let cols = result.columns
        guard cols > 0 else { return [] }
        let dur = max(result.duration, .leastNonzeroMagnitude)
        let lo = clamp(Int((options.timeRange.lowerBound / dur * Double(cols)).rounded(.down)), 0, cols - 1)
        let hi = clamp(Int((options.timeRange.upperBound / dur * Double(cols)).rounded(.up)), lo, cols - 1)
        return stride(indicesFrom: lo, through: hi, cap: options.maxColumns)
    }

    /// Frequency-bin indices to export, after range clamp + decimation
    /// (ascending, low → high frequency).
    static func binIndices(_ result: SpectrogramResult, _ options: ExportOptions) -> [Int] {
        let bins = result.bins
        guard bins > 0 else { return [] }
        let nyq = max(result.maxFrequency, .leastNonzeroMagnitude)
        let lo = clamp(Int((options.freqRange.lowerBound / nyq * Double(bins)).rounded()), 0, bins - 1)
        let hi = clamp(Int((options.freqRange.upperBound / nyq * Double(bins)).rounded()), lo, bins - 1)
        return stride(indicesFrom: lo, through: hi, cap: options.maxBins)
    }

    /// Center time (seconds) of column `c`.
    static func time(forColumn c: Int, _ result: SpectrogramResult) -> Double {
        (Double(c) + 0.5) / Double(result.columns) * result.duration
    }

    /// Center frequency (Hz) of bin `b`.
    static func frequency(forBin b: Int, _ result: SpectrogramResult) -> Double {
        Double(b) * result.sampleRate / Double(result.fftSize)
    }

    // MARK: CSV (freq × time matrix)

    static func csvData(_ result: SpectrogramResult, _ options: ExportOptions) -> Data {
        let columns = columnIndices(result, options)
        // High frequency on top to match the on-screen orientation.
        let bins = binIndices(result, options).reversed()
        let sep = options.effectiveDelimiter
        let nl = "\n"

        var out = String()
        out.reserveCapacity(columns.count * (bins.count + 1) * 8 + 64)

        if options.includeHeaders {
            out += "frequency_Hz \\ time_s"
            for c in columns {
                out += sep
                out += number(time(forColumn: c, result), precision: 3, options)
            }
            out += nl
        }

        for b in bins {
            if options.includeHeaders {
                out += number(frequency(forBin: b, result), precision: 1, options)
                out += sep
            }
            let base = b
            var first = true
            for c in columns {
                if first { first = false } else { out += sep }
                let db = result.magnitudes[c * result.bins + base]
                out += number(value(db, result, options), precision: options.precision, options)
            }
            out += nl
        }

        return Data(out.utf8)
    }

    // MARK: JSON (grid + metadata)

    static func jsonData(_ result: SpectrogramResult, _ options: ExportOptions) -> Data {
        let columns = columnIndices(result, options)
        let bins = binIndices(result, options)

        let times = columns.map { time(forColumn: $0, result) }
        let frequencies = bins.map { frequency(forBin: $0, result) }
        // values[frequencyIndex][timeIndex], ascending frequency.
        let values: [[Double]] = bins.map { b in
            columns.map { c in
                rounded(value(result.magnitudes[c * result.bins + b], result, options),
                        precision: options.precision)
            }
        }

        let payload = ExportPayload(
            source: options.sourceName,
            sampleRate: result.sampleRate,
            fftSize: result.fftSize,
            windowFunction: options.windowFunction,
            overlapPercent: options.overlapPercent,
            units: options.units.rawValue,
            duration: result.duration,
            timeRange: [options.timeRange.lowerBound, options.timeRange.upperBound],
            frequencyRange: [options.freqRange.lowerBound, options.freqRange.upperBound],
            columns: columns.count,
            bins: bins.count,
            times: times.map { rounded($0, precision: 4) },
            frequencies: frequencies.map { rounded($0, precision: 2) },
            values: values)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(payload)) ?? Data()
    }

    private struct ExportPayload: Encodable {
        let source: String
        let sampleRate: Double
        let fftSize: Int
        let windowFunction: String
        let overlapPercent: Double
        let units: String
        let duration: Double
        let timeRange: [Double]
        let frequencyRange: [Double]
        let columns: Int
        let bins: Int
        let times: [Double]
        let frequencies: [Double]
        let values: [[Double]]
    }

    // MARK: Markers CSV

    static func markersData(_ markers: [(time: Double, label: String)], _ options: ExportOptions) -> Data {
        let sep = options.effectiveDelimiter
        var out = String()
        if options.includeHeaders {
            out += "time_s" + sep + "label\n"
        }
        for m in markers.sorted(by: { $0.time < $1.time }) {
            out += number(m.time, precision: 3, options)
            out += sep
            out += csvEscape(m.label, delimiter: sep)
            out += "\n"
        }
        return Data(out.utf8)
    }

    // MARK: Helpers

    private static func value(_ db: Float, _ result: SpectrogramResult, _ options: ExportOptions) -> Double {
        let d = Double(db)
        switch options.units {
        case .decibels:   return d
        case .linear:     return pow(10.0, d / 20.0)
        case .normalized:
            let span = result.maxDB - result.minDB
            guard span > 0 else { return 0 }
            return clampD((d - result.minDB) / span, 0, 1)
        }
    }

    private static func number(_ v: Double, precision: Int, _ options: ExportOptions) -> String {
        var s = String(format: "%.\(max(0, precision))f", v)
        if options.decimal == .comma { s = s.replacingOccurrences(of: ".", with: ",") }
        return s
    }

    private static func rounded(_ v: Double, precision: Int) -> Double {
        let f = pow(10.0, Double(max(0, precision)))
        return (v * f).rounded() / f
    }

    /// Wraps a marker label in quotes if it contains the delimiter, quotes or newlines.
    private static func csvEscape(_ s: String, delimiter: String) -> String {
        guard s.contains(delimiter) || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func stride(indicesFrom lo: Int, through hi: Int, cap: Int) -> [Int] {
        guard hi >= lo else { return [] }
        let count = hi - lo + 1
        let step = max(1, Int(ceil(Double(count) / Double(max(1, cap)))))
        return Swift.stride(from: lo, through: hi, by: step).map { $0 }
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
    private static func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}
