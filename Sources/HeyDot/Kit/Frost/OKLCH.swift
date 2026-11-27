import Foundation

/// OKLCH (Björn Ottosson's OKLab in polar form), for hue and chroma that match how colours look.
struct OKLCH: Equatable {
    var l: Double, c: Double, h: Double

    init(l: Double, c: Double, h: Double) { self.l = l; self.c = c; self.h = OKLCH.wrap(h) }

    init(hex: UInt32) {
        func lin(_ v: UInt32) -> Double {
            let x = Double(v & 0xFF) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (lin(hex >> 16), lin(hex >> 8), lin(hex))
        let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        let a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        let bb = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
        self.init(l: L, c: (a * a + bb * bb).squareRoot(), h: atan2(bb, a) * 180 / .pi)
    }

    /// Linear sRGB, unclamped.
    var linear: (Double, Double, Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
    }

    var inGamut: Bool { let (r, g, b) = linear; return [r, g, b].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 } }

    /// The colour as sRGB hex, with chroma reduced (hue and lightness kept) until it fits.
    var hexInGamut: UInt32 {
        var color = self
        if !color.inGamut {
            var lo = 0.0, hi = c
            for _ in 0..<30 { let mid = (lo + hi) / 2; color.c = mid; if color.inGamut { lo = mid } else { hi = mid } }
            color.c = lo
        }
        let (r, g, b) = color.linear
        func byte(_ v: Double) -> UInt32 {
            let x = max(0, min(1, v))
            return UInt32(((x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055) * 255).rounded())
        }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    static func wrap(_ h: Double) -> Double { let x = h.truncatingRemainder(dividingBy: 360); return x < 0 ? x + 360 : x }
    static func hueDistance(_ a: Double, _ b: Double) -> Double { let d = abs(wrap(a) - wrap(b)); return min(d, 360 - d) }
}
