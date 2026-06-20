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
}
