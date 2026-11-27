import AppKit
import SwiftUI

enum DotInk {
    static let ink = Color(hex: 0x0A0A0B)
    static let paper = Color.white
}

/// How a dot is painted. `.standard` is the flat vector mark (ink body); `.inverted` is the white body
/// used on dark tiles; `.template` is solid alpha for the menu bar.
enum DotStyle: Sendable { case standard, inverted, template }

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
struct DotView: View {
    let design: DotDesign
    let style: DotStyle
    let gutter: CGFloat

    init(_ design: DotDesign, style: DotStyle = .standard, gutter: CGFloat = 2.6) {
        self.design = design; self.style = style; self.gutter = gutter
    }

    var body: some View {
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
        // The logo drawn as a vector (menu bar, option cells) takes the PNG's coral, not the nearest palette colour.
        let accentHex = d.isLogo ? Accent.defaultHex : d.color.hex
        let accent = Color(hex: accentHex)
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
            let feature = colorBody ? (d.signature == .mic ? Color(hex: Accent.ink(for: accentHex)) : DotInk.ink) : accent
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
struct DotTile: View {
    @Environment(\.colorScheme) private var scheme
    let design: DotDesign
    let size: CGFloat
    var dark: Bool?

    init(_ design: DotDesign, size: CGFloat, dark: Bool? = nil) {
        self.design = design; self.size = size; self.dark = dark
    }

    var body: some View {
        if design.isLogo {
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
