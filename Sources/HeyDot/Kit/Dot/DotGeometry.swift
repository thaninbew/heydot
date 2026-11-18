import CoreGraphics
import Foundation

// All dot artwork, hand-authored on a 96-unit grid (y down). flat vector rules: one bold flat body,
// two pill eyes, and every add-on separated from the body by a cut gutter instead of an outline.

enum G {
    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, angle: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: angle * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
    }

    /// A stadium: the flat vector eye.
    static func pill(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, angle: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: angle * .pi / 180)
        let r = min(w, h) / 2
        return CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: &t)
    }

    static func roundedRect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    static func poly(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }

    /// Polygon with every corner filleted to radius r (clamped to half of each edge).
    static func roundedPoly(_ pts: [CGPoint], r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n = pts.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        p.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n {
            let corner = pts[i], next = pts[(i + 1) % n]
            p.addArc(tangent1End: corner, tangent2End: next, radius: r)
        }
        p.closeSubpath()
        return p
    }

    static func union(_ paths: [CGPath]) -> CGPath {
        guard var result = paths.first else { return CGMutablePath() }
        for path in paths.dropFirst() { result = result.union(path) }
        return result
    }

    static func stroke(_ path: CGPath, _ width: CGFloat, cap: CGLineCap = .round) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 4)
    }

    /// A thick elliptical arc band, angles in degrees (0 = +x, clockwise on screen because y is down).
    static func arc(_ cx: CGFloat, _ cy: CGFloat, rx: CGFloat, ry: CGFloat, from a0: CGFloat, to a1: CGFloat,
                    width: CGFloat, cap: CGLineCap = .round) -> CGPath {
        let p = CGMutablePath()
        let steps = 48
        for i in 0...steps {
            let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)) * .pi / 180
            let pt = CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return stroke(p, width, cap: cap)
    }

    /// Four-point sparkle.
    static func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let k = r * 0.22
        p.move(to: CGPoint(x: cx, y: cy - r))
        p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + k, y: cy - k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + k, y: cy + k))
        p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - k, y: cy + k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - k, y: cy - k))
        p.closeSubpath()
        return p
    }

    static func mirrored(_ path: CGPath) -> CGPath {
        var t = CGAffineTransform(translationX: 96, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &t) ?? path
    }

    static func points(_ ring: [CGPoint]) -> CGPath { poly(ring) }
}

/// A body plus the anchor points that eyes, glasses and accessories hang from.
/// Hand-set values say what each part *means* on this shape (where the eyes are, how wide a hat's
/// opening is, which line the ears are on). Everything else is measured from the body path itself,
/// so an accessory always meets the real outline instead of a guessed box.
struct Face {
    var body: CGPath
    // Eye line
    var eyeX: CGFloat = 48
    var eyeY: CGFloat
    var eyeGap: CGFloat = 8       // half the distance between eye centres
    var eyeW: CGFloat = 10.5
    var eyeH: CGFloat = 18
    // Head top: a hat's opening (half-width `seatHalf`, centred on `hatX`) slides down until it meets the body.
    var hatX: CGFloat = 48
    var seatHalf: CGFloat
    // Ears: the line headphone cups sit on.
    var earY: CGFloat
    /// Ears on top of the head (part of `body`). Headphones pass behind them: the cups sit on the head below
    /// the ears and the band is cut away around each ear, so the ears are never covered.
    var ears: CGPath?
    var earsOnTop: Bool { ears != nil }
    /// Degrees the headphone cups lean to lie flat on a sloped side (the triangle's); 0 is upright.
    var cupTilt: CGFloat = 0

    init(body: CGPath, eyeX: CGFloat = 48, eyeY: CGFloat, eyeGap: CGFloat = 8, eyeW: CGFloat = 10.5, eyeH: CGFloat = 18,
         hatX: CGFloat = 48, seatHalf: CGFloat, earY: CGFloat, ears: CGPath? = nil, cupTilt: CGFloat = 0) {
        self.body = body; self.eyeX = eyeX; self.eyeY = eyeY; self.eyeGap = eyeGap; self.eyeW = eyeW; self.eyeH = eyeH
        self.hatX = hatX; self.seatHalf = seatHalf; self.earY = earY; self.ears = ears; self.cupTilt = cupTilt
    }

    /// Measured anchors, all on the 96-unit grid.
    struct Anchors {
        var crown: CGFloat      // top of the head above hatX
        var seat: CGFloat       // y where the hat opening meets the head
        var earL: CGFloat       // outer body edges on the ear line
        var earR: CGFloat
        var bandTop: CGFloat    // highest head point a headphone band has to clear
        var neck: CGFloat       // bottom of the body under the eyes
        var eyeL: CGFloat       // body edges on the eye line (glasses must stay inside)
        var eyeR: CGFloat
    }

