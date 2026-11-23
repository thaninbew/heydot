import AppKit
import SwiftUI
import WebKit

/// What the signed-in page shows: sign-in state and the dots it links to.
public struct WebPageState: Equatable, Sendable {
    public var signedIn: Bool?        // nil: the page could not be read
    public var challenge: Bool
    public var dots: [DotTab]
    public init(signedIn: Bool?, challenge: Bool = false, dots: [DotTab] = []) {
        self.signedIn = signedIn; self.challenge = challenge; self.dots = dots
    }
}

/// The built-in call path: HeyDot's own WKWebView, signed in once, kept warm and hidden. Injectable so QA
/// renders and tests never load chatgpt.com.
@MainActor
public protocol WebCalling: AnyObject {
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
    func showSignIn(onClose: @escaping () -> Void)
    func signOut() async
    /// Drops the hidden page and anything still waiting on it (a hung press, a stale page), so the next
    /// call or warm starts from a fresh load. Ends a running call.
    func reset()
}

public extension WebCalling {
    var microphoneMuted: Bool? { nil }
    func setMicrophoneMuted(_ muted: Bool) async -> Bool { false }
    func reset() {}
}

/// No built-in browser (tests and fixtures that don't exercise it).
@MainActor
public final class NoWeb: WebCalling {
    public var inCall = false
    public var onCallChange: ((String?) -> Void)?
    public var microphoneMuted: Bool?
    public var state = WebPageState(signedIn: nil)
    public var result = CallResult(outcome: "error")
    public init() {}
    public func call(dotURL: String, wakeAt: Date) async -> CallResult { result }
    public func check(dotURL: String) async -> CallResult { result }
    public func endCall() {}
    public func warm(dotURL: String?) {}
    public func pageState() async -> WebPageState { state }
    public func showSignIn(onClose: @escaping () -> Void) {}
    public func signOut() async {}
}

