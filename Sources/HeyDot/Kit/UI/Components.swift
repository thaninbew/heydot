import SwiftUI

/// A status dot plus line, coloured by state.
struct StatusPill: View {
    let status: AppStatus
    let text: String
    @Environment(\.self) private var env

    var color: Color {
        switch status {
        case .listening: env.frostMark
        case .calling: .green
        case .paused: .secondary
        default: .orange
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// A full-width row that behaves like a menu item: icon, title, hover highlight.
struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary).font(.callout) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A result banner for call and check outcomes (the Frost banner).
struct ResultBanner: View {
    let result: CallResult
    var onDismiss: (() -> Void)?

    var body: some View {
        FrostBanner(good: result.pressed || result.wouldPress, message: result.message) {
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Dismiss")
            }
        }
    }
}

/// Recent input levels for the tuning waveform, newest last. Its own object so 20 updates a second
/// redraw only the waveform, not the whole onboarding window.
@MainActor
final class LevelHistory: ObservableObject {
    static let count = 72
    @Published private(set) var levels = [Float](repeating: -160, count: LevelHistory.count)
    func push(_ db: Float) { levels.removeFirst(); levels.append(db) }
    func reset() { levels = [Float](repeating: -160, count: Self.count) }
    func set(_ values: [Float]) { levels = Array((Array(repeating: -160, count: Self.count) + values).suffix(Self.count)) }
}

/// A tiny CPU sparkline: the last 40 one-second samples, scaled to at least 2 % so idle noise stays flat.
struct Sparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let top = max(2, values.max() ?? 0)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                             y: rect.maxY - rect.height * CGFloat(min(1, v / top)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// "Listener: 0.4% CPU · ~18 MB" with a sparkline. Samples only while on screen.
struct UsageReadout: View {
    @ObservedObject var usage = ListenerUsage.shared
    let viewer: String

    var body: some View {
        HStack(spacing: 6) {
            Sparkline(values: usage.history)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 44, height: 12)
            Text(usage.latest.map(ListenerUsage.describe) ?? "Measuring\u{2026}")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("Only the wake-word listener: CPU time spent capturing and spotting audio, as percent of one core. Memory is an estimate of the speech model and audio buffers.")
        .accessibilityElement(children: .combine)
        .onAppear { usage.show(viewer) }
        .onDisappear { usage.hide(viewer) }
    }
}

/// Privacy and cost reassurance, in Settings: what HeyDot listens for and what the listener costs.
struct PrivacyNote: View {
    let phrase: String
    var viewer = "settings"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Audio never leaves your Mac. HeyDot runs a tiny on-device keyword spotter (like \u{201C}Hey Siri\u{201D}) and only listens for \u{201C}\(phrase.capitalized)\u{201D}. HeyDot has no servers.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            UsageReadout(viewer: viewer).padding(.leading, 24)
        }
    }
}