    var anchors: Anchors {
        let crown = Probe.top(body, x: hatX) ?? 20
        let seat = min(Probe.top(body, x: hatX - seatHalf) ?? 96, Probe.top(body, x: hatX + seatHalf) ?? 96, crown + 26)
        let ear = Probe.run(body, y: earY, around: eyeX) ?? (eyeX - 30, eyeX + 30)
        let eye = Probe.run(body, y: eyeY, around: eyeX) ?? (eyeX - 30, eyeX + 30)
        let bandTop: CGFloat = earsOnTop ? crown
            : stride(from: ear.0 + 6, through: ear.1 - 6, by: 1).compactMap { Probe.top(body, x: $0) }.min() ?? crown
        return Anchors(crown: crown, seat: seat, earL: ear.0, earR: ear.1, bandTop: bandTop,
                       neck: Probe.bottom(body, x: eyeX) ?? 88, eyeL: eye.0, eyeR: eye.1)
    }

    /// Accessory scale: 1 on the 20-unit seat of the Circle, clamped so tiny heads still read.
    var scale: CGFloat { max(0.7, min(1.15, seatHalf / 20)) }
}

/// Point probes on a body path (0.25-unit steps; bodies are cached, so this runs once per design).
enum Probe {
    static let step: CGFloat = 0.25
    static func top(_ p: CGPath, x: CGFloat) -> CGFloat? {
        stride(from: CGFloat(0), through: 96, by: step).first { p.contains(CGPoint(x: x, y: $0)) }
    }
    static func bottom(_ p: CGPath, x: CGFloat) -> CGFloat? {
        stride(from: CGFloat(96), through: 0, by: -step).first { p.contains(CGPoint(x: x, y: $0)) }
    }
    /// The contiguous run of body on row `y` that contains `x`.
    static func run(_ p: CGPath, y: CGFloat, around x: CGFloat) -> (CGFloat, CGFloat)? {
        guard p.contains(CGPoint(x: x, y: y)) else { return nil }
        var l = x, r = x
        while l > 0, p.contains(CGPoint(x: l - step, y: y)) { l -= step }
        while r < 96, p.contains(CGPoint(x: r + step, y: y)) { r += step }
        return (l, r)
    }
}

public enum LayerRole: Sendable { case body, eye, highlight, line, accessory, glint }

public struct DotLayer: @unchecked Sendable {
    public let path: CGPath
    public let role: LayerRole
}

enum DotArt {
    static func face(_ d: DotDesign) -> Face {
        switch d.signature {
        case .hey:
            return Face(body: G.circle(40, 57, 29), eyeX: 40, eyeY: 62, hatX: 40, seatHalf: 18, earY: 58)
        case .heyWave:
            return Face(body: G.circle(42, 58, 30), eyeX: 42, eyeY: 63, hatX: 42, seatHalf: 19, earY: 59)
        case .heyBubble:
            let bubble = G.union([G.circle(48, 48, 33), G.roundedPoly([CGPoint(x: 24, y: 62), CGPoint(x: 13, y: 92), CGPoint(x: 46, y: 78)], r: 3)])
            return Face(body: bubble, eyeY: 52, seatHalf: 21, earY: 48)
        case let s? where LogoV2.cases.contains(s):
            return LogoV2.face(s)
        case nil, .some:
            return face(of: d.shape)
        }
    }

