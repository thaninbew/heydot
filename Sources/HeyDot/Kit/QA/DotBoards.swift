import AppKit
import SwiftUI

/// Offscreen boards for design review: every shape, every accessory, fit grids and logo candidates.
@MainActor
enum DotBoards {
    static func write<V: View>(_ view: V, to url: URL, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    struct Cell: View {
        let design: DotDesign
        let label: String
        var size: CGFloat = 120
        var body: some View {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    DotView(design).frame(width: size, height: size)
                        .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    DotTile(design, size: size + 20, dark: true)
                }
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0x333333))
            }
        }
    }

    static func board<C: View>(_ title: String, columns: Int, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Color(hex: 0x111111))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(300), spacing: 18), count: columns), alignment: .leading, spacing: 22) {
                content()
            }
        }
        .padding(28)
        .background(Color(hex: 0xEFEFEC))
    }

    static func renderAll(into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(board("Shapes (default colour, oval eyes)", columns: 4) {
            ForEach(DotShape.allCases) { shape in Cell(design: DotDesign(shape: shape), label: shape.label) }
        }, to: dir.appendingPathComponent("dot-shapes.png"))
        try write(board("Accessories on Circle (accessory colour Coral)", columns: 3) {
            ForEach(DotAccessory.allCases) { a in
                Cell(design: DotDesign(shape: .circle, color: .violet, accessory: a, accessoryColor: .coral), label: a.label)
            }
        }, to: dir.appendingPathComponent("dot-accessories.png"))
        try write(board("Accessories on Rounded triangle (Charcoal)", columns: 3) {
            ForEach(DotAccessory.allCases) { a in
                Cell(design: DotDesign(shape: .roundedTriangle, color: .lime, accessory: a), label: a.label)
            }
        }, to: dir.appendingPathComponent("dot-accessories-triangle.png"))
        try write(board("Eyes", columns: 4) {
            ForEach(DotEyes.allCases) { e in Cell(design: DotDesign(shape: .circle, color: .blue, eyes: e), label: e.label) }
        }, to: dir.appendingPathComponent("dot-eyes.png"))
        try write(board("Glasses", columns: 3) {
            ForEach(DotGlasses.allCases) { g in Cell(design: DotDesign(shape: .circle, color: .teal, glasses: g), label: g.label) }
        }, to: dir.appendingPathComponent("dot-glasses.png"))
        try write(board("Colours: eye accent on ink (default) and colour body", columns: 3) {
            ForEach(DotColor.faceColors) { c in
                VStack(spacing: 6) {
                    HStack {
                        DotView(DotDesign(shape: .circle, color: c)).frame(width: 110, height: 110)
                        DotView(DotDesign(shape: .circle, color: c, fill: .colorBody)).frame(width: 110, height: 110)
                    }.padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    Text(c.label).font(.system(size: 13, weight: .medium))
                }
            }
        }, to: dir.appendingPathComponent("dot-colors.png"))
        try write(logoBoard(), to: dir.appendingPathComponent("logo-board.png"))
    }

    // MARK: Fit QA

    /// One labelled grid: rows are options, columns are the 11 shapes. Each cell is the light dot
    /// over its dark tile, so cuts and overhangs show on both grounds.
    struct FitGrid<Row: Identifiable>: View {
        let title: String
        let rows: [Row]
        let rowLabel: (Row) -> String
        let design: (DotShape, Row) -> DotDesign
        var shapes = DotShape.allCases
        var cell: CGFloat = 80
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Color(hex: 0x111111))
                HStack(spacing: 6) {
                    Text("").frame(width: 110)
                    ForEach(shapes) { shape in
                        Text(shape.label).font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0x444444))
                            .multilineTextAlignment(.center).frame(width: cell + 12, height: 28)
                    }
                }
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(rowLabel(row)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x222222))
                            .frame(width: 110, alignment: .leading)
                        ForEach(shapes) { shape in
                            VStack(spacing: 4) {
                                DotView(design(shape, row)).frame(width: cell, height: cell)
                                    .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                                DotTile(design(shape, row), size: cell + 12, dark: true)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .background(Color(hex: 0xEFEFEC))
        }
    }

    /// Debug overlay: the measured anchors drawn on every shape (seat line, ear points, neck, eye line).
    struct AnchorCell: View {
        let shape: DotShape
        var body: some View {
            let f = DotArt.face(of: shape), a = f.anchors
            Canvas { ctx, size in
                let k = size.width / 96
                ctx.scaleBy(x: k, y: k)
                ctx.fill(Path(f.body), with: .color(Color(hex: 0x222222)))
                func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ c: Color) {
                    var p = Path(); p.move(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x1, y: y1))
                    ctx.stroke(p, with: .color(c), lineWidth: 0.8)
                }
                func dot(_ x: CGFloat, _ y: CGFloat, _ c: Color) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1.8, y: y - 1.8, width: 3.6, height: 3.6)), with: .color(c))
                }
                line(f.hatX - f.seatHalf, a.seat, f.hatX + f.seatHalf, a.seat, .orange)
                dot(f.hatX, a.crown, .orange)
                dot(a.earL, f.earY, .cyan); dot(a.earR, f.earY, .cyan)
                line(a.earL, a.bandTop, a.earR, a.bandTop, .cyan.opacity(0.6))
                dot(f.eyeX, a.neck, .pink)
                line(a.eyeL, f.eyeY, a.eyeR, f.eyeY, .green)
            }
            .frame(width: 120, height: 120)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottom) { Text(shape.label).font(.system(size: 9)).foregroundStyle(.secondary).offset(y: 14) }
        }
    }

    static func renderFit(into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(FitGrid(title: "Accessories \u{00D7} shapes (accessory colour Coral)", rows: DotAccessory.allCases, rowLabel: \.label) { shape, a in
            DotDesign(shape: shape, color: .lime, accessory: a, accessoryColor: .coral)
        }, to: dir.appendingPathComponent("accessories-x-shapes.png"))
        try write(FitGrid(title: "Accessories \u{00D7} shapes (Charcoal)", rows: DotAccessory.allCases, rowLabel: \.label) { shape, a in
            DotDesign(shape: shape, color: .violet, accessory: a)
        }, to: dir.appendingPathComponent("accessories-x-shapes-charcoal.png"))
        try write(FitGrid(title: "Glasses \u{00D7} shapes", rows: DotGlasses.allCases, rowLabel: \.label) { shape, g in
            DotDesign(shape: shape, color: .teal, glasses: g)
        }, to: dir.appendingPathComponent("glasses-x-shapes.png"))
        // One sheet per option, in two lines of large cells, so every cell can be inspected.
        let rows = dir.appendingPathComponent("rows", isDirectory: true)
        try FileManager.default.createDirectory(at: rows, withIntermediateDirectories: true)
        let halves = [Array(DotShape.allCases.prefix(6)), Array(DotShape.allCases.dropFirst(6))]
        for a in DotAccessory.allCases where a != .none {
            try write(VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<2, id: \.self) { i in
                    FitGrid(title: i == 0 ? a.label : "", rows: [a], rowLabel: \.label, design: { shape, a in
                        DotDesign(shape: shape, color: .lime, accessory: a, accessoryColor: .coral)
                    }, shapes: halves[i], cell: 130)
                }
            }.background(Color(hex: 0xEFEFEC)), to: rows.appendingPathComponent("accessory-\(a.rawValue).png"))
        }
        for g in DotGlasses.allCases where g != .none {
            try write(VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<2, id: \.self) { i in
                    FitGrid(title: i == 0 ? g.label : "", rows: [g], rowLabel: \.label, design: { shape, g in
                        DotDesign(shape: shape, color: .teal, glasses: g)
                    }, shapes: halves[i], cell: 130)
                }
            }.background(Color(hex: 0xEFEFEC)), to: rows.appendingPathComponent("glasses-\(g.rawValue).png"))
        }
        try write(VStack(alignment: .leading, spacing: 12) {
            Text("Measured anchors: orange seat line and crown, cyan ear points and band clearance, pink neck, green eye line")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 16), count: 6), spacing: 30) {
                ForEach(DotShape.allCases) { AnchorCell(shape: $0) }
            }
        }.padding(24).background(Color(hex: 0xEFEFEC)), to: dir.appendingPathComponent("anchors.png"))
    }

    // MARK: Logo v2 board

    /// Five fresh default-logo candidates, each at 512 and 32 px (tiles) and as the menu bar glyph at
    /// 18 and 16 pt on light and dark bars, at Retina (2x) and 1x pixel density. The current default
    /// is the first row for comparison. Rendered at 1x so every pixel size on the board is literal.
    struct LogoV2Board: View {
        var rows: [(String, String, DotDesign)] {
            [("Previous default: Sound arcs", "For comparison. Replaced by 4. Mic.", DotDesign(signature: .hey))]
                + LogoV2.cases.enumerated().map { i, s in
                    let info = LogoV2.info(s)
                    return ("\(i + 1). \(info.name)", info.says, DotDesign(signature: s))
                }
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("HeyDot default logo, round 2: five candidates").font(.system(size: 30, weight: .bold))
                Text("flat vector style: one bold flat body, pill eyes, add-ons cut apart by a gutter. Tiles at 512 and 32 px; menu bar glyph at 18 and 16 pt, Retina (2x) and 1x, on light and dark bars, listening and needs-attention states.")
                    .font(.system(size: 15)).foregroundStyle(Color(hex: 0x555555)).frame(width: 1500, alignment: .leading)
                ForEach(rows, id: \.0) { name, says, design in
                    HStack(alignment: .center, spacing: 28) {
                        DotTile(design, size: 512, dark: true)
                        VStack(alignment: .leading, spacing: 18) {
                            Text(name).font(.system(size: 26, weight: .bold))
                            Text(says).font(.system(size: 16)).foregroundStyle(Color(hex: 0x444444)).frame(width: 900, alignment: .leading)
                            HStack(alignment: .bottom, spacing: 18) {
                                DotTile(design, size: 32, dark: true)
                                DotTile(design, size: 32, dark: false)
                                Text("32 px tiles").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach([false, true], id: \.self) { dark in bar(design, dark: dark) }
                        }
                    }
                    .padding(24)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
                }
            }
            .padding(40)
            .background(Color(hex: 0xEFEFEC))
        }

        /// A strip of real menu bar. Rasters are made exactly as the menu bar makes them (template image at
        /// 2x or 1x), then drawn pixel for pixel; the last group zooms the 16 px @1x raster 4x so single
        /// pixels can be judged.
        func bar(_ design: DotDesign, dark: Bool) -> some View {
            let ink = dark ? Color.white : Color.black
            func glyph(_ st: GlyphState, _ pt: CGFloat, scale: CGFloat, zoom: CGFloat = 1) -> some View {
                Image(nsImage: OneX.image(design, state: st, points: pt, scale: scale))
                    .resizable().interpolation(.none).renderingMode(.template).foregroundStyle(ink)
                    .frame(width: pt * scale * zoom, height: pt * scale * zoom)
            }
            func label(_ t: String) -> some View { Text(t).font(.system(size: 11)).foregroundStyle(ink.opacity(0.65)) }
            return HStack(spacing: 18) {
                ForEach([CGFloat(18), 16], id: \.self) { pt in
                    HStack(spacing: 8) { glyph(.listening, pt, scale: 2); glyph(.attention, pt, scale: 2); label("\(Int(pt)) pt @2x") }
                    HStack(spacing: 6) { glyph(.listening, pt, scale: 1); glyph(.attention, pt, scale: 1); label("\(Int(pt)) px") }
                }
                HStack(spacing: 8) { glyph(.listening, 16, scale: 1, zoom: 4); label("16 px, zoomed 4\u{00D7}") }
                Spacer(minLength: 0)
                label(dark ? "dark bar" : "light bar")
            }
            .padding(.horizontal, 14).frame(width: 900, height: 80)
            .background(dark ? Color(hex: 0x1E1E1E) : Color(hex: 0xECECEC), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// A true 1x glyph raster (what a non-Retina menu bar draws).
    @MainActor enum OneX {
        static func image(_ design: DotDesign, state: GlyphState, points: CGFloat, scale: CGFloat = 1) -> NSImage {
            let renderer = ImageRenderer(content: GlyphView(design: design, state: state).frame(width: points, height: points))
            renderer.scale = scale
            let image = renderer.nsImage ?? NSImage(size: NSSize(width: points, height: points))
            image.isTemplate = true
            return image
        }
    }

    static func renderLogosV2(into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(LogoV2Board(), to: dir.appendingPathComponent("board.png"), scale: 1)
    }

    static let logoCandidates: [(String, String, DotDesign)] = [
        ("A. Sound arcs", "A dot saying \u{201C}hey!\u{201D}: two arcs leave it like a voice.", DotDesign(signature: .hey)),
        ("B. Wave", "A dot waving a detached hand, with two motion ticks.", DotDesign(signature: .heyWave)),
        ("C. Speech bubble", "The dot itself is a speech bubble.", DotDesign(signature: .heyBubble)),
    ]

    static func logoBoard() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("HeyDot default logo: three candidates").font(.system(size: 22, weight: .bold))
            Text("Self-review at 16, 18, 32, 128 and 512 px. Template glyph rows are the menu bar rendering (2x).")
                .font(.system(size: 13)).foregroundStyle(Color(hex: 0x555555))
            ForEach(logoCandidates, id: \.0) { name, note, design in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name).font(.system(size: 16, weight: .semibold))
                        Text(note).font(.system(size: 13)).foregroundStyle(Color(hex: 0x555555))
                    }
                    HStack(alignment: .bottom, spacing: 22) {
                        DotTile(design, size: 256, dark: true)  // 512 px at 2x
                        DotTile(design, size: 64, dark: true)   // 128 px
                        DotView(design).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 16) {
                                ForEach([8, 9, 16] as [CGFloat], id: \.self) { s in
                                    DotTile(design, size: s, dark: true)
                                }
                                Text("tiles at 16 / 18 / 32 px").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                ForEach([GlyphState.listening, .paused, .attention], id: \.self) { st in
                                    GlyphView(design: design, state: st).frame(width: 18, height: 18)
                                        .foregroundStyle(.black)
                                }
                                Text("menu bar glyph 18 pt: listening, paused, needs attention").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(6).background(Color(hex: 0xE4E4E4), in: RoundedRectangle(cornerRadius: 6))
                            HStack(spacing: 16) {
                                ForEach([GlyphState.listening, .paused, .attention], id: \.self) { st in
                                    GlyphView(design: design, state: st).frame(width: 18, height: 18)
                                        .colorInvert()
                                }
                                Text("on a dark menu bar").font(.system(size: 11)).foregroundStyle(Color(hex: 0xBBBBBB))
                            }
                            .padding(6).background(Color(hex: 0x1E1E1E), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(28)
        .frame(width: 1000, alignment: .leading)
        .background(Color(hex: 0xEFEFEC))
    }
}
