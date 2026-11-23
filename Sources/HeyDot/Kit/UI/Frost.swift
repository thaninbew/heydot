import AppKit
import QuartzCore
import SwiftUI

// Frost: HeyDot's window and popover look. A see-through window the wallpaper tints, two soft tint blobs drifting
// behind the content, the app tile floating at the centre and violet Liquid Glass buttons (macOS 26), with a
// drawn fallback on macOS 14 and 15. Motion runs as Core Animation in the render server, so it costs the app no
// CPU, stops when the window is closed or occluded, and is off with Reduce Motion.

/// The design tokens (DESIGN.md): every surface takes its sizes, radii and spacing from here.
enum Frost {
    /// The default dot's eye violet, and the deeper and lighter ends of the primary button.
    static let violet = Color(hex: 0x7B61FF)
    static let violetDeep = Color(hex: 0x6146F0)
    static let violetLight = Color(hex: 0x9D8BFF)

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
        (0x9B7CFF, 0.08, 0.10, 0.62),  // violet, top left
        (0xFFB08A, 0.95, 0.12, 0.55),  // peach, top right
        (0x8EC5FF, 0.55, 1.05, 0.50),  // blue, bottom
    ]
}

// MARK: Accent

/// The UI accent follows the dot's colour: its hue and saturation, with lightness moved into the one band where
/// white button text stays readable (at least 4.5:1) and marks still stand out on a dark window (at least 3:1
/// against #1E1E1E) and a light one. The default logo, custom avatars and an undesigned dot use Frost's violet.
enum Accent {
    static let defaultHex: UInt32 = 0x7B61FF
    static let darkWindow: UInt32 = 0x1E1E1E
    static let lightWindow: UInt32 = 0xF2F2F5
    /// Relative luminance band that meets both contrast floors.
    static let band: ClosedRange<Double> = 0.145...0.183

    /// The accent for text and marks drawn on the window (rings, progress, level bars, ticks): in dark mode lifted
    /// until it reads at 4.5:1 on a dark window; in light mode the fill colour already does (`band`).
    ///
    /// Since round 7 the accent is the dot's own colour, so marks (rings, progress, level bars, ticks, focus) use the
    /// same hue moved in OKLCH lightness only as far as 3:1 against the window needs: lime deepens a little on a light
    /// window, a near-black lightens on a dark one, and most colours stay as they are.
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
        design.custom != nil ? defaultHex : design.color.hex
    }

    static func hex(for design: DotDesign) -> UInt32 { ui(source(for: design)) }

    /// The colour moved into `band` by lightness only (unchanged when already inside it).
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

private struct FrostAccentKey: EnvironmentKey { static let defaultValue = Accent.ui(Accent.defaultHex) }

