//
//  PNGExport.swift
//  SimpleSpectr
//
//  Wraps a CGImage as a PNG FileDocument for `.fileExporter`.
//

import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

struct PNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    static var writableContentTypes: [UTType] { [.png] }

    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }

    // Required by FileDocument; this document is export-only.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = PNGDocument.pngData(from: image) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Renders the spectrogram together with its frequency and time axes into a
    /// single `CGImage` for PNG export (native spectrogram resolution + axis insets).
    @MainActor
    static func compositeImage(for result: SpectrogramResult) -> CGImage? {
        var renderer = ImageRenderer(content: SpectrogramExportView(result: result))
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// Non-interactive spectrogram with frequency (left) and time (bottom) axes,
/// laid out exactly like the on-screen scene but without hover/readout chrome.
private struct SpectrogramExportView: View {
    let result: SpectrogramResult

    private let axisColor = Color(white: 0.6)
    private let leftInset: CGFloat = 56
    private let bottomInset: CGFloat = 28
    private let topInset: CGFloat = 8
    private let rightInset: CGFloat = 12

    var body: some View {
        let imgW = CGFloat(result.image.width)
        let imgH = CGFloat(result.image.height)
        let plot = CGRect(x: leftInset, y: topInset, width: imgW, height: imgH)

        ZStack(alignment: .topLeading) {
            Color(white: 0.07)

            Image(decorative: result.image, scale: 1.0)
                .resizable()
                .interpolation(.medium)
                .frame(width: imgW, height: imgH)
                .offset(x: plot.minX, y: plot.minY)

            axes(in: plot)
        }
        .frame(width: imgW + leftInset + rightInset,
               height: imgH + topInset + bottomInset)
    }

    @ViewBuilder
    private func axes(in plot: CGRect) -> some View {
        // Frequency labels (y axis) — high frequency at top, low at bottom.
        let freqTicks = 6
        ForEach(0...freqTicks, id: \.self) { i in
            let frac = Double(i) / Double(freqTicks)
            let y = plot.maxY - CGFloat(frac) * plot.height
            let hz = frac * result.maxFrequency
            Text(formatHz(hz))
                .font(.system(size: 9))
                .foregroundStyle(axisColor)
                .frame(width: leftInset - 8, alignment: .trailing)
                .position(x: (leftInset - 8) / 2, y: y)
        }

        // Time labels (x axis) — 0:00 at left, duration at right.
        let timeTicks = 6
        ForEach(0...timeTicks, id: \.self) { i in
            let frac = Double(i) / Double(timeTicks)
            let x = plot.minX + CGFloat(frac) * plot.width
            let t = frac * result.duration
            Text(formatDuration(t))
                .font(.system(size: 9))
                .foregroundStyle(axisColor)
                .position(x: x, y: plot.maxY + 14)
        }
    }

    private func formatHz(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.0fk", hz / 1000) : String(format: "%.0f", hz)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
