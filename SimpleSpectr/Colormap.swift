//
//  Colormap.swift
//  SimpleSpectr
//
//  Perceptual colormaps, interpolated in Oklab space and baked into LUTs.
//  "Inferno" is the app default; the others are selectable in Settings.
//

import Foundation
import SwiftUI

/// Selectable spectrogram colormap. Each case is backed by 8-bit sRGB anchor
/// colors that are interpolated in Oklab space into a 256-entry LUT.
nonisolated enum Palette: String, CaseIterable, Identifiable, Sendable {
    case inferno     // default
    case viridis
    case magma
    case plasma
    case turbo
    case cividis
    case jet
    case hot
    case grayscale

    var id: String { rawValue }

    /// Whether this is the factory default (shown with a "Default" caption).
    var isDefault: Bool { self == .inferno }

    /// Display name — scientific colormap names are kept as proper nouns.
    @MainActor var displayName: String {
        switch self {
        case .inferno:   return "Inferno"
        case .viridis:   return "Viridis"
        case .magma:     return "Magma"
        case .plasma:    return "Plasma"
        case .turbo:     return "Turbo"
        case .cividis:   return "Cividis"
        case .jet:       return "Jet"
        case .hot:       return "Hot"
        case .grayscale: return L("palette.grayscale")
        }
    }

    /// Anchor colors sampled along each colormap (8-bit sRGB).
    private var anchors: [(Double, Double, Double)] {
        switch self {
        case .inferno:
            return [
                (0,   0,   4),
                (40,  11,  84),
                (101, 21,  110),
                (159, 42,  99),
                (212, 72,  66),
                (245, 125, 21),
                (250, 193, 39),
                (252, 255, 164),
            ]
        case .viridis:
            return [
                (68,  1,   84),
                (71,  40,  120),
                (62,  74,  137),
                (49,  104, 142),
                (38,  130, 142),
                (31,  158, 137),
                (53,  183, 121),
                (109, 205, 89),
                (180, 222, 44),
                (253, 231, 37),
            ]
        case .magma:
            return [
                (0,   0,   4),
                (28,  16,  68),
                (79,  18,  123),
                (129, 37,  129),
                (181, 54,  122),
                (229, 80,  100),
                (251, 135, 97),
                (254, 194, 135),
                (252, 253, 191),
            ]
        case .plasma:
            return [
                (13,  8,   135),
                (75,  3,   161),
                (125, 3,   168),
                (168, 34,  150),
                (203, 70,  121),
                (229, 107, 93),
                (248, 148, 65),
                (253, 195, 40),
                (240, 249, 33),
            ]
        case .turbo:
            return [
                (48,  18,  59),
                (70,  93,  211),
                (33,  168, 221),
                (28,  213, 169),
                (109, 235, 89),
                (202, 226, 50),
                (253, 165, 49),
                (232, 78,  27),
                (122, 4,   3),
            ]
        case .cividis:
            // Evenly sampled from matplotlib's _cividis_data so the high end
            // is the proper saturated yellow, not a washed-out cream.
            return [
                (0,   34,  78),
                (18,  53,  112),
                (67,  78,  108),
                (139, 135, 120),
                (192, 177, 106),
                (229, 211, 79),
                (247, 225, 56),
                (254, 230, 54),
                (254, 232, 56),
            ]
        case .jet:
            // Classic MATLAB rainbow, the historical spectrogram colormap.
            // Sampled at even intervals from matplotlib's piecewise `jet`.
            return [
                (0,   0,   128),
                (0,   0,   243),
                (0,   77,  255),
                (0,   179, 255),
                (41,  255, 206),
                (123, 255, 123),
                (206, 255, 41),
                (255, 198, 0),
                (255, 104, 0),
                (243, 9,   0),
                (128, 0,   0),
            ]
        case .hot:
            // Black → red → yellow → white (matplotlib `hot`), sampled evenly.
            return [
                (0,   0,   0),
                (70,  0,   0),
                (140, 0,   0),
                (210, 0,   0),
                (255, 23,  0),
                (255, 90,  0),
                (255, 157, 0),
                (255, 224, 0),
                (255, 255, 54),
                (255, 255, 155),
                (255, 255, 255),
            ]
        case .grayscale:
            return [
                (15,  15,  15),
                (255, 255, 255),
            ]
        }
    }

    // 256-entry RGB lookup table for this palette, computed once per case.
    var lut: [(UInt8, UInt8, UInt8)] { Self.allLUTs[self]! }

    /// Map an index in 0…255 to an RGB triple.
    func sample(_ index: Int) -> (UInt8, UInt8, UInt8) {
        lut[min(max(index, 0), 255)]
    }

    /// SwiftUI gradient stops sampled from the LUT, for live previews.
    func gradientColors(count: Int = 32) -> [Color] {
        let n = max(2, count)
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1) * 255.0
            let (r, g, b) = sample(Int(t))
            return Color(red: Double(r) / 255.0,
                         green: Double(g) / 255.0,
                         blue: Double(b) / 255.0)
        }
    }

    // All LUTs built once, thread-safely, at first access.
    private static let allLUTs: [Palette: [(UInt8, UInt8, UInt8)]] = {
        var dict: [Palette: [(UInt8, UInt8, UInt8)]] = [:]
        for p in Palette.allCases {
            let lab = p.anchors.map { srgbToOklab($0) }
            dict[p] = (0..<256).map { i in oklabToSRGB8(sampleLab(Double(i) / 255.0, lab: lab)) }
        }
        return dict
    }()

    private static func sampleLab(_ t: Double, lab: [(Double, Double, Double)]) -> (Double, Double, Double) {
        let segments = lab.count - 1
        let scaled = min(max(t, 0), 1) * Double(segments)
        let idx = min(Int(scaled), segments - 1)
        let frac = scaled - Double(idx)
        let a = lab[idx]
        let b = lab[idx + 1]
        return (a.0 + (b.0 - a.0) * frac,
                a.1 + (b.1 - a.1) * frac,
                a.2 + (b.2 - a.2) * frac)
    }

    // MARK: - Oklab ↔ sRGB (Björn Ottosson)

    private static func srgbToOklab(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let r = srgbToLinear(rgb.0 / 255.0)
        let g = srgbToLinear(rgb.1 / 255.0)
        let bl = srgbToLinear(rgb.2 / 255.0)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    private static func oklabToSRGB8(_ lab: (Double, Double, Double)) -> (UInt8, UInt8, UInt8) {
        let l_ = lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2
        let m_ = lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2
        let s_ = lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (to255(r), to255(g), to255(b))
    }

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    private static func to255(_ linear: Double) -> UInt8 {
        let v = linearToSRGB(min(max(linear, 0), 1)) * 255.0
        return UInt8(min(max(v.rounded(), 0), 255))
    }
}
