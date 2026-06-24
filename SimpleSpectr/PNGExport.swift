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
        let renderer = ImageRenderer(content: SpectrogramExportView(result: result))
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// Non-interactive spectrogram with frequency (left) and time (bottom) axes,
/// laid out exactly like the on-screen scene but without hover/readout chrome.
private struct SpectrogramExportView: View {
    let result: SpectrogramResult

    var body: some View {
        let imgW = CGFloat(result.image.width)
        let imgH = CGFloat(result.image.height)
        let plot = CGRect(x: SpectrogramPlot.leftInset, y: SpectrogramPlot.topInset,
                          width: imgW, height: imgH)

        ZStack(alignment: .topLeading) {
            Color(white: 0.07)

            Image(decorative: result.image, scale: 1.0)
                .resizable()
                .interpolation(.medium)
                .frame(width: imgW, height: imgH)
                .offset(x: plot.minX, y: plot.minY)

            SpectrogramAxes(result: result, plot: plot)
        }
        .frame(width: imgW + SpectrogramPlot.leftInset + SpectrogramPlot.rightInset,
               height: imgH + SpectrogramPlot.topInset + SpectrogramPlot.bottomInset)
    }
}
