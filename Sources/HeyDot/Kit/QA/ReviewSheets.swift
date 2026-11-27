import SwiftUI

/// The default logo as the user sees it: app-style tiles at 128, 64 and 32 pt plus the popover avatar size.
struct LogoSheet: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ForEach([128.0, 64, 52, 32], id: \.self) { size in
                VStack(spacing: 6) {
                    DotTile(.default, size: size)
                    Text("\(Int(size)) pt").font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                DotTile(.default, size: 64, dark: true)
                Text("dark tile").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

/// Accent swatches with the contrast each one reaches.
struct AccentBoard: View {
    static let samples: [(String, DotDesign)] = [
        ("tray", DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody)), ("pale", DotDesign(color: .yellow)), ("near-black", DotDesign(color: .charcoal)), ("default", .default),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.samples, id: \.0) { name, design in
                let raw = Accent.source(for: design), ui = Accent.hex(for: design)
                HStack(spacing: 14) {
                    Text(name).font(.headline).frame(width: 90, alignment: .leading)
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: raw)).frame(width: 44, height: 30)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: ui)).frame(width: 44, height: 30)
                    Text(String(format: "#%06X  white text %.1f:1  dark window %.1f:1  light window %.1f:1", ui,
                                Accent.contrast(ui, 0xFFFFFF), Accent.contrast(ui, Accent.darkWindow), Accent.contrast(ui, Accent.lightWindow)))
                        .font(.system(size: 12, design: .monospaced))
                    Button("Continue") {}.frostButton(.primary)
                    TileRings(size: 14, level: -20).frame(width: 30, height: 30)
                }
                .frostAccent(design)
            }
        }
        .padding(20)
        .background(FrostBackdrop())
    }
}

/// The six reference dots and their themes side by side: the backdrop each one gets, its stops and its accent.
struct ThemeBoard: View {
    /// (name, the dot, a palette override for colours no dot option expresses: a true red and a pale pastel).
    static let samples: [(String, DotDesign, Theme?)] = {
        var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue  // the lime example: lime with blue headphones
        return [
            ("default", .default, nil),
            ("tray", tray, nil),
            ("green-blue", DotDesign(color: .teal, accessory: .headphones, accessoryColor: .blue), Theme.from(palette: [0x2DB84D, 0x2F6BFF])),
            ("red", DotDesign(color: .coral), Theme.from(palette: [0xE0353B])),
            ("pale", DotDesign(color: .pink), Theme.from(palette: [0xF6D6E8])),
            ("near-black", DotDesign(color: .charcoal), nil),
        ]
    }()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Self.samples, id: \.0) { name, design, override in
                let theme = override ?? Theme.forDesign(design)
                VStack(spacing: 10) {
                    ZStack {
                        FrostBackdrop()
                        VStack(spacing: 14) {
                            DotTile(design, size: 64, dark: true)
                            Button("Continue") {}.frostButton(.primary)
                            HStack(spacing: 5) {
                                Capsule().fill(Color(hex: Accent.mark(theme.accent, dark: scheme == .dark))).frame(width: 18, height: 6)
                                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.primary.opacity(0.18)).frame(width: 6, height: 6) }
                            }
                        }
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Frost.Radius.card, style: .continuous))
                    Text(name).font(.headline)
                    HStack(spacing: 4) {
                        ForEach(theme.stops(dark: scheme == .dark), id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 4).fill(Color(hex: hex)).frame(width: 30, height: 18)
                        }
                        Circle().fill(Color(hex: theme.accent)).frame(width: 18, height: 18).padding(.leading, 4)
                    }
                    Text(String(format: "accent #%06X  label %.1f:1", theme.accent, Accent.contrast(theme.accent, Accent.label(on: theme.accent))))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frostTheme(theme)
            }
        }
        .padding(20)
        .background(SampleWallpaper())
    }
}

struct GlyphStrip: View {
    static let designs: [DotDesign] = [.default, DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones),
                                       DotDesign(shape: .heart, color: .pink, fill: .colorBody), DotDesign(shape: .hexagon, color: .coral, accessory: .crown)]
    var extra: [DotDesign] = []
    var designs: [DotDesign] { Self.designs + extra }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([false, true], id: \.self) { color in
                Text(color ? "Menu bar icon: Color" : "Menu bar icon: Monochrome (default)").font(.system(size: 11, weight: .semibold))
                ForEach([(false, Color(hex: 0xECECEC)), (true, Color(hex: 0x1E1E1E))], id: \.0) { dark, bg in
                    HStack(spacing: 18) {
                        ForEach(designs, id: \.self) { design in
                            ForEach([GlyphState.listening, .paused, .attention, .ok], id: \.self) { state in
                                let image = DotGlyph.image(design, state: state, color: color, darkBar: dark)
                                if color { Image(nsImage: image) }
                                else { Image(nsImage: image).renderingMode(.template).foregroundStyle(dark ? Color.white : Color.black) }
                            }
                            Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 24).background(bg)
                }
            }
        }
        .padding(10)
        .background(Color.white)
    }
}
