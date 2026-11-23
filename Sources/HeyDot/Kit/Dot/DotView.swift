import AppKit
import SwiftUI

public enum DotInk {
    public static let ink = Color(hex: 0x0A0A0B)
    public static let paper = Color.white
}

/// How a dot is painted. `.standard` is the flat vector mark (ink body); `.inverted` is the white body
/// used on dark tiles; `.template` is solid alpha for the menu bar.
public enum DotStyle: Sendable { case standard, inverted, template }

@MainActor
enum DotCache {
    private static var store: [String: [DotLayer]] = [:]
    static func layers(_ design: DotDesign, gutter: CGFloat) -> [DotLayer] {
        var keyed = design
        keyed.nickname = ""
        let key = "\(keyed.hashValue)-\(gutter)"
        if let hit = store[key] { return hit }
        let made = DotArt.layers(keyed, gutter: gutter)
        if store.count > 400 { store.removeAll() }
        store[key] = made
        return made
    }
}

/// Vector dot. The same model draws the menu bar glyph, popover avatar, dot maker and app icon.
public struct DotView: View {
    let design: DotDesign
    let style: DotStyle
    let gutter: CGFloat

    public init(_ design: DotDesign, style: DotStyle = .standard, gutter: CGFloat = 2.6) {
        self.design = design; self.style = style; self.gutter = gutter
    }

    public var body: some View {
        if let art = design.custom, let image = Self.avatar(art, style) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
        } else {
            // An avatar whose file is gone, or one without a silhouette in the monochrome menu bar, draws the logo.
            canvas(design.custom == nil ? design : .default)
        }
    }

    /// The imported avatar's image for this style; nil when the style can't use it.
    static func avatar(_ art: CustomArt, _ style: DotStyle) -> NSImage? {
        switch style {
        case .standard: Avatars.image(art.id)
        case .inverted: Avatars.image(art.id, .dark)
        case .template: art.silhouette ? Avatars.image(art.id, .template) : nil
        }
    }

    func canvas(_ design: DotDesign) -> some View {
        let layers = DotCache.layers(design, gutter: gutter)
        let palette = Self.palette(design, style)
        return Canvas { context, size in
            let s = min(size.width, size.height) / 96
            context.translateBy(x: (size.width - 96 * s) / 2, y: (size.height - 96 * s) / 2)
            context.scaleBy(x: s, y: s)
            for layer in layers {
                guard let color = palette(layer.role) else { continue }
                let path = Path(layer.path)
                context.fill(path, with: .color(color))
                // Close the anti-aliasing seam between an eye and the hole cut for it.
                if layer.role == .eye && style != .template { context.stroke(path, with: .color(color), lineWidth: 0.6) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    static func palette(_ d: DotDesign, _ style: DotStyle) -> (LayerRole) -> Color? {
        let accent = d.color.color
        // Charcoal is the one-colour accessory: it matches the ink, and turns white on a dark tile
        // (the flat vector tile variant), so Tray's headphones stay visible everywhere.
        let accessory = d.accessoryColor != .charcoal ? d.accessoryColor.color
            : (style == .inverted && d.fill == .inkBody ? DotInk.paper : DotInk.ink)
        let colorBody = d.fill == .colorBody
        switch style {
        case .template:
            return { role in
                switch role {
                case .body, .line, .accessory: return .black
                case .eye, .highlight, .glint: return nil
                }
            }
        case .standard, .inverted:
            let body = colorBody ? accent : (style == .inverted ? DotInk.paper : DotInk.ink)
            let feature = colorBody ? (d.signature == .mic ? Color(hex: Accent.ink(for: d.color.hex)) : DotInk.ink) : accent
            let line = style == .inverted && !colorBody ? DotInk.paper : DotInk.ink
            return { role in
                switch role {
                case .body: return body
                case .eye: return feature
                case .highlight: return DotInk.paper
                case .line: return line
                case .glint: return colorBody ? DotInk.paper : accent
                case .accessory: return accessory
                }
            }
        }
    }
}

/// A dot on a frosted rounded tile (translucent white, lighter in dark mode) in the dot's own colours.
public struct DotTile: View {
    @Environment(\.colorScheme) private var scheme
    let design: DotDesign
    let size: CGFloat
    var dark: Bool?

    public init(_ design: DotDesign, size: CGFloat, dark: Bool? = nil) {
        self.design = design; self.size = size; self.dark = dark
    }

    public var body: some View {
        if design == .default {
            // The icon has 100 units of transparent inset on Apple's 1024 grid.
            Image(nsImage: LogoAsset.image).resizable().interpolation(.high)
                .frame(width: size * 1024 / 824, height: size * 1024 / 824)
                .frame(width: size, height: size)
        } else {
            // Frosted glass in both appearances, so the window's theme shows through and the dot is the only colour on
            // it: more white in light mode, a lighter veil in dark mode.
            let isDark = dark ?? (scheme == .dark)
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Color.white.opacity(isDark ? 0.16 : 0.45))
                .overlay {
                    DotView(design, style: isDark ? .inverted : .standard)
                        .padding(size * 0.14)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .strokeBorder(Color.white.opacity(isDark ? 0.22 : 0.8), lineWidth: 1)
                }
                .frame(width: size, height: size)
        }
    }
}

/// Menu bar state shown on top of the dot glyph. `ok` is a brief check after a call starts or a check passes.
public enum GlyphState: Sendable { case listening, paused, attention, ok }

@MainActor
public enum DotGlyph {
    /// An 18 pt menu bar image of the user's dot. Monochrome is a template image (macOS tints it);
    /// colour is a non-template image in the dot's own colours, drawn for the bar's light or dark
    /// appearance. Paused dims the dot and adds a pause badge; attention adds an orange alert badge.
    public static func image(_ design: DotDesign, state: GlyphState, points: CGFloat = 18,
                             color: Bool = false, darkBar: Bool = false) -> NSImage {
        let view = GlyphView(design: design, state: state, color: color, darkBar: darkBar).frame(width: points, height: points)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: points, height: points))
        image.isTemplate = !color
        image.accessibilityDescription = switch state {
        case .listening: "HeyDot, listening"
        case .paused: "HeyDot, paused"
        case .attention: "HeyDot, needs attention"
        case .ok: "HeyDot, done"
        }
        return image
    }
}

