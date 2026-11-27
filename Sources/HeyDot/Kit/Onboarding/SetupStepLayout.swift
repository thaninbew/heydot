import SwiftUI

/// The one layout every setup step uses. The page dots sit fixed at the top, the step's content is centred in the
/// space between, its note (a hint or a problem) sits above the buttons, and the button row (Back, then the step's
/// buttons, centred) is pinned the same distance from the bottom on every step. Notes and content that change
/// height grow away from the row, so moving between steps, or within one, never moves it.
struct SetupStepLayout<Dots: View, Content: View, Note: View, Buttons: View>: View {
    /// Nil hides Back (the first and last steps, and tuning opened from Settings).
    let back: (() -> Void)?
    let dots: Dots
    let content: Content
    let note: Note
    let buttons: Buttons

    init(back: (() -> Void)?, @ViewBuilder dots: () -> Dots, @ViewBuilder content: () -> Content,
         @ViewBuilder note: () -> Note, @ViewBuilder buttons: () -> Buttons) {
        self.back = back
        self.dots = dots(); self.content = content(); self.note = note(); self.buttons = buttons()
    }

    var body: some View {
        VStack(spacing: 0) {
            dots
                .padding(.top, 13)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .top)
            // Scrolls only when a step is taller than its space (a long check result, larger text sizes).
            GeometryReader { geo in
                ScrollView {
                    content
                        .padding(.horizontal, 56)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            VStack(spacing: Frost.Space.m) {
                note
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560, minHeight: 20, alignment: .bottom)
                HStack(spacing: Frost.Space.m) {
                    if let back {
                        Button(action: back) { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)) }
                            .frostButton(.round)
                            .accessibilityLabel("Back")
                    }
                    buttons
                }
                .frame(height: Frost.pillHeight)
            }
            .padding(.top, Frost.Space.m)
            .padding(.bottom, Frost.Space.xxl)
        }
        .frame(width: 760, height: 600)
    }
}