    static func face(of shape: DotShape) -> Face {
        switch shape {
        case .circle:
            return Face(body: G.circle(48, 53, 32), eyeY: 59, seatHalf: 20, earY: 55)
        case .roundedTriangle:
            // The cups lean with the sides (about 33 degrees from upright) so they lie on the slope.
            return Face(body: G.points([CGPoint(x: 37.78, y: 38.65), CGPoint(x: 39.24, y: 36.44), CGPoint(x: 40.7, y: 34.57), CGPoint(x: 42.16, y: 33.04), CGPoint(x: 43.62, y: 31.85), CGPoint(x: 45.08, y: 31), CGPoint(x: 46.54, y: 30.49), CGPoint(x: 48, y: 30.32), CGPoint(x: 49.46, y: 30.49), CGPoint(x: 50.92, y: 31), CGPoint(x: 52.38, y: 31.85), CGPoint(x: 53.84, y: 33.04), CGPoint(x: 55.3, y: 34.57), CGPoint(x: 56.76, y: 36.44), CGPoint(x: 58.22, y: 38.65), CGPoint(x: 79.77, y: 73.72), CGPoint(x: 81.21, y: 76.24), CGPoint(x: 82.31, y: 78.57), CGPoint(x: 83.08, y: 80.71), CGPoint(x: 83.52, y: 82.67), CGPoint(x: 83.62, y: 84.45), CGPoint(x: 83.39, y: 86.03), CGPoint(x: 82.83, y: 87.43), CGPoint(x: 81.93, y: 88.64), CGPoint(x: 80.7, y: 89.67), CGPoint(x: 79.14, y: 90.51), CGPoint(x: 77.24, y: 91.16), CGPoint(x: 75.01, y: 91.63), CGPoint(x: 72.44, y: 91.91), CGPoint(x: 69.55, y: 92), CGPoint(x: 26.45, y: 92), CGPoint(x: 23.56, y: 91.91), CGPoint(x: 20.99, y: 91.63), CGPoint(x: 18.76, y: 91.16), CGPoint(x: 16.86, y: 90.51), CGPoint(x: 15.3, y: 89.67), CGPoint(x: 14.07, y: 88.64), CGPoint(x: 13.17, y: 87.43), CGPoint(x: 12.61, y: 86.03), CGPoint(x: 12.38, y: 84.45), CGPoint(x: 12.48, y: 82.67), CGPoint(x: 12.92, y: 80.71), CGPoint(x: 13.69, y: 78.57), CGPoint(x: 14.79, y: 76.24), CGPoint(x: 16.23, y: 73.72)]), eyeY: 67, seatHalf: 13, earY: 66, cupTilt: 33)
        case .capsule:
            return Face(body: G.roundedRect(25, 14, 71, 90, r: 23), eyeY: 56, seatHalf: 17, earY: 54)
        case .roundedHeadTwoEars:
            let head = G.roundedRect(14, 32, 82, 88, r: 25)
            let ear = G.roundedPoly([CGPoint(x: 15, y: 52), CGPoint(x: 19, y: 12), CGPoint(x: 47, y: 35)], r: 5)
            let ears = G.union([ear, G.mirrored(ear)])
            return Face(body: G.union([head, ears]), eyeY: 62, eyeGap: 9, seatHalf: 12, earY: 62, ears: ears)
        case .sixLobedFlower:
            let petals = (0..<6).map { k -> CGPath in
                let a = (CGFloat(k) * 60 - 90) * .pi / 180
                return G.circle(48 + 20 * cos(a), 52 + 20 * sin(a), 14.5)
            }
            return Face(body: G.union([G.circle(48, 52, 23)] + petals), eyeY: 56, seatHalf: 16, earY: 54)
        case .heart:
            let point = G.roundedPoly([CGPoint(x: 48, y: 29.7), CGPoint(x: 76.3, y: 58), CGPoint(x: 48, y: 87), CGPoint(x: 19.7, y: 58)], r: 5)
            return Face(body: G.union([point, G.circle(33.9, 43.9, 20), G.circle(62.1, 43.9, 20)]), eyeY: 55, seatHalf: 18, earY: 50)
        case .fourLobedButterfly:
            let upper = G.ellipse(29, 36, 19, 15, angle: -28)
            let lower = G.ellipse(33, 71, 14, 11.5, angle: 28)
            // The upper wings are the head's widest line, so headphone cups hug their sides there.
            return Face(body: G.union([G.circle(48, 54, 21), upper, G.mirrored(upper), lower, G.mirrored(lower)]), eyeY: 56,
                        seatHalf: 11, earY: 38)
        case .circleTwoEars:
            let ears = G.union([G.circle(23, 31, 12.5), G.mirrored(G.circle(23, 31, 12.5))])
            return Face(body: G.union([G.circle(48, 58, 30), ears]), eyeY: 62, eyeGap: 8.5, seatHalf: 13,
                        earY: 60, ears: ears)
        case .twelveScallopedRosette:
            let scallops = (0..<12).map { k -> CGPath in
                let a = (CGFloat(k) * 30 - 90) * .pi / 180
                return G.circle(48 + 30 * cos(a), 52 + 30 * sin(a), 8)
            }
            return Face(body: G.union([G.circle(48, 52, 30)] + scallops), eyeY: 56, seatHalf: 20, earY: 54)
        case .hexagon:
            return Face(body: G.points([CGPoint(x: 16.51, y: 43.88), CGPoint(x: 16.86, y: 42.56), CGPoint(x: 17.27, y: 41.33), CGPoint(x: 17.75, y: 40.18), CGPoint(x: 18.3, y: 39.12), CGPoint(x: 18.91, y: 38.14), CGPoint(x: 19.6, y: 37.25), CGPoint(x: 20.35, y: 36.44), CGPoint(x: 21.17, y: 35.72), CGPoint(x: 22.06, y: 35.08), CGPoint(x: 23.01, y: 34.53), CGPoint(x: 24.03, y: 34.06), CGPoint(x: 25.12, y: 33.68), CGPoint(x: 26.28, y: 33.38), CGPoint(x: 27.51, y: 33.17), CGPoint(x: 28.8, y: 33.04), CGPoint(x: 30.16, y: 33), CGPoint(x: 65.84, y: 33), CGPoint(x: 67.2, y: 33.04), CGPoint(x: 68.49, y: 33.17), CGPoint(x: 69.72, y: 33.38), CGPoint(x: 70.88, y: 33.68), CGPoint(x: 71.97, y: 34.06), CGPoint(x: 72.99, y: 34.53), CGPoint(x: 73.94, y: 35.08), CGPoint(x: 74.83, y: 35.72), CGPoint(x: 75.65, y: 36.44), CGPoint(x: 76.4, y: 37.25), CGPoint(x: 77.09, y: 38.14), CGPoint(x: 77.7, y: 39.12), CGPoint(x: 78.25, y: 40.18), CGPoint(x: 78.73, y: 41.33), CGPoint(x: 79.14, y: 42.56), CGPoint(x: 79.49, y: 43.88), CGPoint(x: 84.55, y: 66.06), CGPoint(x: 84.65, y: 67.42), CGPoint(x: 84.56, y: 68.21), CGPoint(x: 84.36, y: 68.98), CGPoint(x: 83.91, y: 69.99), CGPoint(x: 74.98, y: 86.34), CGPoint(x: 74.33, y: 87.25), CGPoint(x: 73.22, y: 88.37), CGPoint(x: 72.38, y: 88.96), CGPoint(x: 70.98, y: 89.59), CGPoint(x: 69.94, y: 89.85), CGPoint(x: 68.25, y: 90), CGPoint(x: 27.75, y: 90), CGPoint(x: 26.06, y: 89.85), CGPoint(x: 25.02, y: 89.59), CGPoint(x: 23.62, y: 88.96), CGPoint(x: 22.78, y: 88.37), CGPoint(x: 21.67, y: 87.25), CGPoint(x: 21.02, y: 86.34), CGPoint(x: 12.09, y: 69.99), CGPoint(x: 11.64, y: 68.98), CGPoint(x: 11.44, y: 68.21), CGPoint(x: 11.35, y: 66.88), CGPoint(x: 11.45, y: 66.06)]), eyeY: 57, eyeGap: 11, eyeW: 11, seatHalf: 19, earY: 56)
        case .roundedDiamond:
            return Face(body: G.roundedPoly([CGPoint(x: 48, y: 9), CGPoint(x: 87, y: 52), CGPoint(x: 48, y: 95), CGPoint(x: 9, y: 52)], r: 13),
                        eyeY: 55, seatHalf: 12, earY: 54)
        }
    }
    /// Extra body-coloured parts of a signature (the logo's sound arcs or wave).
    static func signatureExtras(_ d: DotDesign) -> [CGPath] {
        switch d.signature {
        case .hey:
            return [G.arc(40, 57, rx: 38, ry: 38, from: -62, to: -18, width: 6.5),
                    G.arc(40, 57, rx: 50, ry: 50, from: -56, to: -24, width: 6.5)]
        case .heyWave:
            let hand = G.pill(80, 25, 12, 23, angle: 28)
            return [hand, G.pill(88, 7, 3.6, 9, angle: 55), G.pill(94, 22, 3.6, 9, angle: 95)]
        case let s?:
            return LogoV2.extras(s)
        default:
            return []
        }
    }

