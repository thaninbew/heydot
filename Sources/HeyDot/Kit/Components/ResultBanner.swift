import SwiftUI

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