extension EnvironmentValues {
    /// The dot-derived accent (`Accent`) as sRGB hex, set at each window's root.
    var frostAccentHex: UInt32 {
        get { self[FrostAccentKey.self] }
        set { self[FrostAccentKey.self] = newValue }
    }
    var frostAccent: Color { Color(hex: frostAccentHex) }
    /// `Accent.mark` for the current appearance.
    var frostMark: Color { Color(hex: Accent.mark(frostAccentHex, dark: colorScheme == .dark)) }
    /// The label colour on an accent fill (`Accent.label`).
    var frostLabel: Color { Color(hex: Accent.label(on: frostAccentHex)) }
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
    /// Sets the accent for this subtree from a dot design: glass tint, focus rings, progress, rings, switches, links.
    /// Since round 6 the whole theme follows the dot (`Theme`), not only the accent.
    func frostAccent(_ design: DotDesign) -> some View { frostTheme(Theme.forDesign(design)) }
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

// MARK: Backdrop

/// The window's background. Live: the behind-window material plus drifting tint blobs (window only; the popover
/// passes `animated: false` and `material: false`, since NSPopover has its own material).
struct FrostBackdrop: View {
    var animated = true
    var material = true
    @Environment(\.frostTheme) private var theme
    @Environment(\.frostSnapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if snapshot {
            ZStack {
                SampleWallpaper()
                (scheme == .dark ? Color(white: 0.11) : Color.white).opacity(scheme == .dark ? 0.66 : 0.6)
                FrostBlobs(theme: theme, dark: scheme == .dark)
            }
        } else {
            FrostBackdropLayer(material: material, animated: animated && !reduceMotion, dark: scheme == .dark, theme: theme)
        }
    }
}

/// Static blobs, for QA renders (the live window draws the same ones as layers).
private struct FrostBlobs: View {
    let theme: Theme
    let dark: Bool
    var body: some View {
        let stops = theme.stops(dark: dark)
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            if let wash = theme.wash { Color(hex: wash, opacity: dark ? 0.10 : 0.14) }
            ForEach(Array(Frost.blobs.enumerated()), id: \.offset) { i, blob in
                RadialGradient(colors: [Color(hex: stops[i % stops.count], opacity: (dark ? 0.24 : 0.34) * theme.weights[i % theme.weights.count]), .clear],
                               center: .center, startRadius: 0, endRadius: side * blob.radius)
                    .frame(width: side * blob.radius * 2, height: side * blob.radius * 2)
                    .position(x: geo.size.width * blob.x, y: geo.size.height * blob.y)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A stand-in desktop for QA renders: a neutral grey, so the colour a render shows comes from the theme alone
/// (a Frost-coloured stand-in made every theme look like Frost).
struct SampleWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(hex: 0xC4C7D0), Color(hex: 0xE2E0DD)], startPoint: .top, endPoint: .bottom)
    }
}

private struct FrostBackdropLayer: NSViewRepresentable {
    let material: Bool
    let animated: Bool
    let dark: Bool
    let theme: Theme
    func makeNSView(context: Context) -> FrostBackdropView { FrostBackdropView(material: material) }
    func updateNSView(_ view: FrostBackdropView, context: Context) { view.configure(dark: dark, animated: animated, theme: theme) }
}

final class FrostBackdropView: NSView {
    /// Decoration only: clicks and scrolling pass through to the content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private let blobs = CALayer()
    private var animated = false
    private var dark = false