    // MARK: Eyes

    static func eyes(_ style: DotEyes, _ f: Face) -> (shape: CGPath, highlights: [CGPath]) {
        var shapes: [CGPath] = []
        var lights: [CGPath] = []
        for side in [CGFloat(-1), 1] {
            let x = f.eyeX + side * f.eyeGap, y = f.eyeY, w = f.eyeW, h = f.eyeH
            switch style {
            case .oval:
                shapes.append(G.pill(x, y, w, h))
            case .sweptLids:
                let cut = G.poly([CGPoint(x: x - side * w, y: y - h / 2 - 0.5), CGPoint(x: x + side * w, y: y - h / 2 + 8.5),
                                  CGPoint(x: x + side * w, y: y - h), CGPoint(x: x - side * w, y: y - h)])
                shapes.append(G.pill(x, y, w, h).subtracting(cut))
            case .sparkleCapsules:
                shapes.append(G.pill(x, y, w, h))
                lights.append(G.sparkle(x - 0.6, y - 3.2, 3.9))
            case .highlightCapsules:
                shapes.append(G.pill(x, y, w, h))
                lights.append(G.circle(x - 1.4, y - 4.4, 2.2))
            case .dots:
                shapes.append(G.circle(x, y + 1, 5.6))
            case .roundHighlights:
                shapes.append(G.circle(x, y + 1, 7.3))
                lights.append(G.circle(x - 2.4, y - 1.6, 2.3))
            case .crescentInset:
                let disc = G.circle(x, y + 1, 7.3)
                shapes.append(disc.subtracting(G.circle(x + side * 2.2, y - 3.4, 5.6)))
            case .sleepyLids:
                let cut = G.roundedRect(x - w, y - h, x + w, y - 0.5, r: 0)
                shapes.append(G.pill(x, y, w, h).subtracting(cut))
            }
        }
        return (G.union(shapes), lights)
    }

