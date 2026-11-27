import AppKit
import SwiftUI

/// Menu bar state shown on top of the dot glyph. `ok` is a brief check after a call starts or a check passes.
enum GlyphState: Sendable { case listening, paused, attention, ok }

@MainActor
enum DotGlyph {
    /// An 18 pt menu bar image of the user's dot. Monochrome is a template image (macOS tints it);
    /// colour is a non-template image in the dot's own colours, drawn for the bar's light or dark
    /// appearance. Paused dims the dot and adds a pause badge; attention adds an orange alert badge.
    static func image(_ design: DotDesign, state: GlyphState, points: CGFloat = 18,
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
