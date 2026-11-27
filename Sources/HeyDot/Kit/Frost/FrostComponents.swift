import SwiftUI

/// A frosted panel for grouped content (dot lists, the agent checklist).
struct FrostCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        content
            // Inline actions in a card are chips (rows that need their own look set a style themselves).
            .buttonStyle(FrostButtonStyle(role: .chip))
            .padding(16)
            .background(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: Frost.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Frost.Radius.card, style: .continuous).strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0.7), lineWidth: 0.75))
    }
}

/// A frosted rounded field for text entry.
struct FrostField: ViewModifier {
    var height: CGFloat = Frost.pillHeight
    var fontSize: CGFloat = 17
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .padding(.horizontal, height > 40 ? 16 : 12)
            .frame(height: height)
            .background(scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: Frost.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Frost.Radius.field, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
    }
}

/// A choice between a few options (the pill version of a segmented control): a capsule track of chips, the chosen
/// one filled with the accent.
struct FrostChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.frostAccentHex) private var accentHex
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let chosen = value == selection
                Button { selection = value } label: {
                    Text(label).font(.system(size: 13, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? Color(hex: Accent.label(on: accentHex)) : Color.primary)
                        .padding(.horizontal, 14).frame(minWidth: 64, minHeight: Frost.chipHeight - 4)
                        .background(chosen ? Color(hex: accentHex) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)))
        .fixedSize()
    }
}

/// One result or problem, on a softly tinted inset (call and check results, import errors).
struct FrostBanner<Trailing: View>: View {
    let good: Bool
    let message: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Frost.Space.s) {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(good ? AnyShapeStyle(.frostMark) : AnyShapeStyle(.orange))
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, Frost.Space.m).padding(.vertical, 10)
        .background(good ? AnyShapeStyle(.frostMark.opacity(0.12)) : AnyShapeStyle(Color.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: Frost.Radius.inset, style: .continuous))
    }
}

/// A scrolling monospaced preview (agent prompts).
struct FrostCodePreview: View {
    let text: String
    var height: CGFloat = 180
    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Frost.Space.m)
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Frost.Radius.inset, style: .continuous))
    }
}
