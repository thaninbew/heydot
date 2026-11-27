import Foundation

/// What the signed-in page shows: sign-in state and the dots it links to.
struct WebPageState: Equatable, Sendable {
    var signedIn: Bool?        // nil: the page could not be read
    var challenge: Bool
    var dots: [DotTab]
    init(signedIn: Bool?, challenge: Bool = false, dots: [DotTab] = []) {
        self.signedIn = signedIn; self.challenge = challenge; self.dots = dots
    }
}

/// The built-in call path: HeyDot's own WKWebView, signed in once, kept warm and hidden. Injectable so QA
/// renders and tests never load chatgpt.com.
@MainActor
protocol WebCalling: AnyObject {
    /// True from a successful press until the page's microphone capture ends.
    var inCall: Bool { get }
    /// Called on the main actor whenever `inCall` or the call's microphone state changes; the argument
    /// explains a call that ended badly.
    var onCallChange: ((String?) -> Void)? { get set }
    /// The call's microphone as the browser reports it: true muted, false live, nil when there is no live
    /// microphone to mute (no call, or a backend that can't tell).
    var microphoneMuted: Bool? { get }
    /// Mutes or unmutes the call's microphone. True only when the browser then reports the asked-for state.
    func setMicrophoneMuted(_ muted: Bool) async -> Bool
    func call(dotURL: String, wakeAt: Date) async -> CallResult
    /// Looks for the call button in the hidden page without pressing it.
    func check(dotURL: String) async -> CallResult
    func endCall()
    /// Loads the dot page in the hidden view so a wake only has to press.
    func warm(dotURL: String?)
    func pageState() async -> WebPageState
    func showChatGPT(pickingDot: Bool, onClose: @escaping (DotTab?) -> Void)
    func signOut() async
    func prepareForErase() async
    /// Drops the hidden page and anything still waiting on it (a hung press, a stale page), so the next
    /// call or warm starts from a fresh load. Ends a running call.
    func reset()
}

extension WebCalling {
    var microphoneMuted: Bool? { nil }
    func setMicrophoneMuted(_ muted: Bool) async -> Bool { false }
    func reset() {}
    func prepareForErase() async { reset() }
}

/// No built-in browser (tests and fixtures that don't exercise it).
@MainActor
final class NoWeb: WebCalling {
    var inCall = false
    var onCallChange: ((String?) -> Void)?
    var microphoneMuted: Bool?
    var state = WebPageState(signedIn: nil)
    var result = CallResult(outcome: "error")
    init() {}
    func call(dotURL: String, wakeAt: Date) async -> CallResult { result }
    func check(dotURL: String) async -> CallResult { result }
    func endCall() {}
    func warm(dotURL: String?) {}
    func pageState() async -> WebPageState { state }
    func showChatGPT(pickingDot: Bool, onClose: @escaping (DotTab?) -> Void) {}
    func signOut() async {}
}

struct DotTab: Sendable, Equatable, Identifiable {
    let url: String
    let title: String
    var id: String { url }
    init(url: String, title: String) { self.url = url; self.title = title }
    static func conversation(at url: URL?, title: String?) -> DotTab? {
        guard let url, url.scheme == "https", url.host == "chatgpt.com", url.port == nil,
              url.user == nil, url.password == nil, url.pathComponents.count == 3,
              url.pathComponents[1] == "dots",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        if components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let link = components.url else { return nil }
        let label = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DotTab(url: link.absoluteString, title: label.isEmpty ? url.lastPathComponent : label)
    }
}
