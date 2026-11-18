import Foundation
import SwiftUI

/// The whole look follows the dot (DESIGN.md, "Theme from dot"): the backdrop's three tint stops and the accent
/// come from the dot's own colours by one deterministic formula in OKLCH. Imported avatars keep Frost;
/// the default HeyDot logo follows its violet.
struct Theme: Equatable, Sendable {
    /// Backdrop stops (sRGB hex), in `Frost.blobs` order: top left, top right, bottom.
    let light: [UInt32]
    let dark: [UInt32]
    /// The fill accent: the dot's own main colour (`Accent.pill`). Labels on it come from `Accent.label`, marks
    /// from `Accent.mark`.
    let accent: UInt32
    /// How strongly each stop shows (1 is Frost's even blobs); the dot's main colour leads.
    var weights: [Double] = [1, 1, 1]
    /// An even wash of the main colour under the blobs, so the window reads as the dot's colour; nil for Frost.
    var wash: UInt32?

    func stops(dark isDark: Bool) -> [UInt32] { isDark ? dark : light }

    /// Frost: violet, peach and blue, with the violet accent.
    static let frost: Theme = {
        let stops = Frost.blobs.map(\.color)
        return Theme(light: stops, dark: stops, accent: Accent.ui(Accent.defaultHex))
    }()

    // MARK: From a dot

    /// QA renders only: a palette to theme every window with (a single red, a pale pastel) that no dot design
    /// expresses. Always nil in the app.
    nonisolated(unsafe) static var renderOverride: Theme?

    static func forDesign(_ design: DotDesign) -> Theme {
        if let renderOverride { return renderOverride }
        let colors = palette(for: design)
        guard !colors.isEmpty else { return .frost }
        return from(palette: colors)
    }

    /// The dot's dominant colours from its definition, not its pixels: the chosen colour, then the accessory colour
    /// when the dot wears one in a colour (charcoal and brown are ink, not hue). Empty for imported avatars.
    static func palette(for design: DotDesign) -> [UInt32] {
        guard design.custom == nil else { return [] }
        var colors = [design.color.hex]
        if design.accessory != .none, ![.charcoal, .brown].contains(design.accessoryColor), design.accessoryColor != design.color {
            colors.append(design.accessoryColor.hex)
        }
        return colors
    }

    /// The formula. The first colour is the main one (the dot body); chromatic inputs (OKLCH chroma at least
    /// 0.02) give the hues:
    /// - none (grey, near-black): a quiet slate theme, cool tinted neutrals;
    /// - one hue h: h leads, with its split complement h + 150 and an analogous h - 40 in support;
    /// - two or three: the main hue leads, the second supports, and one stop fills the largest gap on the hue wheel.
    /// The main stop keeps the dot's own lightness and chroma within soft bounds; the supporting stops are quieter.
    /// The accent is the main colour itself.
    static func from(palette: [UInt32]) -> Theme {
        let main = palette.first ?? Accent.defaultHex
        let colors = palette.map(OKLCH.init(hex:)).filter { $0.c >= 0.02 }
        var hues: [Double] = []
        for c in colors where !hues.contains(where: { OKLCH.hueDistance($0, c.h) < 12 }) { hues.append(c.h) }
        let accent = Accent.pill(main)
        guard let lead = colors.first else {
            let ring: [Double] = [262, 222, 302]
            return Theme(light: ring.map { OKLCH(l: 0.80, c: 0.035, h: $0).hexInGamut },
                         dark: ring.map { OKLCH(l: 0.62, c: 0.03, h: $0).hexInGamut },
                         accent: accent, weights: [1, 1, 1], wash: nil)
        }
        let ring: [Double] = hues.count == 1
            ? [lead.h, OKLCH.wrap(lead.h + 150), OKLCH.wrap(lead.h - 40)]
            : [hues[0], hues[1], largestGapMiddle(Array(hues.prefix(2)))]
        func stops(dark: Bool) -> [UInt32] {
            let bounds = dark ? lightnessBounds.dark : lightnessBounds.light
            let leadStop = OKLCH(l: min(max(lead.l, bounds.lowerBound + 0.05), bounds.upperBound),
                                 c: min(lead.c, dark ? 0.14 : mainChroma), h: lead.h)
            let support = ring.dropFirst().map { OKLCH(l: dark ? 0.62 : 0.80, c: dark ? 0.08 : 0.09, h: $0) }
            return ([leadStop] + support).map(\.hexInGamut)
        }
        let light = stops(dark: false)
        return Theme(light: light, dark: stops(dark: true), accent: accent, weights: [1.4, 0.6, 0.45], wash: light[0])
    }

    static let mainChroma = 0.17
    static let chromaBounds: ClosedRange<Double> = 0.0...mainChroma
    static let lightnessBounds: (light: ClosedRange<Double>, dark: ClosedRange<Double>) = (0.72...0.90, 0.52...0.72)

    /// The middle of the widest empty arc between the given hues.
    static func largestGapMiddle(_ hues: [Double]) -> Double {
        let sorted = hues.map(OKLCH.wrap).sorted()
        var best = (gap: -1.0, middle: 0.0)
        for (i, h) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : sorted[0] + 360
            let gap = next - h
            if gap > best.gap { best = (gap, OKLCH.wrap(h + gap / 2)) }
        }
        return best.middle
    }
}

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

// MARK: Environment

private struct FrostThemeKey: EnvironmentKey { static let defaultValue = Theme.frost }

extension EnvironmentValues {
    /// The dot's theme, set at each window's root with the accent.
    var frostTheme: Theme {
        get { self[FrostThemeKey.self] }
        set { self[FrostThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies a theme to a subtree: backdrop stops, accent and tint, crossfading when it changes.
    func frostTheme(_ theme: Theme) -> some View {
        environment(\.frostTheme, theme)
            .environment(\.frostAccentHex, theme.accent)
            .tint(Color(hex: theme.accent))
            .animation(.easeInOut(duration: 0.6), value: theme)
    }
}