    init(material: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        if material {
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.autoresizingMask = [.width, .height]
            addSubview(effect)
        }
        let host = NSView()
        host.wantsLayer = true
        host.layer?.addSublayer(wash)
        host.layer?.addSublayer(blobs)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        for blob in Frost.blobs {
            let layer = CAGradientLayer()
            layer.type = .radial
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            blobs.addSublayer(layer)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var theme: Theme?
    private let wash = CALayer()

    /// A new theme crossfades the wash and blobs (0.6 s, in the render server).
    func configure(dark: Bool, animated: Bool, theme: Theme) {
        let recolor = theme != self.theme || dark != self.dark
        let first = self.theme == nil
        self.dark = dark; self.theme = theme
        if recolor {
            let stops = theme.stops(dark: dark)
            CATransaction.begin()
            CATransaction.setAnimationDuration(first ? 0 : 0.6)
            CATransaction.setDisableActions(first)
            wash.backgroundColor = theme.wash.map { NSColor(Color(hex: $0)).withAlphaComponent(dark ? 0.10 : 0.14).cgColor }
                ?? NSColor.clear.cgColor
            for (i, sublayer) in (blobs.sublayers ?? []).enumerated() {
                guard let layer = sublayer as? CAGradientLayer else { continue }
                let color = NSColor(Color(hex: stops[i % max(1, stops.count)]))
                let alpha = (dark ? 0.24 : 0.34) * theme.weights[i % max(1, theme.weights.count)]
                layer.colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
            }
            CATransaction.commit()
        }
        if self.animated != animated { self.animated = animated; updateMotion() }
    }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
        let side = max(bounds.width, bounds.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blobs.frame = bounds
        wash.frame = bounds
        for (layer, blob) in zip(blobs.sublayers ?? [], Frost.blobs) {
            let d = side * blob.radius * 2
            layer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            // AppKit layers are y-up; the blob table is y-down.
            layer.position = CGPoint(x: bounds.width * blob.x, y: bounds.height * (1 - blob.y))
        }
        CATransaction.commit()
        updateMotion()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMotion() }

    /// Two blobs drift on 26 s and 32 s loops while the view is in a window; none otherwise.
    private func updateMotion() {
        let layers = blobs.sublayers ?? []
        layers.forEach { $0.removeAnimation(forKey: "drift") }
        guard animated, window != nil, bounds.width > 0 else { return }
        for (layer, (period, dx, dy)) in zip(layers, [(26.0, 0.06, 0.05), (32.0, -0.05, 0.06)]) {
            let drift = CABasicAnimation(keyPath: "position")
            drift.byValue = NSValue(point: NSPoint(x: bounds.width * dx, y: bounds.height * dy))
            drift.duration = period / 2
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(drift, forKey: "drift")
        }
    }
}

// MARK: Floating tile

/// The app tile, floating 9 pt with a ±1.2° sway on a 6 s loop. The tile is drawn by `DotTile` exactly as
/// everywhere else, rendered once into a layer, and only that layer moves.
struct FloatingTile: View {
    let design: DotDesign
    let size: CGFloat
    var dark: Bool? = true
    var floats = true
    @Environment(\.frostSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.frostAccentHex) private var accentHex

    var body: some View {
        Group {
            if snapshot || reduceMotion || !floats {
                DotTile(design, size: size, dark: dark)
                    .shadow(color: Color(hex: accentHex).opacity(0.24), radius: size * 0.14, y: size * 0.08)
            } else {
                FloatingTileLayer(design: design, size: size, dark: dark ?? (scheme == .dark), scheme: scheme, shadow: accentHex)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct FloatingTileLayer: NSViewRepresentable {
    let design: DotDesign
    let size: CGFloat
    let dark: Bool
    let scheme: ColorScheme
    let shadow: UInt32
    func makeNSView(context: Context) -> FloatingTileView { FloatingTileView() }
    func updateNSView(_ view: FloatingTileView, context: Context) {
        view.shadowColor = NSColor(Color(hex: shadow)).cgColor
        view.show(key: "\(design)|\(size)|\(dark)|\(scheme)") {
            DotTile(design, size: size, dark: dark).environment(\.colorScheme, scheme)
        }
    }
}

final class FloatingTileView: NSView {
    /// Decoration only: clicks and scrolling pass through to the content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private let tile = CALayer()
    private var key: String?
    var shadowColor: CGColor? {
        get { tile.shadowColor }
        set { tile.shadowColor = newValue }
    }

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = false
        tile.shadowColor = NSColor(Frost.violetDeep).cgColor
        tile.shadowOpacity = 0.24
        layer?.addSublayer(tile)
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func show<V: View>(key: String, _ content: () -> V) {
        guard key != self.key else { return }
        self.key = key
        let renderer = ImageRenderer(content: content())
        renderer.scale = window?.backingScaleFactor ?? 2
        tile.contents = renderer.cgImage
        tile.contentsScale = renderer.scale
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let size = min(bounds.width, bounds.height)
        tile.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        tile.position = CGPoint(x: bounds.midX, y: bounds.midY)
        tile.shadowRadius = size * 0.14
        tile.shadowOffset = CGSize(width: 0, height: -size * 0.08)
        tile.shadowPath = CGPath(roundedRect: tile.bounds, cornerWidth: size * 0.23, cornerHeight: size * 0.23, transform: nil)
        CATransaction.commit()
        updateMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor, scale != tile.contentsScale { key = nil }
        updateMotion()
    }

    private func updateMotion() {
        tile.removeAllAnimations()
        guard window != nil, tile.bounds.width > 0 else { return }
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -4.5; float.toValue = 4.5
        let sway = CABasicAnimation(keyPath: "transform.rotation.z")
        sway.fromValue = -1.2 * Double.pi / 180; sway.toValue = 1.2 * Double.pi / 180
        sway.beginTime = CACurrentMediaTime() - 1.5  // a quarter loop behind the float
        for animation in [float, sway] {
            animation.duration = 3
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tile.add(animation, forKey: animation.keyPath)
        }
    }
}

// MARK: Rings

/// Rings around the tile. With a level they follow the microphone (they move only while sound is heard);
/// without one they sit still.
struct TileRings: View {
    let size: CGFloat
    var level: Float?
    @Environment(\.self) private var env

    var body: some View {
        let tint = env.frostMark
        let f = CGFloat(max(0, min(1, ((level ?? -60) + 60) / 54)))
        ZStack {
            Circle().strokeBorder(tint.opacity(0.14 + 0.3 * f), lineWidth: 1.5)
                .frame(width: size * 2.05, height: size * 2.05)
                .scaleEffect(1 + 0.06 * f)
            Circle().strokeBorder(tint.opacity(0.3 + 0.45 * f), lineWidth: 2)
                .frame(width: size * 1.78, height: size * 1.78)
                .scaleEffect(1 + 0.04 * f)
        }
        .animation(.easeOut(duration: 0.12), value: f)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Rings driven by the tuning screen's level history.
struct LiveRings: View {
    @ObservedObject var history: LevelHistory
    let size: CGFloat
    let active: Bool
    var body: some View { TileRings(size: size, level: active ? history.levels.last : nil) }
}

// MARK: Buttons

enum FrostRole { case primary, secondary, round, chip, hangUp }

extension View {
    /// Every Frost button is one capsule (or circle) whose size HeyDot sets, so primary and secondary buttons
    /// share one height and base width. macOS 26 fills it with Liquid Glass (violet-tinted for the primary); 14 and
    /// 15, and QA renders, draw the fallback.
    func frostButton(_ role: FrostRole) -> some View { modifier(FrostButtonModifier(role: role)) }
}

private struct FrostButtonModifier: ViewModifier {
    let role: FrostRole
    @Environment(\.frostSnapshot) private var snapshot

    func body(content: Content) -> some View {
                content.buttonStyle(FrostButtonStyle(role: role, ownFocusRing: true)).focusEffectDisabled()
    }
}

struct FrostButtonStyle: ButtonStyle {
    let role: FrostRole
    /// Draw the accent focus ring (and the caller turns the system one off). A style applied to a whole form
    /// keeps the system ring instead, so text fields in it keep theirs.
    var ownFocusRing = false
    /// One height for every capsule button in a row, and the width a short label starts from.
    static let height = Frost.pillHeight
    static let baseWidth: CGFloat = 132
    func makeBody(configuration: Configuration) -> some View { FrostButtonBody(role: role, ownFocusRing: ownFocusRing, configuration: configuration) }
}

private struct FrostButtonBody: View {
    let role: FrostRole
    let ownFocusRing: Bool
    let configuration: ButtonStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.frostSnapshot) private var snapshot
    @Environment(\.frostAccentHex) private var accentHex
    private var accent: Color { Color(hex: accentHex) }
    @Environment(\.isFocused) private var focused

    private var circular: Bool { role == .round || role == .hangUp }
    private var filled: Bool { role == .primary || role == .hangUp }
    private var shape: AnyShape { circular ? AnyShape(Circle()) : AnyShape(Capsule()) }

    var body: some View {
        let height = role == .chip ? Frost.chipHeight : Frost.pillHeight
        configuration.label
            .font(.system(size: role == .chip ? 13 : 15, weight: filled ? .semibold : .medium))
            .foregroundStyle(role == .hangUp ? Color.white : role == .primary ? Color(hex: Accent.label(on: accentHex))
                             : (configuration.role == .destructive ? Color.red : Color.primary))
            .lineLimit(1)
            .padding(.horizontal, circular ? 0 : (role == .chip ? 11 : 24))
            .frame(minWidth: circular ? height : (role == .chip ? nil : FrostButtonStyle.baseWidth), minHeight: height)
            .background { surface }
            .overlay {
                // The keyboard focus ring, in the accent (the system ring is turned off for these buttons).
                if ownFocusRing && focused && !snapshot { shape.stroke(Color(hex: Accent.mark(accentHex, dark: scheme == .dark)), lineWidth: 2.5).padding(-3.5) }
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder private var surface: some View {
        let tint: Color? = role == .primary ? accent : (role == .hangUp ? Color(hex: 0xF0453C) : nil)
        if #available(macOS 26, *), !snapshot {
            Color.clear
                .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: shape)
                .shadow(color: (tint ?? .clear).opacity(enabled ? 0.3 : 0), radius: 10, y: 4)
        } else {
            drawn
        }
    }

    /// macOS 14 and 15: a violet gradient capsule with a top highlight, or a frosted white capsule.
    @ViewBuilder private var drawn: some View {
        let dark = scheme == .dark
        if filled {
            let base = role == .hangUp ? Color(hex: 0xFF5A52) : Color(hex: Accent.mix(accentHex, 0xFFFFFF, 0.1))
            let deep = role == .hangUp ? Color(hex: 0xE5352C) : Color(hex: Accent.mix(accentHex, 0x000000, 0.08))
            shape.fill(LinearGradient(colors: [base, deep], startPoint: .top, endPoint: .bottom))
                // A top highlight as a fill: a stroke here draws stray edges in offscreen captures.
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0)], startPoint: .top, endPoint: .center)))
                .compositingGroup()
                .shadow(color: deep.opacity(enabled ? 0.34 : 0), radius: 10, y: 4)
        } else {
            shape.fill(dark ? Color.white.opacity(0.12) : Color.white.opacity(0.78))
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(dark ? 0.28 : 0.9), .white.opacity(0.08)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .shadow(color: .black.opacity(dark ? 0.25 : 0.07), radius: 6, y: 2)
        }
    }
}

/// A frosted panel for grouped content (dot lists, the agent checklist).
struct FrostCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        content
            // Inline actions in a card are chips (rows that need their own look set a style themselves).
            .buttonStyle(FrostButtonStyle(role: .chip))
            .padding(16)
            .background(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: Frost.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Frost.Radius.card, style: .continuous).strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0.7), lineWidth: 0.75))
    }
}

