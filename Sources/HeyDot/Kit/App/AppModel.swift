import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import WakeEngine

enum AppStatus: Equatable {
    case setupNeeded, micAccessNeeded, micDenied, paused, signInNeeded, listening, calling, failed(String)

    var glyph: GlyphState {
        switch self {
        case .listening, .calling: .listening
        case .paused: .paused
        default: .attention
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private var microphoneAccess: AVAuthorizationStatus
    @Published private var microphoneRequest: Task<Void, Never>?
    @Published private(set) var engineError: String?
    /// The latest call or check result. A success shows briefly and clears itself (`successLifetime`); a problem
    /// stays until a later result replaces it or the user dismisses it. There is only ever one, so repeated
    /// calls replace each other instead of piling up.
    @Published private(set) var lastResult: CallResult?
    /// True while a success is fresh: the menu bar glyph shows a check badge for that time.
    @Published private(set) var flashing = false
    var successLifetime: Duration = .seconds(4)
    private var resultExpiry: Task<Void, Never>?
    /// Called after the pause or its end time changes (ControlService re-arms the timed-pause expiry).
    var onPauseChange: (() -> Void)?
    private var stopped = false
    private var lastWakeCall: ContinuousClock.Instant?
    @Published private(set) var calling = false
    @Published private(set) var checking = false
    @Published var settingsError: String?
    /// Built-in browser: nil until the page has been read once.
    @Published private(set) var webSignedIn: Bool?

    let engine: WakeListening
    let enroller: WakeEnrolling
    let web: WebCalling
    let hooks: SystemHooks
    let store: SettingsStore?
    let log: Log
    /// While onboarding's live test runs, wakes go here instead of pressing the call button.
    var wakeOverride: ((WakeEvent) -> Void)?

    init(settings: AppSettings, engine: WakeListening, enroller: WakeEnrolling,
                web: WebCalling? = nil, hooks: SystemHooks, store: SettingsStore?, log: Log = .shared) {
        self.settings = settings; self.engine = engine; self.enroller = enroller
        self.web = web ?? NoWeb()
        self.hooks = hooks; self.store = store; self.log = log
        microphoneAccess = hooks.microphoneStatus()
        self.web.onCallChange = { [weak self] problem in
            guard let self else { return }
            if let problem { self.show(CallResult(outcome: "call-ended", message: problem)) }
            self.objectWillChange.send()
        }
    }

    // MARK: Settings

    func update(_ change: (inout AppSettings) -> Void) {
        applySettingsChange(change)
    }

    /// Setup can advance only after its current settings are on disk.
    func saveSetup(_ change: (inout AppSettings) -> Void = { _ in }) -> Bool {
        applySettingsChange(requireSavedSettings: true, change)
    }

    @discardableResult
    private func applySettingsChange(requireSavedSettings: Bool = false, _ change: (inout AppSettings) -> Void) -> Bool {
        guard !stopped else { return false }
        var next = settings
        change(&next)
        next.wake.phrase = next.phrase
        if !next.paused { next.pausedUntil = nil }
        guard next != settings || requireSavedSettings else { return true }
        let restart = next.wake != settings.wake || next.paused != settings.paused || next.onboarded != settings.onboarded
        let rewarm = next.dotURL != settings.dotURL
        let repause = next.paused != settings.paused || next.pausedUntil != settings.pausedUntil
        // A new microphone takes effect at once if the listener runs (voice tuning stops it and restarts it after).
        let reinput = next.inputDeviceUID != settings.inputDeviceUID && engine.isListening
        do { try store?.save(next); settingsError = nil } catch {
            settingsError = "Couldn't save settings: \(error.localizedDescription)"
            log.write("settings: save failed: \(error)")
            if requireSavedSettings { return false }
        }
        settings = next
        if restart || reinput { refreshListening() }
        if rewarm { warmWeb() }
        if repause { onPauseChange?() }
        return true
    }

    // MARK: Status

    var status: AppStatus {
        if !settings.onboarded || settings.dotURL == nil { return .setupNeeded }
        if microphoneAccess == .notDetermined { return .micAccessNeeded }
        if microphoneAccess != .authorized { return .micDenied }
        if settings.paused { return .paused }
        if calling || web.inCall { return .calling }
        if let engineError { return .failed(engineError) }
        if webSignedIn == false { return .signInNeeded }
        if let lastResult, !lastResult.pressed, !lastResult.wouldPress { return .failed(lastResult.message) }
        return .listening
    }

    var statusLine: String {
        switch status {
        case .setupNeeded: "Set up needed"
        case .micAccessNeeded: "Microphone access needed"
        case .micDenied: "Microphone access is off"
        case .paused: settings.pausedUntil.map { "Paused until \(Self.time($0))" } ?? "Paused"
        case .signInNeeded: "Sign in to ChatGPT"
        case .listening: "Listening for \u{201C}\(settings.phrase.capitalized)\u{201D}"
        case .calling: web.inCall ? "In a call with \(displayName)" : "Calling \(displayName)\u{2026}"
        case .failed: "Didn't start the call"
        }
    }

    static func time(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    var displayName: String { settings.design.nickname.isEmpty ? settings.dotName : settings.design.nickname }

    // MARK: Listening

    func stop() {
        stopped = true
        keepAlive?.cancel(); keepAlive = nil
        resultExpiry?.cancel(); resultExpiry = nil
        wakeOverride = nil; onPauseChange = nil
        engine.stop()
        web.endCall()
    }

    func refreshListening() {
        refreshListening(access: hooks.microphoneStatus())
    }

    /// Settings can change outside the app. Restart only when macOS reports a different permission.
    func refreshMicrophoneAccess() {
        let access = hooks.microphoneStatus()
        if access != microphoneAccess { refreshListening(access: access) }
    }

    var requestingMicrophoneAccess: Bool { microphoneRequest != nil }

    func requestMicrophoneAccess() async {
        guard !stopped else { return }
        if let microphoneRequest { await microphoneRequest.value; return }
        guard hooks.microphoneStatus() == .notDetermined else { refreshMicrophoneAccess(); return }
        let request = Task { [weak self, ask = hooks.requestMicrophone] in
            defer { self?.microphoneRequest = nil }
            guard self?.stopped == false else { return }
            await withCheckedContinuation { (reply: CheckedContinuation<Void, Never>) in
                ask { _ in reply.resume() }
            }
            self?.refreshMicrophoneAccess()
        }
        microphoneRequest = request
        await request.value
    }

    func openMicrophoneSettings() {
        hooks.openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    private func refreshListening(access: AVAuthorizationStatus) {
        guard !stopped else { return }
        if microphoneAccess != access { microphoneAccess = access }
        let shouldListen = settings.onboarded && !settings.paused && settings.dotURL != nil
        // The engine's synchronous start can wait for the OS prompt, so ask separately after a user action.
        if access == .authorized && (shouldListen || wakeOverride != nil) { startEngine() }
        else if engine.isListening { engine.stop() }
    }

    private func startEngine() {
        engine.inputDeviceUID = settings.inputDeviceUID
        do {
            try engine.start(settings.wake) { [weak self] event in self?.handleWake(event) }
            engineError = nil
            log.write("listening for \"\(settings.wake.phrase)\" (score \(settings.wake.score), threshold \(settings.wake.threshold), \(settings.wake.learned.count) learned)")
        } catch {
            engineError = Self.describe(error)
            log.write("listen failed: \(error)")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? WakeEngineError {
        case .microphoneDenied: "Microphone access is off. Turn it on in System Settings > Privacy & Security."
        case .modelMissing: "The speech model is missing from the app. Reinstall HeyDot."
        case .invalidPhrase(let p): "The model can't spell \u{201C}\(p)\u{201D}. Try a different name."
        case .engine(let m): m
        case nil: error.localizedDescription
        }
    }

    func handleWake(_ event: WakeEvent) {
        log.write("wake: heard \"\(event.phrase)\"")
        if let wakeOverride { wakeOverride(event); return }
        guard !stopped, !settings.paused, !calling, !web.inCall else { return }
        let now = ContinuousClock.now
        if let lastWakeCall, now - lastWakeCall < .seconds(3) { return }
        lastWakeCall = now
        Task { await call(wakeAt: event.at) }
    }

    /// Bumped by `reloadWeb` so a call still waiting on the old page can't overwrite what follows it.
    private var callEpoch = 0

    func call(wakeAt: Date = Date()) async {
        guard !stopped, !calling, !web.inCall else { return }
        calling = true
        let mine = callEpoch
        let result = await placeCall(wakeAt: wakeAt)
        guard mine == callEpoch else { return }
        calling = false
        guard !stopped else { return }
        show(result)
        if result.pressed, !settings.starAsked { update { $0.callsStarted += 1 } }
        // "Not found" or a timeout can really be a lapsed sign-in: re-read the page so the popover offers
        // Sign in instead of a call button that will fail again.
        if !result.pressed, result.outcome != "signed-out" { Task { await refreshWebState() } }
    }

    /// The popover's Reload: drops the hidden page (and a call stuck waiting on it), then loads it fresh and
    /// re-reads sign-in.
    func reloadWeb() {
        log.write("web: reload from the menu")
        callEpoch += 1
        calling = false
        web.reset()
        clearResult()
        warmWeb()
    }

    /// The popover's Call now: the same fail-closed press as a wake, and it works while listening is paused.
    var canCallNow: Bool { settings.onboarded && settings.dotURL != nil && !calling && !web.inCall && !checking }

    func callNow() async {
        guard canCallNow else { return }
        log.write("call: started from the menu")
        await call()
    }

    /// Presses the call button through the hidden browser, without touching `lastResult`.
    func placeCall(wakeAt: Date = Date()) async -> CallResult {
        guard let url = settings.dotURL else { return CallResult(outcome: "no-dot") }
        let result = await web.call(dotURL: url, wakeAt: wakeAt)
        noteWeb(result.outcome)
        return result
    }

    func checkCallButton() async {
        guard let url = settings.dotURL else { lastResult = CallResult(outcome: "no-dot"); return }
        checking = true
        show(await check(dotURL: url))
        checking = false
    }

    func check(dotURL: String) async -> CallResult {
        let result = await web.check(dotURL: dotURL)
        noteWeb(result.outcome)
        return result
    }

    private func noteWeb(_ outcome: String) {
        if outcome == "signed-out" { noteSignedIn(false) }
        else if ["pressed", "would-press", "disabled", "ambiguous"].contains(outcome) { noteSignedIn(true) }
    }

    /// Records sign-in changes in the log, so how long ChatGPT keeps HeyDot signed in can be measured.
    private func noteSignedIn(_ signedIn: Bool) {
        if webSignedIn != signedIn { log.write("web: \(signedIn ? "signed in" : "signed out") (page check)") }
        webSignedIn = signedIn
    }

    // MARK: Built-in browser

    /// Keeps the dot page loaded in the hidden view and re-reads sign-in state.
    func warmWeb() {
        web.warm(dotURL: settings.dotURL)
        Task { await refreshWebState() }
    }

    @discardableResult
    func refreshWebState() async -> WebPageState {
        let state = await web.pageState()
        if let signedIn = state.signedIn { noteSignedIn(signedIn) }
        return state
    }

    /// Visits ChatGPT in the hidden page every few hours while HeyDot runs. A page visit is what renews
    /// ChatGPT's sign-in session, so an idle HeyDot otherwise lets it lapse; it also finds a lapsed sign-in
    /// before a wake does. Each visit unloads itself after `idleLifetime` like any warm.
    var keepAliveInterval: Duration = .seconds(4 * 3600)
    private var keepAlive: Task<Void, Never>?

    func startKeepAlive() {
        keepAlive?.cancel()
        let interval = keepAliveInterval
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, !self.stopped else { return }
                if self.settings.onboarded, !self.calling, !self.web.inCall { self.warmWeb() }
            }
        }
    }

    func showSignIn() {
        web.showChatGPT(pickingDot: false) { [weak self] _ in Task { await self?.refreshWebState() } }
    }

    func endCall() { web.endCall() }

    /// WebKit owns the page's microphone and reports its real mute state.
    var canMute: Bool { web.inCall && web.microphoneMuted != nil }
    var muted: Bool { web.microphoneMuted == true }

    func setMuted(_ on: Bool) async {
        if await !web.setMicrophoneMuted(on) {
            show(CallResult(outcome: "mute-failed", message: on ? "Couldn't mute the call's microphone. It is still on."
                                                                : "Couldn't unmute the call's microphone."))
        }
        objectWillChange.send()
    }

    func signOutWeb() async {
        await web.signOut()
        webSignedIn = false
    }

    func togglePause() { update { $0.paused.toggle(); $0.pausedUntil = nil } }

    /// The next time the clock reads the user's morning time (`morningMinutes`, default 8:00 AM): later today
    /// when that is still ahead (a pause just after midnight), otherwise tomorrow.
    static func nextMorning(minutes: Int = 8 * 60, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    /// The popover's timed pauses, in its menu order.
    static let pauseDurations: [(String, TimeInterval)] = [
        ("15 minutes", 15 * 60), ("30 minutes", 30 * 60), ("1 hour", 3600), ("2 hours", 2 * 3600), ("4 hours", 4 * 3600),
    ]

    /// How long a timed pause has left, for the popover and Settings: "42 min left", "1 h 5 min left".
    static func remaining(until: Date, now: Date = Date()) -> String {
        let minutes = Int((until.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 1 { return "Less than a minute left" }
        if minutes < 60 { return "\(minutes) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h left" : "\(h) h \(m) min left"
    }

    /// The morning time as the clock shows it ("8:00 AM").
    static func clock(minutes: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// HeyDot's GitHub page (source, releases, issues).
    static let repository = URL(string: "https://github.com/thaninbew/heydot")!

    /// After a few calls that worked, the popover asks once for a GitHub star.
    var asksForStar: Bool { !settings.starAsked && settings.callsStarted >= 3 }

    func answerStarCard(star: Bool) {
        update { $0.starAsked = true }
        if star { hooks.openURL(Self.repository) }
    }

    func clearResult() { resultExpiry?.cancel(); lastResult = nil; flashing = false }

    /// Shows one result, replacing whatever was there. Successes expire on their own.
    func show(_ result: CallResult) {
        resultExpiry?.cancel()
        lastResult = result
        flashing = result.pressed || result.wouldPress
        guard flashing else { return }
        let lifetime = successLifetime
        resultExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.lastResult == result else { return }
            self.lastResult = nil
            self.flashing = false
        }
    }

    /// For QA fixtures only.
    func setFixture(result: CallResult?, engineError: String? = nil, signedIn: Bool? = nil) {
        lastResult = result; self.engineError = engineError; webSignedIn = signedIn
    }
}
