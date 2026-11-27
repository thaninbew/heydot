import SwiftUI

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
