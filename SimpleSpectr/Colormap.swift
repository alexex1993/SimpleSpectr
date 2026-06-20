//
//  Colormap.swift
//  SimpleSpectr
//
//  "Inferno" perceptual colormap, interpolated from anchor colors.
//

import Foundation

enum Colormap {
    // Anchor colors sampled along matplotlib's "inferno".
    private static let anchors: [(Float, Float, Float)] = [
        (0,   0,   4),
        (40,  11,  84),
        (101, 21,  110),
        (159, 42,  99),
        (212, 72,  66),
        (245, 125, 21),
        (250, 193, 39),
        (252, 255, 164),
    ]

    /// Map a value in [0, 1] to an RGB triple.
    static func inferno(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let clamped = min(max(t, 0), 1)
        let segments = anchors.count - 1
        let scaled = clamped * Float(segments)
        let idx = min(Int(scaled), segments - 1)
        let frac = scaled - Float(idx)
        let a = anchors[idx]
        let b = anchors[idx + 1]
        let r = a.0 + (b.0 - a.0) * frac
        let g = a.1 + (b.1 - a.1) * frac
        let bl = a.2 + (b.2 - a.2) * frac
        return (UInt8(r.rounded()), UInt8(g.rounded()), UInt8(bl.rounded()))
    }
}