    // MARK: Glasses

    /// Glasses hang from the eye line. Any style wider than the head at that line is scaled down about
    /// the eye centre so the frames stay on the face. The monocle's ring slides in (up to 2 units) and then
    /// shrinks until it and its gutter stay inside the outline on every row; its chain may dangle past the edge.
    static func glasses(_ style: DotGlasses, _ f: Face, gutter: CGFloat = 2.6) -> (frames: CGPath?, glints: [CGPath]) {
        let (frames, glints) = glassesUnscaled(style, f)
        if style == .monocle, let frames {
            let mx = f.eyeX + f.eyeGap + 1.6, y = f.eyeY
            func over(_ shift: CGFloat, _ k: CGFloat) -> CGFloat {
                stride(from: CGFloat(-10), through: 10, by: 1).compactMap { dy -> CGFloat? in
                    let yy = y + dy * k
                    guard let run = Probe.run(f.body, y: yy, around: f.eyeX) else { return nil }
                    let ring = mx - shift + (8.2 * (1 - (dy / 11.2) * (dy / 11.2)).squareRoot() + 1.3) * k
                    return ring + gutter + 3.5 - run.1  // keep a readable band of body outside the cut, never a sliver
                }.max() ?? 0
            }
            let fits = [CGFloat(0), 1, 2].flatMap { sh in stride(from: CGFloat(1), through: 0.8, by: -0.05).map { (sh, $0) } }
            guard let (sh, k) = fits.first(where: { over($0.0, $0.1) <= 0 }) ?? fits.last, sh != 0 || k != 1 else { return (frames, glints) }
            var t = CGAffineTransform(translationX: mx - sh, y: y).scaledBy(x: k, y: k).translatedBy(x: -mx, y: -y)
            return (frames.copy(using: &t), glints)
        }
        guard let frames else { return (frames, glints) }
        let a = f.anchors, box = frames.boundingBoxOfPath
        let room = min(f.eyeX - a.eyeL, a.eyeR - f.eyeX) - 1.5
        let need = max(f.eyeX - box.minX, box.maxX - f.eyeX)
        guard need > room, room > 0 else { return (frames, glints) }
        let k = room / need
        var t = CGAffineTransform(translationX: f.eyeX, y: f.eyeY).scaledBy(x: k, y: k).translatedBy(x: -f.eyeX, y: -f.eyeY)
        return (frames.copy(using: &t), glints.compactMap { $0.copy(using: &t) })
    }

    static func glassesUnscaled(_ style: DotGlasses, _ f: Face) -> (frames: CGPath?, glints: [CGPath]) {
        let y = f.eyeY, r = f.eyeX + f.eyeGap
        let spread = f.eyeGap + 1.6
        let lx = f.eyeX - spread, rx = f.eyeX + spread
        switch style {
        case .none:
            return (nil, [])
        case .monocle:
            let mx = r + 1.6
            let ring = G.stroke(G.ellipse(mx, y, 8.2, 11.2), 2.6)
            let chain = CGMutablePath()
            chain.move(to: CGPoint(x: mx + 6.5, y: y + 8))
            chain.addQuadCurve(to: CGPoint(x: mx + 12, y: y + 27), control: CGPoint(x: mx + 14, y: y + 15))
            return (G.union([ring, G.stroke(chain, 1.8)]), [])
        case .tallOvalFrames:
            let rings = [G.stroke(G.ellipse(lx, y, 7.8, 12.6), 2.6), G.stroke(G.ellipse(rx, y, 7.8, 12.6), 2.6)]
            return (G.union(rings), [])
        case .separateTrapezoidLenses:
            func lens(_ cx: CGFloat) -> CGPath {
                G.stroke(G.roundedPoly([CGPoint(x: cx - 8.4, y: y - 9), CGPoint(x: cx + 8.4, y: y - 9),
                                        CGPoint(x: cx + 6, y: y + 9.5), CGPoint(x: cx - 6, y: y + 9.5)], r: 2.5), 2.4)
            }
            return (G.union([lens(f.eyeX - f.eyeGap - 2.6), lens(f.eyeX + f.eyeGap + 2.6)]), [])
        case .classicSunglasses:
            func lens(_ cx: CGFloat) -> CGPath {
                G.roundedPoly([CGPoint(x: cx - 10.5, y: y - 7), CGPoint(x: cx + 10.5, y: y - 7),
                               CGPoint(x: cx + 8, y: y + 7.5), CGPoint(x: cx - 7, y: y + 7.5)], r: 3.5)
            }
            let left = lens(lx), right = G.mirrored(lens(96 - rx))
            let brow = G.roundedRect(lx - 10.5, y - 8, rx + 10.5, y - 3.5, r: 2)
            return (G.union([left, right, brow]), [G.pill(lx + 3.5, y + 1, 2.4, 7, angle: 35), G.pill(rx + 3.5, y + 1, 2.4, 7, angle: 35)])
        case .roundSunglasses:
            let bridge = G.arc(f.eyeX, y - 2, rx: 4.5, ry: 3.5, from: 200, to: 340, width: 2.2)
            return (G.union([G.circle(lx, y, 9.2), G.circle(rx, y, 9.2), bridge]),
                    [G.pill(lx + 3, y - 2.5, 2.4, 6.5, angle: 40), G.pill(rx + 3, y - 2.5, 2.4, 6.5, angle: 40)])
        }
    }

