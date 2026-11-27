import SwiftUI

enum FrostRole { case primary, secondary, round, chip, hangUp }

extension View {
    /// Every Frost button is one capsule (or circle) whose size HeyDot sets, so primary and secondary buttons
    /// share one height and base width. macOS 26 fills it with Liquid Glass (accent-tinted for the primary); 14 and
    /// 15, and QA renders, draw the fallback.
    func frostButton(_ role: FrostRole) -> some View { modifier(FrostButtonModifier(role: role)) }
}

private struct FrostButtonModifier: ViewModifier {
    let role: FrostRole

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

    /// macOS 14 and 15: an accent gradient capsule with a top highlight, or a frosted white capsule.
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
