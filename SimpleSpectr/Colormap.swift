//
//  Colormap.swift
//  SimpleSpectr
//
//  "Inferno" perceptual colormap, interpolated in Oklab space and baked into a LUT.
//

import Foundation

enum Colormap {
    // Anchor colors sampled along matplotlib's "inferno" (8-bit sRGB).
    private static let anchors: [(Double, Double, Double)] = [
        (0,   0,   4),
        (40,  11,  84),
        (101, 21,  110),
        (159, 42,  99),
        (212, 72,  66),
        (245, 125, 21),
        (250, 193, 39),
        (252, 255, 164),
    ]

    // Same anchors converted to Oklab once, so per-pixel interpolation is perceptual.
    private static let anchorsLab: [(Double, Double, Double)] = anchors.map { srgbToOklab($0) }

    // 256-entry RGB lookup table, computed once.
    private static let lut: [(UInt8, UInt8, UInt8)] = {
        (0..<256).map { i in oklabToSRGB8(sampleLab(Double(i) / 255.0)) }
    }()

    /// Map an index in 0…255 to an RGB triple.
    static func infernoLUT(_ index: Int) -> (UInt8, UInt8, UInt8) {
        return lut[min(max(index, 0), 255)]
    }

    private static func sampleLab(_ t: Double) -> (Double, Double, Double) {
        let segments = anchorsLab.count - 1
        let scaled = min(max(t, 0), 1) * Double(segments)
        let idx = min(Int(scaled), segments - 1)
        let frac = scaled - Double(idx)
        let a = anchorsLab[idx]
        let b = anchorsLab[idx + 1]
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
