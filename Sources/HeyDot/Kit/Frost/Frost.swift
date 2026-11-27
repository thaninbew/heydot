import SwiftUI

// Frost: HeyDot's window and popover look. A see-through window the wallpaper tints, two soft tint blobs drifting
// behind the content, the app tile floating at the centre and accent-tinted Liquid Glass buttons (macOS 26), with a
// drawn fallback on macOS 14 and 15. Motion runs as Core Animation in the render server, so it costs the app no
// CPU, stops when the window is closed or occluded, and is off with Reduce Motion.

/// The design tokens (DESIGN.md): every surface takes its sizes, radii and spacing from here.
enum Frost {

    /// Pill heights: the main pill (primary, secondary, round) and the chip (inline actions, pause chips, choices).
    static let pillHeight: CGFloat = 46
    static let chipHeight: CGFloat = 30
    /// Corner radii. Pills and chips are capsules; tiles use 23 % of their side.
    enum Radius {
        static let card: CGFloat = 18      // cards, the popover
        static let field: CGFloat = 14     // text fields, option cells
        static let inset: CGFloat = 12     // banners, code previews, list rows
    }
    /// Spacing scale, in points.
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    static let blobs: [(color: UInt32, x: CGFloat, y: CGFloat, radius: CGFloat)] = [
        (0xFB9890, 0.08, 0.10, 0.62),  // coral, top left
        (0xF4BF8C, 0.95, 0.12, 0.55),  // peach, top right
        (0xF4A0C8, 0.55, 1.05, 0.50),  // pink, bottom
    ]
}

private struct FrostAccentKey: EnvironmentKey { static let defaultValue = Accent.ui(Accent.defaultHex) }

extension EnvironmentValues {
    /// The accent fill (`Theme.accent`) as sRGB hex, set at each window's root by `frostTheme`.
    var frostAccentHex: UInt32 {
        get { self[FrostAccentKey.self] }
        set { self[FrostAccentKey.self] = newValue }
    }
    /// `Accent.mark` for the current appearance.
    var frostMark: Color { Color(hex: Accent.mark(frostAccentHex, dark: colorScheme == .dark)) }
}

/// `frostMark` as a style, resolved where it's drawn. Good news (signed in, call started, a check passed) uses the
/// dot's own colour, never a stock green that fights the theme.
struct FrostMarkStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.frostMark }
}
extension ShapeStyle where Self == FrostMarkStyle {
    static var frostMark: FrostMarkStyle { FrostMarkStyle() }
}

extension View {
    /// Themes this subtree from a dot design (`Theme.forDesign`): backdrop, accent, glass tint, focus rings,
    /// progress, rings, switches and links.
    func frostTheme(_ design: DotDesign) -> some View { frostTheme(Theme.forDesign(design)) }
}

private struct FrostSnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// QA renders only. Offscreen capture can't draw behind-window blur or Liquid Glass, so a render draws a
    /// sample wallpaper under a translucent wash and uses the macOS 14/15 button fallback.
    var frostSnapshot: Bool {
        get { self[FrostSnapshotKey.self] }
        set { self[FrostSnapshotKey.self] = newValue }
    }
}
