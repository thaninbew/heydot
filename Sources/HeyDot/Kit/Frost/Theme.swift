import Foundation
import SwiftUI

/// The whole look follows the dot (DESIGN.md, "Theme from dot"): the backdrop's three tint stops and the accent
/// come from the dot's own colours by one deterministic formula in OKLCH. Imported avatars keep Frost;
/// the default HeyDot logo follows its coral.
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

    /// Frost: coral, peach and pink, with the coral accent.
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
        if design.isLogo { return [Accent.defaultHex] }  // the logo's coral, not the mic's stored colour
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
