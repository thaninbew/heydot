import AppKit
import QuartzCore
import SwiftUI

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
