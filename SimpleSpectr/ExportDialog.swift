//
//  ExportDialog.swift
//  SimpleSpectr
//
//  The unified export sheet. Replaces the old one-shot "Save PNG" panel: the
//  user picks a format (CSV / JSON / PNG / Markers), tunes the relevant
//  parameters (range, units, decimation, number format, axes), then a native
//  save panel writes the file. Image rendering reuses `PNGExport.swift`; numeric
//  serialization is in `SpectrogramExport.swift`.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportDialog: View {
    let sourceName: String
    let result: SpectrogramResult
    let markers: [(time: Double, label: String)]
    let onClose: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var options: ExportOptions
    @State private var errorMessage: String?
    @State private var isWriting = false

    init(sourceName: String,
         result: SpectrogramResult,
         markers: [(time: Double, label: String)],
         windowFunction: String,
         overlapPercent: Double,
         onClose: @escaping () -> Void) {
        self.sourceName = sourceName
        self.result = result
        self.markers = markers
        self.onClose = onClose
        var opts = ExportOptions(timeRange: 0...max(result.duration, 0.001),
                                 freqRange: 0...max(result.maxFrequency, 1),
                                 maxColumns: result.columns,
                                 maxBins: result.bins)
        opts.windowFunction = windowFunction
        opts.overlapPercent = overlapPercent
        opts.sourceName = sourceName
        _options = State(initialValue: opts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("export.title"))
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Form {
                formatSection
                if options.format == .png {
                    pngSection
                } else if options.format.usesGrid {
                    gridSection
                    rangeSection
                    numberSection
                } else if options.format == .markers {
                    markersSection
                }
            }
            .formStyle(.grouped)
            .frame(height: 360)

            Divider()

            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button(L("export.cancel"), role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(L("export.export")) { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWriting || !canExport)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
    }

    // MARK: Sections

    private var formatSection: some View {
        Section {
            Picker(L("export.format"), selection: $options.format) {
                Text(L("export.format.csv")).tag(ExportFormat.csv)
                Text(L("export.format.json")).tag(ExportFormat.json)
                Text(L("export.format.png")).tag(ExportFormat.png)
                Text(L("export.format.markers")).tag(ExportFormat.markers)
            }
            .pickerStyle(.menu)
        }
    }

    private var pngSection: some View {
        Section {
            Toggle(L("export.png.axes"), isOn: $options.pngIncludesAxes)
        } footer: {
            Text(L("export.png.axesHint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var gridSection: some View {
        Section(L("export.dataSection")) {
            Picker(L("export.units"), selection: $options.units) {
                Text(L("export.units.db")).tag(ExportUnits.decibels)
                Text(L("export.units.linear")).tag(ExportUnits.linear)
                Text(L("export.units.normalized")).tag(ExportUnits.normalized)
            }
            Stepper(value: $options.maxColumns, in: 1...result.columns, step: stepFor(result.columns)) {
                LabeledContent(L("export.maxColumns"), value: "\(min(options.maxColumns, result.columns))")
            }
            Stepper(value: $options.maxBins, in: 1...result.bins, step: stepFor(result.bins)) {
                LabeledContent(L("export.maxBins"), value: "\(min(options.maxBins, result.bins))")
            }
            LabeledContent(L("export.cellCount"), value: cellCountText)
                .foregroundStyle(.secondary)
        }
    }

    private var rangeSection: some View {
        Section(L("export.rangeSection")) {
            rangeRow(L("export.timeFrom"), L("export.timeTo"),
                     lower: timeLowerBinding, upper: timeUpperBinding, unit: "s")
            rangeRow(L("export.freqFrom"), L("export.freqTo"),
                     lower: freqLowerBinding, upper: freqUpperBinding, unit: "Hz")
            Button(L("export.resetRange")) {
                options.timeRange = 0...max(result.duration, 0.001)
                options.freqRange = 0...max(result.maxFrequency, 1)
            }
            .controlSize(.small)
        }
    }

    private var numberSection: some View {
        Section(L("export.numberSection")) {
            if options.format == .csv {
                Picker(L("export.delimiter"), selection: $options.delimiter) {
                    Text(L("export.delimiter.comma")).tag(CSVDelimiter.comma)
                    Text(L("export.delimiter.semicolon")).tag(CSVDelimiter.semicolon)
                    Text(L("export.delimiter.tab")).tag(CSVDelimiter.tab)
                }
            }
            Picker(L("export.decimal"), selection: $options.decimal) {
                Text(L("export.decimal.point")).tag(DecimalSeparator.point)
                Text(L("export.decimal.comma")).tag(DecimalSeparator.comma)
            }
            Stepper(value: $options.precision, in: 0...6) {
                LabeledContent(L("export.precision"), value: "\(options.precision)")
            }
            if options.format == .csv {
                Toggle(L("export.headers"), isOn: $options.includeHeaders)
            }
        }
    }

    private var markersSection: some View {
        Section(L("export.markersSection")) {
            LabeledContent(L("export.markersCount"), value: "\(markers.count)")
                .foregroundStyle(.secondary)
            Picker(L("export.decimal"), selection: $options.decimal) {
                Text(L("export.decimal.point")).tag(DecimalSeparator.point)
                Text(L("export.decimal.comma")).tag(DecimalSeparator.comma)
            }
            Toggle(L("export.headers"), isOn: $options.includeHeaders)
        }
    }

    private func rangeRow(_ fromLabel: String, _ toLabel: String,
                          lower: Binding<Double>, upper: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(fromLabel).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            TextField("", value: lower, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
            Text(toLabel).foregroundStyle(.secondary)
            TextField("", value: upper, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Bindings (clamped)

    private var timeLowerBinding: Binding<Double> {
        Binding(get: { options.timeRange.lowerBound },
                set: { v in
                    let lo = min(max(0, v), options.timeRange.upperBound)
                    options.timeRange = lo...options.timeRange.upperBound
                })
    }
    private var timeUpperBinding: Binding<Double> {
        Binding(get: { options.timeRange.upperBound },
                set: { v in
                    let hi = min(max(options.timeRange.lowerBound, v), result.duration)
                    options.timeRange = options.timeRange.lowerBound...max(hi, options.timeRange.lowerBound)
                })
    }
    private var freqLowerBinding: Binding<Double> {
        Binding(get: { options.freqRange.lowerBound },
                set: { v in
                    let lo = min(max(0, v), options.freqRange.upperBound)
                    options.freqRange = lo...options.freqRange.upperBound
                })
    }
    private var freqUpperBinding: Binding<Double> {
        Binding(get: { options.freqRange.upperBound },
                set: { v in
                    let hi = min(max(options.freqRange.lowerBound, v), result.maxFrequency)
                    options.freqRange = options.freqRange.lowerBound...max(hi, options.freqRange.lowerBound)
                })
    }

    // MARK: Derived

    private var canExport: Bool {
        options.format != .markers || !markers.isEmpty
    }

    private var cellCountText: String {
        let cols = SpectrogramExporter.columnIndices(result, options).count
        let bins = SpectrogramExporter.binIndices(result, options).count
        return "\(cols) × \(bins) = \(cols * bins)"
    }

    private func stepFor(_ total: Int) -> Int { max(1, total / 20) }

    private var defaultFilename: String {
        let base = (sourceName as NSString).deletingPathExtension
        let stem = base.isEmpty ? "spectrogram" : base
        return stem + options.format.filenameSuffix + "." + options.format.fileExtension
    }

    // MARK: Export

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format.utType]
        panel.nameFieldStringValue = defaultFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        errorMessage = nil
        isWriting = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                isWriting = false
                return
            }
            Task { await write(to: url) }
        }
    }

    private func write(to url: URL) async {
        let opts = options
        let res = result
        let mk = markers
        do {
            let data: Data
            switch opts.format {
            case .png:
                // ImageRenderer / CGImage work must stay on the main actor.
                let cg = opts.pngIncludesAxes
                    ? (PNGDocument.compositeImage(for: res) ?? res.image)
                    : res.image
                guard let png = PNGDocument.pngData(from: cg) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                data = png
            case .csv:
                data = await Task.detached { SpectrogramExporter.csvData(res, opts) }.value
            case .json:
                data = await Task.detached { SpectrogramExporter.jsonData(res, opts) }.value
            case .markers:
                data = await Task.detached { SpectrogramExporter.markersData(mk, opts) }.value
            }
            try data.write(to: url, options: .atomic)
            isWriting = false
            onClose()
        } catch {
            isWriting = false
            errorMessage = error.localizedDescription
        }
    }
}
