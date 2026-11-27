import Foundation

/// Colour rules for the accent (DESIGN.md, "Theme from dot"): the pill fill, the label on it, marks drawn on the
/// window, and the contrast maths behind them.
enum Accent {
    static let defaultHex: UInt32 = 0xFB817A  // the logo's coral
    static let darkWindow: UInt32 = 0x1E1E1E
    static let lightWindow: UInt32 = 0xF2F2F5
    /// Relative luminance band that meets both contrast floors.
    static let band: ClosedRange<Double> = 0.145...0.183

    /// The accent for marks drawn on the window (rings, progress, level bars, ticks, focus): the same hue moved in
    /// OKLCH lightness only as far as 3:1 against the window needs. Lime deepens a little on a light window, a
    /// near-black lightens on a dark one, and most colours stay as they are.
    static func mark(_ hex: UInt32, dark: Bool) -> UInt32 {
        let window = dark ? darkWindow : lightWindow
        guard contrast(hex, window) < markContrast else { return hex }
        return toward(hex, window: window, contrast: markContrast + 0.05)
    }
    static let markContrast = 3.0

    /// The pill fill: the colour itself, nudged in lightness only when it would vanish into a window: under 1.15:1
    /// against the light window (white, near-white; the glass edge carries lime and yellow), under 1.3:1 against
    /// the dark one (black, near-black).
    static func pill(_ hex: UInt32) -> UInt32 {
        var fill = hex
        if contrast(fill, lightWindow) < 1.15 { fill = toward(fill, window: lightWindow, contrast: 1.2) }
        if contrast(fill, darkWindow) < 1.3 { fill = toward(fill, window: darkWindow, contrast: 1.35) }
        return fill
    }

    /// `hex` with OKLCH lightness moved away from `window` (chroma capped to stay in sRGB) until it reaches
    /// `contrast`, hue unchanged.
    static func toward(_ hex: UInt32, window: UInt32, contrast target: Double) -> UInt32 {
        let start = OKLCH(hex: hex)
        let darker = luminance(window) > 0.5
        var lo = 0.0, hi = 1.0  // fraction of the way to black (or white)
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let l = darker ? start.l * (1 - mid) : start.l + (1 - start.l) * mid
            if contrast(OKLCH(l: l, c: start.c, h: start.h).hexInGamut, window) < target { lo = mid } else { hi = mid }
        }
        let l = darker ? start.l * (1 - hi) : start.l + (1 - start.l) * hi
        return OKLCH(l: l, c: start.c, h: start.h).hexInGamut
    }

    /// The label on an accent-filled pill: white when it reads at 4.5:1, or at 3:1 on a darker mid-tone (OKLCH
    /// lightness under 0.65, such as violet), which pill labels meet as large text (15 pt bold); otherwise a near-black
    /// ink tinted with the accent's hue when that reads at 4.5:1 (lime, yellow, pastels); otherwise white at 3:1.
    static func label(on fill: UInt32) -> UInt32 {
        let white = contrast(fill, 0xFFFFFF)
        if white >= 4.5 || (white >= 3 && OKLCH(hex: fill).l < 0.65) { return 0xFFFFFF }
        let ink = self.ink(for: fill)
        if contrast(fill, ink) >= 4.5 { return ink }
        return contrast(fill, 0xFFFFFF) >= 3 ? 0xFFFFFF : 0x000000
    }
    static func ink(for fill: UInt32) -> UInt32 { OKLCH(l: 0.16, c: 0.02, h: OKLCH(hex: fill).h).hexInGamut }

    static func source(for design: DotDesign) -> UInt32 {
        design.custom != nil || design.isLogo ? defaultHex : design.color.hex
    }

    static func hex(for design: DotDesign) -> UInt32 { ui(source(for: design)) }

    /// The colour moved into `band` by lightness only (unchanged when already inside it). Frost's own accent, for
    /// imported avatars (`Theme.frost`).
    static func ui(_ hex: UInt32) -> UInt32 {
        guard !band.contains(luminance(hex)) else { return hex }
        let (h, s, _) = hsl(hex)
        var lo = 0.0, hi = 1.0
        let target = (band.lowerBound + band.upperBound) / 2
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if luminance(fromHSL(h, s, mid)) < target { lo = mid } else { hi = mid }
        }
        return fromHSL(h, s, (lo + hi) / 2)
    }

    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// `a` moved toward `b` by `amount` (0...1), per sRGB channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        func c(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
        func m(_ shift: UInt32) -> UInt32 { UInt32((c(a, shift) + (c(b, shift) - c(a, shift)) * amount).rounded()) << shift }
        return m(16) | m(8) | m(0)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func hsl(_ hex: UInt32) -> (Double, Double, Double) {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    private static func fromHSL(_ h: Double, _ s: Double, _ l: Double) -> UInt32 {
        func hue(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let (r, g, b): (Double, Double, Double)
        if s == 0 { (r, g, b) = (l, l, l) } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
            (r, g, b) = (hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3))
        }
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
