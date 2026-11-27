import SwiftUI

/// The one input-level meter (popover, Not working?): five bars that sit as equal dots in silence (-60 dBFS) and
/// rise into a centred peak with the voice (full at -6 dBFS).
struct LevelBars: View {
    var level: Float
    @Environment(\.self) private var env
    private static let shape: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.5]
    private static let width: CGFloat = 3, height: CGFloat = 20
    var body: some View {
        let f = CGFloat(max(0, min(1, (level + 60) / 54)))
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(env.frostMark)
                    .frame(width: Self.width, height: Self.width + (Self.height - Self.width) * Self.shape[i] * f)
            }
        }
        .animation(.easeOut(duration: 0.12), value: f)
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(f * 100)) percent")
    }
}