/// Hidden WKWebView backend.
///
/// - Sign-in lives in a persistent `WKWebsiteDataStore(forIdentifier:)`. WebKit's public API keeps that store
///   under `~/Library/WebKit/<bundle id>/WebsiteDataStore/<id>`; HeyDot never reads its cookies.
/// - Warm: the dot page sits in a borderless, ordered-out panel (no window on screen, no Dock icon).
/// - Call: the panel goes on screen fully transparent, click-through and non-activating, because WebKit
///   holds a microphone request from a hidden page forever. Then `PageScripts.press` runs with the same
///   fail-closed rules as the page script. The microphone is granted only to https://chatgpt.com, only
///   for the microphone, and only while a call is being placed or running. The panel leaves the screen when
///   the page's microphone capture ends.
@MainActor
public final class WebCallBackend: NSObject, WebCalling, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// Fixed, so the same signed-in store is found on every launch.
    static let storeID = UUID(uuidString: "6E8F2C4A-3B1D-4F5E-9A7C-2D1E0B4C8F61")!
    static let label = "Start call"

    let log: Log
    private let store: WKWebsiteDataStore
    private var panel: NSPanel?
    private var webView: WKWebView?
    private var signInWindow: NSWindow?
    private var signInView: WKWebView?
    let signInState = SignInState()
    private var signInClosed: (() -> Void)?
    private var popups: [NSWindow] = []
    private var loadError: String?
    private var placing = false
    private var captureWatch: NSKeyValueObservation?
    private var callTimeout: Task<Void, Never>?
    private var micWasOn = false
    public private(set) var inCall = false
    public var onCallChange: ((String?) -> Void)?

    /// `store` nil is the persistent sign-in store; QA renders pass `.nonPersistent()`.
    public init(log: Log = .shared, store: WKWebsiteDataStore? = nil) {
        self.log = log
        self.store = store ?? WKWebsiteDataStore(forIdentifier: Self.storeID)
        super.init()
    }

    /// Bound hidden page work even when WebKit's own occlusion throttling changes.
    /// A call or an in-flight page read pins the view until that operation finishes.
    var idleLifetime: Duration = .seconds(30)
    private var idleUnload: Task<Void, Never>?
    private var pageReaders = 0

    private func scheduleIdleUnload() {
        idleUnload?.cancel(); idleUnload = nil
        guard !inCall, !placing, pageReaders == 0, webView != nil else { return }
        let delay = idleLifetime
        idleUnload = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.discardIdleView()
        }
    }

    func discardIdleView() {
        guard !inCall, !placing, pageReaders == 0 else { return }
        releaseView()
    }

    private func releaseView() {
        idleUnload?.cancel(); idleUnload = nil
        captureWatch?.invalidate(); captureWatch = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil; webView = nil; loadError = nil
    }

    func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.mediaTypesRequiringUserActionForPlayback = []
        return config
    }

    // MARK: Hidden view

    @discardableResult
    func ensureView() -> WKWebView {
        if let webView { return webView }
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        panel.isExcludedFromWindowsMenu = true
        let view = WKWebView(frame: frame, configuration: configuration())
        view.navigationDelegate = self
        view.uiDelegate = self
        panel.contentView = view
        self.panel = panel
        webView = view
        captureWatch = view.observe(\.microphoneCaptureState, options: [.new]) { [weak self] view, _ in
            let state = view.microphoneCaptureState
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, self.webView === view else { return }
                self.microphoneChanged(state)
            }
        }
        scheduleIdleUnload()
        return view
    }

    func load(_ url: URL) {
        loadError = nil
        ensureView().load(URLRequest(url: url))
        scheduleIdleUnload()
    }

    private func isShowing(_ target: URL) -> Bool {
        guard let current = webView?.url, current.host == "chatgpt.com" else { return false }
        return Self.trim(current.path) == Self.trim(target.path)
    }

    static func trim(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public func warm(dotURL: String?) {
        guard let dotURL, let url = URL(string: dotURL), url.host == "chatgpt.com" else { return }
        guard !inCall, !placing, !isShowing(url) || loadError != nil else { return }
        log.write("web: warming \(url.path)")
        load(url)
    }

    /// On screen, fully transparent, click-through, non-activating: the page counts as visible.
    private func reveal() {
        guard let panel else { return }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 800)
        panel.setFrame(NSRect(x: screen.minX, y: screen.minY, width: min(1100, screen.width), height: min(800, screen.height)), display: false)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    private func conceal() { panel?.orderOut(nil) }

    /// How long one page script may take. A hung or suspended page never answers `callAsyncJavaScript`, and
    /// without a bound the call (and every later wake) would wait on it forever.
    var scriptTimeout: Duration = .seconds(5)

    private func run(_ script: String, _ arguments: [String: Any] = [:], in view: WKWebView? = nil) async -> [String: Any] {
        guard let view = view ?? webView else { return ["outcome": "error"] }
        let timeout = scriptTimeout
        // The reply crosses the continuation as JSON so nothing non-Sendable leaves the main actor.
        let reply: Data? = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            let once = Once()
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                guard once.claim() else { return }
                let value = try? result.get()
                done.resume(returning: value.flatMap { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil })
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard once.claim() else { return }
                done.resume(returning: Data("{\"outcome\":\"error\",\"error\":\"page-timeout\"}".utf8))
            }
        }
        guard let reply, let value = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return ["outcome": "error"] }
        if value["error"] as? String == "page-timeout" { log.write("web: the page didn't answer within \(timeout)") }
        return value
    }

    // MARK: Calls

    public func call(dotURL: String, wakeAt: Date) async -> CallResult {
        guard let target = URL(string: dotURL), target.host == "chatgpt.com" else { return CallResult(outcome: "no-dot") }
        guard !inCall, !placing else { return CallResult(outcome: "disabled", message: Self.describe("in-call")) }
        placing = true; micWasOn = false
        idleUnload?.cancel(); idleUnload = nil
        let mine = epoch
        defer {
            // After a reset this press no longer owns the view or the placing flag.
            if mine == epoch {
                placing = false
                if !inCall { discardIdleView() }
            }
        }
        let began = Date()
        let view = ensureView()
        let reloaded = !isShowing(target) || loadError != nil
        if reloaded { load(target) }
        reveal()
        let outcome = await press(target, view: view, click: true, within: reloaded ? 20 : 12)
        let end = Date()
        if mine != epoch { return CallResult(outcome: "cancelled", message: "Call cancelled.") }
        if outcome == "pressed" {
            inCall = true
            onCallChange?(nil)
            // No microphone within 20 s means WebKit or macOS never granted it: fail visibly, don't sit on screen.
            callTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled, self.inCall, !self.micWasOn else { return }
                self.log.write("web: microphone never opened after the press; ending")
                self.finishCall(problem: Self.describe("no-mic"))
            }
        } else {
            conceal()
        }
        let ms = { (d: Date) in Int((d.timeIntervalSince(wakeAt) * 1000).rounded()) }
        let event: JSONValue = [
            "event": "wake", "backend": "built-in", "outcome": .string(outcome), "page_loaded": .bool(reloaded),
            "wake_to_press_ms": .array([["step": "web", "start": .number(Double(ms(began))), "end": .number(Double(ms(end)))]]),
        ]
        log.write("wake: " + (String(data: (try? event.data()) ?? Data(), encoding: .utf8) ?? outcome))
        return CallResult(outcome: outcome, message: Self.describe(outcome), wakeToPressMs: ms(end))
    }

    public func check(dotURL: String) async -> CallResult {
        guard let target = URL(string: dotURL), target.host == "chatgpt.com" else { return CallResult(outcome: "no-dot") }
        if inCall || placing { return CallResult(outcome: "disabled", message: Self.describe("in-call")) }
        pageReaders += 1
        defer { pageReaders -= 1; scheduleIdleUnload() }
        let view = ensureView()
        let reloaded = !isShowing(target) || loadError != nil
        if reloaded { load(target) }
        let outcome = await press(target, view: view, click: false, within: reloaded ? 20 : 8)
        log.write("check: built-in \(outcome)")
        return CallResult(outcome: outcome, message: Self.describe(outcome))
    }

    /// Polls `PageScripts.press` until it settles. Terminal at once: pressed, would-press, challenge,
    /// ambiguous, disabled. Terminal once the page finished loading: signed-out, wrong-dot. Everything else
    /// (not-found while the page renders, not-visible while the panel becomes visible) waits until `within`.
    private func press(_ target: URL, view: WKWebView, click: Bool, within seconds: Double) async -> String {
        let deadline = Date().addingTimeInterval(seconds)
        let args: [String: Any] = ["dotPath": target.path, "label": Self.label, "click": click]
        var outcome = "not-found"
        let mine = epoch
        while true {
            if Task.isCancelled || mine != epoch { return "timeout" }
            if loadError != nil && !view.isLoading { return "load-failed" }
            let reply = await run(PageScripts.press, args, in: view)
            outcome = reply["outcome"] as? String ?? "error"
            switch outcome {
            case "pressed", "would-press", "challenge", "ambiguous", "disabled": return outcome
            case "signed-out" where !view.isLoading, "wrong-dot" where !view.isLoading: return outcome
            default: break
            }
            if Date() >= deadline {
                if outcome == "not-found" {
                    let near = reply["near"] as? [String] ?? []
                    log.write("web: no \"\(Self.label)\" button on \(target.path); call-like controls: \(near.isEmpty ? "none" : near.map { "\"\($0)\"" }.joined(separator: ", "))")
                }
                return switch outcome {
                case "not-visible": "hidden"
                case "error", "signed-out", "wrong-dot": "timeout"
                default: outcome
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func microphoneChanged(_ state: WKMediaCaptureState) {
        guard inCall || placing else { return }
        log.write("web: microphone \(state == .active ? "active" : state == .muted ? "muted" : "off")")
        if state != .none { micWasOn = true; onCallChange?(nil); return }
        if micWasOn && inCall { finishCall(problem: nil) }
    }

    /// WebKit's own capture state for the call page: muted pauses the microphone track the page got from
    /// getUserMedia without ending the call, and WebKit reports it back, so the button always shows the truth.
    public var microphoneMuted: Bool? {
        guard inCall, let state = webView?.microphoneCaptureState, state != .none else { return nil }
        return state == .muted
    }

    public func setMicrophoneMuted(_ muted: Bool) async -> Bool {
        guard inCall, let view = webView, view.microphoneCaptureState != .none else { return false }
        let want: WKMediaCaptureState = muted ? .muted : .active
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            view.setMicrophoneCaptureState(want) { done.resume() }
        }
        let ok = view.microphoneCaptureState == want
        log.write("web: \(muted ? "mute" : "unmute") \(ok ? "ok" : "failed (microphone is \(view.microphoneCaptureState == .muted ? "muted" : "live"))")")
        onCallChange?(nil)
        return ok
    }

    private func finishCall(problem: String?) {
        callTimeout?.cancel(); callTimeout = nil
        inCall = false; micWasOn = false
        conceal()
        releaseView()
        log.write("web: call ended" + (problem.map { ": \($0)" } ?? ""))
        onCallChange?(problem)
    }

    /// Hangs up by releasing the call page and panel, including media and compositing resources.
    public func endCall() {
        guard inCall else { return }
        log.write("web: ending the call")
        finishCall(problem: nil)
    }

    /// Bumped by `reset` so a press still polling a dropped page stops and leaves the new state alone.
    private var epoch = 0

    public func reset() {
        log.write("web: reset (reloading the page from scratch)")
        epoch += 1
        if inCall { finishCall(problem: nil) }
        callTimeout?.cancel(); callTimeout = nil
        placing = false; micWasOn = false
        releaseView()
    }

    // MARK: Sign-in

    public func pageState() async -> WebPageState {
        pageReaders += 1
        defer { pageReaders -= 1; scheduleIdleUnload() }
        let view: WKWebView
        if let signInView, signInWindow?.isVisible == true { view = signInView } else {
            view = ensureView()
            if view.url == nil { load(URL(string: "https://chatgpt.com/")!) }
            let deadline = Date().addingTimeInterval(10)
            while view.isLoading && Date() < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        }
        let r = await run(PageScripts.state, in: view)
        guard r["ready"] as? Bool == true else { return WebPageState(signedIn: nil) }
        let dots = (r["dots"] as? [[String: Any]] ?? []).compactMap { d -> DotTab? in
            guard let url = d["url"] as? String else { return nil }
            return DotTab(url: url, title: d["title"] as? String ?? url)
        }
        return WebPageState(signedIn: r["signedIn"] as? Bool, challenge: r["challenge"] as? Bool ?? false, dots: dots)
    }

    /// A normal visible window on chatgpt.com, sharing the persistent store. The user signs in however
    /// chatgpt.com offers (Google, Apple, email, phone). WebKit's own user agent is left unchanged.
    public func showSignIn(onClose: @escaping () -> Void) {
        signInClosed = onClose
        if let signInWindow {
            NSApp.activate(ignoringOtherApps: true)
            signInWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = WKWebView(frame: .zero, configuration: configuration())
        view.navigationDelegate = self
        view.uiDelegate = self
        signInState.trouble = false
        signInState.callAttempted = false
        let window = NSWindow(contentViewController: NSHostingController(rootView: SignInView(web: view, state: signInState, done: { [weak self] in
            self?.signInWindow?.close()
        }).fontDesign(.rounded)))
        window.title = "Sign in to ChatGPT"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 980, height: 760))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        signInWindow = window
        signInView = view
        view.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Typing and Return go to the page's sign-in form, not to the window's buttons.
        window.makeFirstResponder(view)
        log.write("web: sign-in window opened")
    }

    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === signInWindow else { return }
        signInView?.stopLoading()
        signInWindow = nil; signInView = nil
        popups.forEach { $0.close() }; popups = []
        log.write("web: sign-in window closed")
        // Sign-in can leave identity providers' cookies (Google, Apple, Microsoft) in the store; keep only
        // ChatGPT's own (chatgpt.com and its openai.com sign-in).
        Task { await Self.pruneToChatGPT(store, log: log) }
        // The hidden page loaded before sign-in: reload it so it picks up the session.
        if let url = webView?.url, !inCall { load(url) }
        let closed = signInClosed
        signInClosed = nil
        closed?()
    }

    public func signOut() async {
        if inCall { endCall() }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        log.write("web: signed out (cleared HeyDot's web data)")
        if let url = webView?.url { load(url) }
    }

    /// Website data HeyDot keeps: ChatGPT's own sites. WebKit groups records by registrable domain.
    nonisolated static func keepsData(for displayName: String) -> Bool {
        ["chatgpt.com", "openai.com"].contains(displayName.lowercased())
    }

    static func pruneToChatGPT(_ store: WKWebsiteDataStore, log: Log) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let drop = records.filter { !keepsData(for: $0.displayName) }
        guard !drop.isEmpty else { return }
        await store.removeData(ofTypes: types, for: drop)
        log.write("web: removed website data for \(drop.count) non-ChatGPT site(s)")
    }

    /// Where a top-level page may go. The hidden call view stays on https://chatgpt.com (a redirect anywhere
    /// else is cancelled and the press fails closed); the sign-in window and its popups may visit the identity
    /// providers chatgpt.com sends them to, over https only. Subframes are left to the page.
    nonisolated static func allowsNavigation(to url: URL?, mainFrame: Bool, callView: Bool) -> Bool {
        guard mainFrame else { return true }
        guard let url else { return false }
        if url.scheme == "about" { return true }
        guard url.scheme == "https" else { return false }
        return !callView || url.host == "chatgpt.com"
    }

    /// A sign-in page that says this embedded browser won't do, such as Google's "This browser or app may not be
    /// secure" (accounts.google.com/.../rejected). It reports the sign-in problem; nothing is blocked.
    nonisolated static func refusesEmbeddedSignIn(_ url: URL?) -> Bool {
        guard let url, url.host == "accounts.google.com" else { return false }
        return url.path.contains("/rejected")
    }

    // MARK: WebKit delegates

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let allowed = Self.allowsNavigation(to: navigationAction.request.url, mainFrame: mainFrame, callView: webView === self.webView)
        if !allowed { log.write("web: blocked a page load to \(navigationAction.request.url?.host ?? "?")") }
        if webView === signInView, mainFrame, Self.refusesEmbeddedSignIn(navigationAction.request.url) {
            signInState.trouble = true
            log.write("web: sign-in provider refused the built-in browser")
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        loadError = error.localizedDescription
        log.write("web: load failed: \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e0 = error as NSError
        if webView === signInView, e0.code != NSURLErrorCancelled, !(e0.domain == "WebKitErrorDomain" && e0.code == 102) {
            signInState.trouble = true  // the sign-in page couldn't load here
        }
        guard webView === self.webView else { return }
        // A redirect or a newer load cancelling this one is not a failure, nor is a load HeyDot's own
        // navigation rule cancelled (the press then fails closed on the page it finds).
        let e = error as NSError
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        loadError = error.localizedDescription
        log.write("web: load failed: \(error.localizedDescription)")
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        log.write("web: page process ended")
        if inCall { finishCall(problem: Self.describe("crashed")) }
        else { loadError = "Web content process terminated"; discardIdleView() }
    }

    /// The microphone, only for chatgpt.com's own top-level page in the call panel, only while placing or in a call.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let grant = Self.allowsMicrophone(origin: (origin.protocol, origin.host, origin.port), frameHost: frame.securityOrigin.host,
                                          type: type, callView: webView === self.webView, active: placing || inCall)
        log.write("web: microphone request from \(origin.protocol)://\(origin.host) (\(type == .microphone ? "microphone" : "type \(type.rawValue)")): \(grant ? "granted" : "denied")")
        // A call started by hand in the ChatGPT window would get no microphone: say where calls start instead.
        if !grant, webView === signInView { signInState.callAttempted = true }
        decisionHandler(grant ? .grant : .deny)
    }

    nonisolated static func allowsMicrophone(origin: (scheme: String, host: String, port: Int), frameHost: String,
                                             type: WKMediaCaptureType, callView: Bool, active: Bool) -> Bool {
        callView && active && type == .microphone && origin.scheme == "https" && origin.host == "chatgpt.com"
            && origin.port == 0 && frameHost == "chatgpt.com"
    }

    /// Sign-in popups (Google, Apple) open in a visible child window that shares the configuration.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === signInView else { return nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let child = WKWebView(frame: window.contentRect(forFrameRect: window.frame), configuration: configuration)
        child.uiDelegate = self
        window.contentView = child
        window.title = "Sign in"
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return child
    }

    public func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { window in
            guard window.contentView === webView else { return false }
            window.close(); return true
        }
    }

    // MARK: Messages

    static func describe(_ outcome: String) -> String {
        switch outcome {
        case "pressed": "Call started."
        case "would-press": "Ready. HeyDot found your dot's call button and left it alone."
        case "signed-out": "HeyDot isn't signed in to ChatGPT. Sign in again from Settings."
        case "challenge": "chatgpt.com wants to check it's you. Open the sign-in window from Settings and finish it there."
        case "not-found": "Couldn't find the call button on your dot's page. Nothing was pressed."
        case "wrong-dot": "Your dot's page didn't open (it went somewhere else). Check the dot link in Settings."
        case "ambiguous": "More than one call button is showing, so HeyDot didn't press anything."
        case "disabled": "The call button is off, probably because a call is already running."
        case "in-call": "A call is already running."
        case "hidden": "macOS didn't let HeyDot's call window become active in time. Nothing was pressed."
        case "load-failed": "Couldn't load your dot's page. Check the internet connection."
        case "timeout": "Your dot's page didn't finish loading in time. Nothing was pressed."
        case "no-mic": "The call started but the microphone never opened, so HeyDot ended it."
        case "crashed": "The ChatGPT page stopped, so the call ended."
        default: "Something went wrong, so nothing was pressed."
        }
    }
}

/// Lets exactly one of two racing callbacks resume a continuation.
@MainActor
final class Once {
    private var claimed = false
    func claim() -> Bool { defer { claimed = true }; return !claimed }
}

/// Whether the sign-in window has hit a page that won't work here (a provider refusing embedded sign-in, or a
/// page that failed to load).
@MainActor
final class SignInState: ObservableObject {
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
                    Text("Sign in to ChatGPT").font(.headline)
                    Text("Use Google, Apple, email or phone. HeyDot has no servers. You sign in to ChatGPT itself; your session stays on this Mac.")
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