    // MARK: Accessories

    /// An accessory's filled shape, an optional detail cut into it, an optional region of body it
    /// hides (the part of the head inside a crown, which would otherwise show between its points) and an
    /// optional region it fills with body (a dip under a hat's opening).
    struct Piece { var shape: CGPath; var details: CGPath? = nil; var hides: CGPath? = nil; var fills: CGPath? = nil }

    /// Body under a hat's opening where the head dips below it (between a butterfly's upper wings or a
    /// cat's ears), so no sliver of background shows between the hat and the head.
    static func notchFill(_ f: Face, _ a: Face.Anchors) -> CGPath? {
        a.crown > a.seat + 1 ? G.roundedRect(f.hatX - f.seatHalf, a.seat, f.hatX + f.seatHalf, a.crown + 1, r: 0) : nil
    }

    static func accessory(_ d: DotDesign, _ f: Face, gutter: CGFloat = 2.6) -> Piece? {
        let a = f.anchors, s = f.scale, x = f.hatX
        let w = f.seatHalf
        switch d.accessory {
        case .none:
            return nil
        case .headphones:
            // Cups straddle the head on the ear line. The band is a half-ellipse on two straight legs; its
            // centre height and radius are searched so it clears the head by a gutter everywhere and sits as
            // low as possible. Ears on top stay in front: the band is measured against the head alone and
            // cut away around each ear, so it reads as passing behind them.
            let head = f.ears.map { f.body.subtracting($0) } ?? f.body
            let ear = Probe.run(head, y: f.earY, around: f.eyeX) ?? (a.earL, a.earR)
            // A leaning cup sits where the slope is narrow but the head is not, so it keeps a fixed size.
            let k = f.cupTilt != 0 ? 1.05 : max(0.75, min(1.1, (ear.1 - ear.0) / 64))
            let cupW = 11 * k, cupH = 25 * k, band = 6.5 * k
            let cy = f.earY + 2, cupTop = cy - cupH / 2
            let cx = (ear.0 + ear.1) / 2
            let headTop = stride(from: ear.0 + 6, through: ear.1 - 6, by: 1).compactMap { Probe.top(head, x: $0) }.min() ?? a.crown
            let rows = stride(from: headTop, through: f.earY, by: 1)
            let half = rows.compactMap { Probe.run(head, y: $0, around: cx) }.map { max(cx - $0.0, $0.1 - cx) }.max() ?? (ear.1 - ear.0) / 2
            // Cup centres sit on the outline; a leaning cup's upper end moves in along the slope, and the band's
            // legs start there.
            let tilt = f.cupTilt * .pi / 180
            let cupX = f.cupTilt == 0 ? half + 0.5 : (Probe.run(head, y: cy, around: cx).map { max(cx - $0.0, $0.1 - cx) } ?? half) + 0.5
            let reach = cupH / 2 - 4
            let rx = cupX - reach * sin(tilt), legY = cy - reach * cos(tilt)
            let clearance = band / 2 + 3.5
            var best: (yc: CGFloat, ry: CGFloat)?
            for yc in stride(from: legY, through: headTop + 6, by: -2) {
                var ry = rx * 0.55
                for x in stride(from: cx - rx, through: cx + rx, by: 1) {
                    let u = (x - cx) / rx
                    guard abs(u) <= 0.92, let top = Probe.top(head, x: x), top < yc else { continue }
                    ry = max(ry, (yc - top + clearance) / (1 - u * u).squareRoot())
                }
                if best == nil || yc - ry > best!.yc - best!.ry { best = (yc, ry) }
            }
            let (yc, ry) = best ?? (cupTop, rx)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx - rx, y: legY))
            path.addLine(to: CGPoint(x: cx - rx, y: yc))
            for i in 1...48 {
                let t = CGFloat.pi + CGFloat.pi * CGFloat(i) / 48
                path.addLine(to: CGPoint(x: cx + rx * cos(t), y: yc + ry * sin(t)))
            }
            path.addLine(to: CGPoint(x: cx + rx, y: legY))
            var arc = G.stroke(path, band, cap: .butt)
            if let ears = f.ears {
                // Hide the band behind each ear and everything outside it on the ear's rows, and the legs below
                // the ears, so only the crown between the ears shows and no sliver runs along an ear's edge.
                let left = ears.intersection(G.roundedRect(0, 0, cx, 96, r: 0)), right = ears.intersection(G.roundedRect(cx, 0, 96, 96, r: 0))
                func smear(_ p: CGPath, _ dx: CGFloat) -> CGPath {
                    G.union((0...12).compactMap { i -> CGPath? in var t = CGAffineTransform(translationX: dx * CGFloat(i), y: 0); return p.copy(using: &t) })
                }
                let earTop = ears.boundingBoxOfPath.minY
                let behind = G.union([smear(left, -3), smear(right, 3),
                                      G.roundedRect(0, earTop, cx - rx + band, legY + 1, r: 0), G.roundedRect(cx + rx - band, earTop, 96, legY + 1, r: 0)])
                arc = arc.subtracting(behind.union(G.stroke(behind, 2 * gutter + 0.6)))
            }
            let cups = [G.pill(cx - cupX, cy, cupW, cupH, angle: f.cupTilt), G.pill(cx + cupX, cy, cupW, cupH, angle: -f.cupTilt)]
            return Piece(shape: G.union([arc] + cups))
        case .bowTie:
            let y = a.neck - 1.5 * s, k = max(0.8, s)
            let wing = G.roundedPoly([CGPoint(x: f.eyeX - 15 * k, y: y - 9 * k), CGPoint(x: f.eyeX - 2 * k, y: y),
                                      CGPoint(x: f.eyeX - 15 * k, y: y + 9 * k)], r: 3 * k)
            var t = CGAffineTransform(translationX: 2 * f.eyeX, y: 0).scaledBy(x: -1, y: 1)
            let right = wing.copy(using: &t) ?? wing
            return Piece(shape: G.union([wing, right, G.pill(f.eyeX, y, 8 * k, 10 * k)]))
        case .beanie:
            let bw = w + 3 * s, cuffTop = a.seat - 5 * s, cuffBottom = a.seat + 4 * s
            let domeH = max(18 * s, cuffTop - a.crown + 5)
            let dome = G.ellipse(x, cuffTop + 1, bw - 1, domeH).intersection(G.roundedRect(x - bw - 2, cuffTop - domeH - 2, x + bw + 2, cuffTop + 1, r: 0))
            let cuff = G.roundedRect(x - bw, cuffTop, x + bw, cuffBottom, r: 4.5 * s)
            let pom = G.circle(x, cuffTop - domeH - 1, 5.5 * s)
            return Piece(shape: G.union([dome, cuff, pom]), details: G.stroke(lineAcross(x - bw, x + bw, cuffTop + 0.5), 1.6 * s),
                         fills: notchFill(f, a))
        case .hat:
            let brimY = a.seat + 1
            let top = min(brimY - 22 * s, a.crown - 6)
            let brim = G.pill(x, brimY, 2 * w + 16 * s, 7.5 * s)
            let crown = G.roundedRect(x - w + 1, top, x + w - 1, brimY, r: 3 * s)
            return Piece(shape: G.union([brim, crown]), details: G.stroke(lineAcross(x - w, x + w, brimY - 6.5 * s), 2.2 * s, cap: .butt),
                         fills: notchFill(f, a))
        case .beret:
            let ry = 9.5 * s, rx = w + 8 * s
            let cy = min(a.seat - 5 * s, a.crown + ry - 3)
            let body = G.ellipse(x + 2 * s, cy, rx, ry, angle: -7)
            return Piece(shape: G.union([body, G.pill(x + 3 * s, cy - ry - 2.5 * s, 3.6 * s, 7 * s, angle: 15)]), fills: notchFill(f, a))
        case .bulb:
            let k = max(0.8, s), cy = a.crown - 17 * k
            let bulb = G.circle(x, cy, 11 * k)
            let neck = G.roundedRect(x - 5.6 * k, cy + 6 * k, x + 5.6 * k, cy + 15 * k, r: 2.5 * k)
            let rays = [G.pill(x - 18.5 * k, cy - 5 * k, 3.2 * k, 8 * k, angle: -60), G.pill(x + 18.5 * k, cy - 5 * k, 3.2 * k, 8 * k, angle: 60),
                        G.pill(x, cy - 18.5 * k, 3.2 * k, 7.5 * k)]
            return Piece(shape: G.union([bulb, neck] + rays), details: G.stroke(lineAcross(x - 6 * k, x + 6 * k, cy + 10.8 * k), 1.6 * k, cap: .butt))
        case .tuft:
            let k = max(0.8, s), t = a.crown + 3
            let leaves = [G.ellipse(x - 1 * k, t - 9 * k, 4.6 * k, 11 * k, angle: -8), G.ellipse(x - 9 * k, t - 5 * k, 3.8 * k, 8.5 * k, angle: -42),
                          G.ellipse(x + 8 * k, t - 6 * k, 3.8 * k, 9 * k, angle: 34)]
            return Piece(shape: G.union(leaves))
        case .crown:
            let cw = w + 1, base = a.seat + 3 * s, h = max(20 * s, base - a.crown + 5)
            let pts = [CGPoint(x: x - cw, y: base), CGPoint(x: x - cw - 2 * s, y: base - h + 1), CGPoint(x: x - cw / 2, y: base - h * 0.5),
                       CGPoint(x: x, y: base - h - 1), CGPoint(x: x + cw / 2, y: base - h * 0.5), CGPoint(x: x + cw + 2 * s, y: base - h + 1),
                       CGPoint(x: x + cw, y: base)]
            return Piece(shape: G.roundedPoly(pts, r: 1.8 * s), hides: G.roundedRect(x - cw - 2, base - h - 2, x + cw + 2, base, r: 0),
                         fills: notchFill(f, a))
        }
    }

    private static func lineAcross(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0 - 4, y: y)); p.addLine(to: CGPoint(x: x1 + 4, y: y))
        return p
    }

    // MARK: Composition

    /// Builds the dot as ordered, already-cut layers inside a 96 x 96 box.
    /// `gutter` is the cut between body and add-ons; the menu bar glyph uses a wider one.
    static func layers(_ d: DotDesign, gutter: CGFloat = 2.6) -> [DotLayer] {
        var f = face(d)
        // The designer's hinted glyph has wider-set, narrower eye holes.
        if d.signature == .mic && gutter >= 4 { f.eyeGap = 10.5; f.eyeW = 10 }
        let extras = signatureExtras(d)
        var body = f.body
        if d.signature == .mic {
            for part in extras { body = body.subtracting(part.union(G.stroke(part, 2 * gutter))) }
        }
        var layers = [DotLayer(path: G.union([body] + extras), role: .body)]

        func cut(by path: CGPath) {
            let cutter = path.union(G.stroke(path, 2 * gutter))
            layers = layers.map { DotLayer(path: $0.path.subtracting(cutter), role: $0.role) }
        }

        var (eyeShape, lights) = eyes(d.eyes, f)
        if let s = d.signature, case let extra = LogoV2.features(s), !extra.isEmpty { eyeShape = G.union([eyeShape] + extra) }
        layers[0] = DotLayer(path: layers[0].path.subtracting(eyeShape), role: .body)
        layers.append(DotLayer(path: eyeShape, role: .eye))
        for light in lights { layers.append(DotLayer(path: light.intersection(eyeShape), role: .highlight)) }

        let (frames, glints) = glasses(d.glasses, f, gutter: gutter)
        if let frames {
            cut(by: frames)
            layers.append(DotLayer(path: frames, role: .line))
            for glint in glints { layers.append(DotLayer(path: glint.intersection(frames), role: .glint)) }
        }

        if let piece = accessory(d, f, gutter: gutter) {
            if let fills = piece.fills { layers[0] = DotLayer(path: layers[0].path.union(fills), role: .body) }
            // The head inside a crown is hidden, so an apex or ear tip never pokes through between its points.
            if let hides = piece.hides {
                layers = layers.map { DotLayer(path: $0.path.subtracting(hides), role: $0.role) }
            }
            cut(by: piece.shape)
            let shape = piece.details.map { piece.shape.subtracting($0) } ?? piece.shape
            layers.append(DotLayer(path: shape, role: .accessory))
        }
        return fit(layers.filter { !$0.path.isEmpty })
    }

    /// Scales everything down (about its centre) only when add-ons push it past a 3-unit margin.
    static func fit(_ layers: [DotLayer], margin: CGFloat = 3) -> [DotLayer] {
        let bounds = layers.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        guard !bounds.isNull else { return layers }
        let box = CGRect(x: margin, y: margin, width: 96 - 2 * margin, height: 96 - 2 * margin)
        if box.contains(bounds) { return layers }
        let s = min(1, box.width / bounds.width, box.height / bounds.height)
        let dx = 48 - bounds.midX * s
        let dy = min(max(48 - bounds.midY * s, box.minY - bounds.minY * s), box.maxY - bounds.maxY * s)
        var t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
        return layers.map { DotLayer(path: $0.path.copy(using: &t) ?? $0.path, role: $0.role) }
    }
}