/// A frosted rounded field for text entry.
struct FrostField: ViewModifier {
    var height: CGFloat = Frost.pillHeight
    var fontSize: CGFloat = 17
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .padding(.horizontal, height > 40 ? 16 : 12)
            .frame(height: height)
            .background(scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: Frost.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Frost.Radius.field, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
    }
}

/// A choice between a few options (the pill version of a segmented control): a capsule track of chips, the chosen
/// one filled with the accent.
struct FrostChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.frostAccentHex) private var accentHex
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let chosen = value == selection
                Button { selection = value } label: {
                    Text(label).font(.system(size: 13, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? Color(hex: Accent.label(on: accentHex)) : Color.primary)
                        .padding(.horizontal, 14).frame(minWidth: 64, minHeight: Frost.chipHeight - 4)
                        .background(chosen ? Color(hex: accentHex) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)))
        .fixedSize()
    }
}

/// One result or problem, on a softly tinted inset (call and check results, import errors).
struct FrostBanner<Trailing: View>: View {
    let good: Bool
    let message: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Frost.Space.s) {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(good ? AnyShapeStyle(.frostMark) : AnyShapeStyle(.orange))
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, Frost.Space.m).padding(.vertical, 10)
        .background(good ? AnyShapeStyle(.frostMark.opacity(0.12)) : AnyShapeStyle(Color.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: Frost.Radius.inset, style: .continuous))
    }
}

/// A scrolling monospaced preview (agent prompts).
struct FrostCodePreview: View {
    let text: String
    var height: CGFloat = 180
    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Frost.Space.m)
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Frost.Radius.inset, style: .continuous))
    }
}
