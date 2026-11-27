import AppKit
import QuartzCore
import SwiftUI

/// The app tile, floating 9 pt with a ±1.2° sway on a 6 s loop. The tile is drawn by `DotTile` exactly as
/// everywhere else, rendered once into a layer, and only that layer moves.
struct FloatingTile: View {
    let design: DotDesign
    let size: CGFloat
    var dark: Bool?
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
        tile.shadowColor = NSColor(Color(hex: Accent.defaultHex)).cgColor
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