struct GlyphView: View {
    let design: DotDesign
    let state: GlyphState
    var color = false
    var darkBar = false

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            // In colour, the body is ink on a light bar and white on a dark one (the tile rule), so it never vanishes.
            let ink: Color = color ? (darkBar ? DotInk.paper : DotInk.ink) : .black
            ZStack {
                // A wider gutter keeps cuts visible at 18 pt.
                DotView(design, style: color ? (darkBar ? .inverted : .standard) : .template, gutter: design.signature == .mic ? 4 : 5)
                    .opacity(state == .paused ? 0.35 : 1)
                if state != .listening {
                    let badge = side * 0.4
                    ZStack {
                        Circle().fill(.black).frame(width: badge + side * 0.12, height: badge + side * 0.12)
                            .blendMode(.destinationOut)
                        Circle().fill(color && state == .attention ? Color(hex: 0xFF8A00) : color && state == .ok ? Color(hex: 0x28A745) : ink)
                            .frame(width: badge, height: badge)
                        BadgeMark(state: state)
                            .fill(.black)
                            .frame(width: badge, height: badge)
                            .blendMode(.destinationOut)
                    }
                    .position(x: side - badge / 2, y: side - badge / 2)
                }
            }
            .compositingGroup()
        }
    }
}

/// The cut-out mark inside the badge: two bars for paused, an exclamation for attention.
struct BadgeMark: Shape {
    let state: GlyphState
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        var p = Path()
        switch state {
        case .paused:
            p.addRoundedRect(in: CGRect(x: w * 0.30, y: w * 0.26, width: w * 0.14, height: w * 0.48), cornerSize: CGSize(width: w * 0.04, height: w * 0.04))
            p.addRoundedRect(in: CGRect(x: w * 0.56, y: w * 0.26, width: w * 0.14, height: w * 0.48), cornerSize: CGSize(width: w * 0.04, height: w * 0.04))
        case .attention:
            p.addRoundedRect(in: CGRect(x: w * 0.42, y: w * 0.2, width: w * 0.16, height: w * 0.38), cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
            p.addEllipse(in: CGRect(x: w * 0.42, y: w * 0.66, width: w * 0.16, height: w * 0.16))
        case .ok:
            var tick = Path()
            tick.move(to: CGPoint(x: w * 0.27, y: w * 0.52))
            tick.addLine(to: CGPoint(x: w * 0.44, y: w * 0.68))
            tick.addLine(to: CGPoint(x: w * 0.74, y: w * 0.34))
            p.addPath(tick.strokedPath(StrokeStyle(lineWidth: w * 0.16, lineCap: .round, lineJoin: .round)))
        case .listening:
            break
        }
        return p
    }
}
