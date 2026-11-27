import SwiftUI
import WebKit

/// Whether the sign-in window has hit a page that won't work here (a provider refusing embedded sign-in, or a
/// page that failed to load).
@MainActor
final class SignInState: ObservableObject {
    @Published var pickingDot = false
    @Published var trouble = false
    /// The page in this window asked for the microphone (someone pressed call here), which this window never gets.
    @Published var callAttempted = false
}

/// The sign-in window: one line of guidance and Done above chatgpt.com itself.
struct SignInView: View {
    let web: WKWebView?
    @ObservedObject var state: SignInState
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.title2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.pickingDot ? "Pick your dot" : "Sign in to ChatGPT").font(.headline)
                    Text(state.pickingDot ? "Open your dot, then click Done to use its link." : "Use Google, Apple, email or phone. HeyDot has no servers. You sign in to ChatGPT itself; your session stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if state.callAttempted {
                    Text("Calls don\u{2019}t run in this window, so it gets no microphone. Click Done, then call from HeyDot.")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if state.trouble {
                    Text("This page couldn’t sign in. Try another sign-in method.")
                        .font(.callout).foregroundStyle(.orange)
                }
                // Not the default button: Return belongs to the page's sign-in form.
                Button("Done", action: done).frostButton(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if let web { WebViewHost(view: web) } else { Color(nsColor: .textBackgroundColor) }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

struct WebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
