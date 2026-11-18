import CoreGraphics

/// The round-2 default-logo candidates. The owner picked `.mic`, refined as round 3’s "8. Open cradle";
/// the others stay for the review board. Same rules as every dot: one bold flat body, pill eyes,
/// add-ons separated by a cut gutter, readable as a template glyph at 16 to 18 px.
enum LogoV2 {
    static let cases: [DotSignature] = [.exclaim, .perk, .callOut, .mic, .sunrise]

    static func info(_ s: DotSignature) -> (name: String, says: String) {
        switch s {
        case .exclaim: ("Exclaim", "The dot is the point of a \u{201C}Hey!\u{201D}: a tall body with eyes over its own full stop.")
        case .perk: ("Perk", "One antenna springs up: the dot just heard its name and woke.")
        case .callOut: ("Call out", "Eyes up, mouth open: the dot calling back \u{201C}hey!\u{201D}.")
        case .mic: ("Mic", "The dot is a microphone head in its cradle: it is the thing listening.")
        case .sunrise: ("Wake", "A dot rising over the horizon, three rays: waking up.")
        default: ("", "")
        }
    }

    static func face(_ s: DotSignature) -> Face {
        switch s {
        case .exclaim:
            return Face(body: G.roundedRect(29, 6, 67, 66, r: 19), eyeY: 38, seatHalf: 15, earY: 38)
        case .perk:
            return Face(body: G.circle(46, 60, 31), eyeX: 46, eyeY: 64, hatX: 46, seatHalf: 19, earY: 60)
        case .callOut:
            return Face(body: G.circle(48, 52, 35), eyeY: 43, eyeGap: 8.5, eyeW: 10, eyeH: 16, seatHalf: 21, earY: 50)
        case .mic:
            return Face(body: G.roundedRect(28, 4, 68, 62, r: 20), eyeY: 34, eyeGap: 9.5, eyeW: 11, eyeH: 16, seatHalf: 17, earY: 34)
        case .sunrise:
            let half = G.circle(48, 64, 31).intersection(G.roundedRect(0, 0, 96, 70, r: 0))
            return Face(body: half, eyeY: 53, seatHalf: 19, earY: 58)
        default:
            return DotArt.face(of: .circle)
        }
    }

    /// Body-coloured parts that are not the head (cut apart from it by the same gutter as add-ons).
    static func extras(_ s: DotSignature) -> [CGPath] {
        switch s {
        case .exclaim:
            return [G.circle(48, 83, 10)]
        case .perk:
            let stalk = CGMutablePath()
            stalk.move(to: CGPoint(x: 55, y: 34))
            stalk.addQuadCurve(to: CGPoint(x: 66, y: 15), control: CGPoint(x: 57, y: 22))
            return [G.stroke(stalk, 7.5), G.circle(69, 11, 8)]
        case .mic:
            let cradle = G.arc(48, 37, rx: 31, ry: 32, from: 35, to: 145, width: 7.5)
            return [cradle, G.roundedRect(44.25, 72.75, 51.75, 85, r: 1.5), G.pill(48, 88.5, 36, 7.5)]
        case .sunrise:
            let rays = [(-90.0, 0.0), (-140.0, -50.0), (-40.0, 50.0)].map { a, tilt -> CGPath in
                let r = a * .pi / 180
                return G.pill(48 + 42 * cos(r), 64 + 42 * sin(r), 7, 13, angle: tilt)
            }
            return rays + [G.pill(48, 81, 84, 8)]
        default:
            return []
        }
    }

    /// Extra features painted like eyes (cut out of the body; accent coloured).
    static func features(_ s: DotSignature) -> [CGPath] {
        s == .callOut ? [G.ellipse(48, 67, 7.5, 8.5)] : []
    }
}
