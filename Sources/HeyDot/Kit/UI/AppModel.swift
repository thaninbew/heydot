import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import WakeEngine

/// System side effects the app needs, injectable so previews and QA renders never touch login items or the microphone.
public struct SystemHooks {
    public var setLaunchAtLogin: (Bool) throws -> Void
    public var launchAtLoginEnabled: () -> Bool
    public var microphoneStatus: () -> AVAuthorizationStatus
    public var requestMicrophone: (@escaping @Sendable (Bool) -> Void) -> Void

    @MainActor
    public static func live() -> SystemHooks {
        return SystemHooks(
            setLaunchAtLogin: { on in
                if on {
                    guard SMAppService.mainApp.status != .enabled,
                          SMAppService.mainApp.status != .requiresApproval else { return }
                    try SMAppService.mainApp.register()
                } else if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            },
            launchAtLoginEnabled: { SMAppService.mainApp.status == .enabled },
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            requestMicrophone: { done in AVCaptureDevice.requestAccess(for: .audio, completionHandler: done) }
        )
    }
}

public enum AppStatus: Equatable {
    case setupNeeded, micDenied, paused, signInNeeded, listening, calling, failed(String)

    public var glyph: GlyphState {
        switch self {
        case .listening, .calling: .listening
        case .paused: .paused
        default: .attention
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var engineError: String?
    /// The latest call or check result. A success shows briefly and clears itself (`successLifetime`); a problem
    /// stays until a later result replaces it or the user dismisses it. There is only ever one, so repeated
    /// calls replace each other instead of piling up.
    @Published public private(set) var lastResult: CallResult?
    /// True while a success is fresh: the menu bar glyph shows a check badge for that time.
    @Published public private(set) var flashing = false
    var successLifetime: Duration = .seconds(4)
    private var resultExpiry: Task<Void, Never>?
    /// Called after the pause or its end time changes (ControlService re-arms the timed-pause expiry).
    var onPauseChange: (() -> Void)?
    private var stopped = false
    private var lastWakeCall: ContinuousClock.Instant?
    @Published public private(set) var calling = false
    @Published public private(set) var checking = false
    @Published public var settingsError: String?
    /// Built-in browser: nil until the page has been read once.
    @Published public private(set) var webSignedIn: Bool?

    public let engine: WakeListening
    public let enroller: WakeEnrolling
    public let web: WebCalling
    public let hooks: SystemHooks
    let store: SettingsStore?
    let log: Log
    /// While onboarding's live test runs, wakes go here instead of pressing the call button.
    var wakeOverride: ((WakeEvent) -> Void)?

    public init(settings: AppSettings, engine: WakeListening, enroller: WakeEnrolling,
                web: WebCalling? = nil, hooks: SystemHooks, store: SettingsStore?, log: Log = .shared) {
        self.settings = settings; self.engine = engine; self.enroller = enroller
        self.web = web ?? NoWeb()
        self.hooks = hooks; self.store = store; self.log = log
        self.web.onCallChange = { [weak self] problem in
            guard let self else { return }
            if let problem { self.show(CallResult(outcome: "call-ended", message: problem)) }
            self.objectWillChange.send()
        }
    }

    // MARK: Settings

    public func update(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        next.wake.phrase = next.phrase
        if !next.paused { next.pausedUntil = nil }
        guard next != settings else { return }
        let restart = next.wake != settings.wake || next.paused != settings.paused || next.onboarded != settings.onboarded
        let rewarm = next.dotURL != settings.dotURL
        let repause = next.paused != settings.paused || next.pausedUntil != settings.pausedUntil
        // A new microphone takes effect at once if the listener runs (voice tuning stops it and restarts it after).
        let reinput = next.inputDeviceUID != settings.inputDeviceUID && engine.isListening
        settings = next
        do { try store?.save(next); settingsError = nil } catch {
            settingsError = "Couldn't save settings: \(error.localizedDescription)"
            log.write("settings: save failed: \(error)")
        }
        if restart || reinput { refreshListening() }
        if rewarm { warmWeb() }
        if repause { onPauseChange?() }
    }

    // MARK: Status

    public var status: AppStatus {
        if !settings.onboarded || settings.dotURL == nil { return .setupNeeded }
        if hooks.microphoneStatus() == .denied || hooks.microphoneStatus() == .restricted { return .micDenied }
        if settings.paused { return .paused }
        if calling || web.inCall { return .calling }
        if let engineError { return .failed(engineError) }
        if webSignedIn == false { return .signInNeeded }
        if let lastResult, !lastResult.pressed, !lastResult.wouldPress { return .failed(lastResult.message) }
        return .listening
    }

    public var statusLine: String {
        switch status {
        case .setupNeeded: "Set up needed"
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

    public var displayName: String { settings.design.nickname.isEmpty ? settings.dotName : settings.design.nickname }

    // MARK: Listening

    public func stop() {
        stopped = true
        resultExpiry?.cancel(); resultExpiry = nil
        wakeOverride = nil; onPauseChange = nil
        engine.stop()
        web.endCall()
    }

    public func refreshListening() {
        guard !stopped else { return }
        let shouldListen = settings.onboarded && !settings.paused && settings.dotURL != nil
        if shouldListen || wakeOverride != nil { startEngine() } else if engine.isListening { engine.stop() }
    }

    func startEngine() {
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

    public func call(wakeAt: Date = Date()) async {
        guard !stopped, !calling, !web.inCall else { return }
        calling = true
        let result = await placeCall(wakeAt: wakeAt)
        calling = false
        guard !stopped else { return }
        show(result)
    }

    /// The popover's Call now: the same fail-closed press as a wake, and it works while listening is paused.
    public var canCallNow: Bool { settings.onboarded && settings.dotURL != nil && !calling && !web.inCall && !checking }

    public func callNow() async {
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

    public func checkCallButton() async {
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
        if outcome == "signed-out" { webSignedIn = false }
        else if ["pressed", "would-press", "disabled", "ambiguous", "not-found"].contains(outcome) { webSignedIn = true }
    }

    // MARK: Built-in browser

    /// Keeps the dot page loaded in the hidden view and re-reads sign-in state.
    public func warmWeb() {
        web.warm(dotURL: settings.dotURL)
        Task { await refreshWebState() }
    }

    @discardableResult
    func refreshWebState() async -> WebPageState {
        let state = await web.pageState()
        if let signedIn = state.signedIn { webSignedIn = signedIn }
        return state
    }

    public func showSignIn() {
        web.showSignIn { [weak self] in Task { await self?.refreshWebState() } }
    }

    public func endCall() { web.endCall() }

    /// WebKit owns the page's microphone and reports its real mute state.
    public var canMute: Bool { web.inCall && web.microphoneMuted != nil }
    public var muted: Bool { web.microphoneMuted == true }

    public func setMuted(_ on: Bool) async {
        if await !web.setMicrophoneMuted(on) {
            show(CallResult(outcome: "mute-failed", message: on ? "Couldn't mute the call's microphone. It is still on."
                                                                : "Couldn't unmute the call's microphone."))
        }
        objectWillChange.send()
    }

    public func signOutWeb() async {
        await web.signOut()
        webSignedIn = false
    }

    public func togglePause() { update { $0.paused.toggle(); $0.pausedUntil = nil } }

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

    public func clearResult() { resultExpiry?.cancel(); lastResult = nil; flashing = false }

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
