import AVFoundation
import CoreAudio
import SwiftUI
import WakeEngine

enum OnboardingStep: Int, CaseIterable {
    case welcome, name, voice, connect, done

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .name: "Name"
        case .voice: "Voice"
        case .connect: "ChatGPT"
        case .done: "Done"
        }
    }
}

/// The outcome of voice tuning, copied out of the engine's `Calibration` (which has no public init).
struct Tuning: Equatable {
    var settings: WakeSettings
    var caught: Int
    var falseHits: Int
    var note: String
    init(settings: WakeSettings, caught: Int, falseHits: Int, note: String) {
        self.settings = settings; self.caught = caught; self.falseHits = falseHits; self.note = note
    }
    init(_ c: Calibration) { self.init(settings: c.settings, caught: c.caught, falseHits: c.falseHits, note: c.note) }
}

/// Continuous listening for the tuning screen. The live one wraps the engine's `TuningListener`;
/// QA renders use a silent fake.
@MainActor
protocol VoiceTuner: AnyObject {
    func start(phrase: String, inputUID: String?, onLevel: @escaping @MainActor (Float, Bool) -> Void,
               onUtterance: @escaping @MainActor (Utterance) -> Void) throws
    func stop()
}

extension TuningListener: VoiceTuner {}

@MainActor
final class OnboardingModel: ObservableObject {
    let app: AppModel
    @Published var step: OnboardingStep = .welcome
    /// Steps behind this one, for Back.
    var trail: [OnboardingStep] = []
    /// Opened from Settings > Voice tuning: Continue after tuning closes the window.
    var returnAfterTuning = false

    @Published var nameDraft: String
    @Published var nameError: String?
    /// The wake phrase field on the naming step; nil while it follows the name ("Hey <Name>").
    @Published var phraseDraft: String?
    @Published var editingPhrase = false
    /// "Later" on the design pill: the pill shrinks to a plain Design your dot button (still there, and on Done).
    @Published var designDeferred = false
    @Published var micStatus: AVAuthorizationStatus

    // Voice tuning: one screen, the mic stays open, utterances tick slots as they're heard.
    static let phraseTarget = 4, otherTarget = 3
    @Published var positives: [Clip] = []
    @Published var negatives: [Clip] = []
    @Published var listening = false
    /// Tuning starts only when the user presses Start (not on entering the step).
    @Published var tuningStarted = false
    /// What went wrong while listening, if anything: no audio arriving from the device (stopped, with Try again),
    /// or audio but no speech yet (a hint; listening continues).
    @Published var problem: TuneProblem?
    @Published var hint: String?
    @Published var tuneError: String?
    @Published var calibrating = false
    @Published var calibration: Tuning?
    @Published var tuningSummary: String?
    @Published var devices: [AudioInput] = []
    let levels = LevelHistory()
    var tuner: VoiceTuner
    private var listenStart = Date()
    private var soundHeard = false
    /// When the last audio buffer arrived, and the loudest level since Start (digital silence is about -160 dBFS).
    private var lastAudio: Date?
    private var loudest: Float = -160
    /// The clock for the silence checks (tests drive it).
    var now: () -> Date = Date.init
    private var silenceTimer: Timer?

    // Built-in browser: sign-in state and the dots seen on the signed-in page (accumulated while open).
    @Published var webSignedIn: Bool?
    @Published var webDots: [DotTab] = []
    @Published var webChallenge = false
    private var webTimer: Timer?
    private var webReading = false

    @Published var urlDraft: String
    @Published var urlError: String?
    @Published var checkResult: CallResult?
    @Published var checking = false

    @Published var launchAtLogin = true
    @Published var loginError: String?
    @Published var heard = false
    @Published var testResult: CallResult?
    @Published var testCalling = false

    var openDotMaker: () -> Void = {}
    var finish: () -> Void = {}

    init(app: AppModel, tuner: VoiceTuner? = nil) {
        self.app = app
        self.tuner = tuner ?? TuningListener()
        nameDraft = app.settings.dotName
        phraseDraft = app.settings.wakePhrase.map(Phrase.title)
        urlDraft = app.settings.dotURL ?? ""
        micStatus = app.hooks.microphoneStatus()
        launchAtLogin = app.settings.onboarded ? app.settings.launchAtLogin : true
    }

    var name: String { app.settings.dotName }
    var phraseTitle: String { Phrase.title(app.settings.phrase) }

    /// The wake phrase the naming step would save, or why it can't: the typed phrase, else "hey <name>".
    var phraseResult: Result<String, Phrase.WakeProblem> {
        if let draft = phraseDraft, !draft.trimmingCharacters(in: .whitespaces).isEmpty { return Phrase.validateWakePhrase(draft) }
        let name = (try? Phrase.validateName(nameDraft).get()) ?? app.settings.dotName
        return Phrase.validateWakePhrase(Phrase.phrase(forName: name))
    }
    /// What tuning asks for after the wake phrase: the phrase's start with a different name (the confusable
    /// that matters most), the name alone, and "Hey there".
    var otherPrompts: [String] {
        let words = app.settings.phrase.split(separator: " ").map(String.init)
        let decoy = words.contains("john") ? "sam" : "john"
        return [Phrase.title(([words.first ?? "hey"] + [decoy]).joined(separator: " ")),
                Phrase.title(words.dropFirst().joined(separator: " ")), "Hey there"]
    }

    // MARK: Navigation

    var dotPicked: Bool { app.settings.dotURL != nil }

    var canContinue: Bool {
        switch step {
        case .name: Phrase.validateName(nameDraft).isSuccess && phraseResult.isSuccess
        case .voice: calibration != nil || canSet
        case .connect: (webSignedIn == true) && Phrase.validateDotURL(urlDraft).isSuccess
        default: true
        }
    }

    /// The footer's main button.
    func primary() {
        if step == .voice && calibration == nil { Task { await calibrate() }; return }
        next()
    }

    func next() {
        switch step {
        case .name:
            guard commitName() else { return }
        case .connect:
            guard commitURL() else { return }
        case .voice where returnAfterTuning:
            complete(); return
        case .done:
            complete(); return
        default: break
        }
        go(to: following(step))
    }

    private func following(_ s: OnboardingStep) -> OnboardingStep {
        switch s {
        case .welcome: return .name
        case .name: return .voice
        case .voice: return .connect
        case .connect, .done: return .done
        }
    }

    private func go(to target: OnboardingStep) {
        leave(step)
        trail.append(step)
        step = target
        enter(step)
    }

    /// Quitting mid-setup: leave the step (stops tuning and its microphone, timers and test hooks) without
    /// finishing setup.
    func shutDown() {
        stopTuning()
        stopWatchingWeb()
        app.wakeOverride = nil
    }

    func back() {
        guard let previous = trail.popLast() else { return }
        leave(step)
        step = previous
        enter(step)
    }

    var canGoBack: Bool { !trail.isEmpty }

    func enter(_ step: OnboardingStep) {
        switch step {
        case .voice: enterTuning()
        case .connect:
            startWatchingWeb()
        case .done: startTest()
        default: break
        }
    }

    func leave(_ step: OnboardingStep) {
        switch step {
        case .connect: stopWatchingWeb()
        case .voice: stopTuning(); app.refreshListening()
        case .done: stopTest()
        default: break
        }
    }

    private func complete() {
        guard app.saveSetup() else { return }
        if step == .done {
            do {
                try app.hooks.setLaunchAtLogin(launchAtLogin)
                loginError = nil
            } catch {
                loginError = error.localizedDescription
                return
            }
            let enabled = app.hooks.launchAtLoginEnabled()
            guard app.saveSetup({ $0.launchAtLogin = enabled; $0.onboarded = true }) else { return }
        }
        leave(step)
        finish()
    }

    // MARK: Name

    /// Saves the name and the wake phrase. A changed phrase resets tuning, so the voice step that follows
    /// tunes to the new one.
    func commitName() -> Bool {
        switch (Phrase.validateName(nameDraft), phraseResult) {
        case (.success(let name), .success(let phrase)):
            nameError = nil
            let before = app.settings.phrase
            let custom = phraseDraft.map { $0.trimmingCharacters(in: .whitespaces).isEmpty } == false ? phrase : nil
            app.update { $0.rename(name); $0.setWakePhrase(custom) }
            if app.settings.phrase != before { resetTuning() }
            return true
        case (.failure(let problem), _):
            nameError = problem.message
            return false
        case (_, .failure(let problem)):
            nameError = problem.message
            editingPhrase = true
            return false
        }
    }

    /// "Change" next to the wake phrase: starts from the phrase shown.
    func editPhrase() {
        if phraseDraft == nil { phraseDraft = (try? phraseResult.get()).map(Phrase.title) ?? "" }
        editingPhrase = true
    }

    /// Back to "Hey <Name>".
    func followName() {
        phraseDraft = nil
        editingPhrase = false
    }

    // MARK: Microphone

    func requestMicrophone() {
        Task { [weak self, app] in
            await app.requestMicrophoneAccess()
            self?.refreshMicrophone()
        }
    }

    /// Re-reads the permission (on entering the step and whenever HeyDot becomes active again, such as after
    /// System Settings).
    func refreshMicrophone() {
        micStatus = app.hooks.microphoneStatus()
    }

    func openPrivacySettings() {
        app.openMicrophoneSettings()
    }

    // MARK: Voice tuning

    enum TuneStage { case permission, phrase, others, ready }
    enum TuneProblem: Equatable { case noAudio, quiet }

    var stage: TuneStage {
        if micStatus != .authorized { return .permission }
        if positives.count < Self.phraseTarget { return .phrase }
        if negatives.count < Self.otherTarget && calibration == nil { return .others }
        return .ready
    }

    /// Enough was heard to tune: three of the four wake phrases (the other phrases help but are optional).
    var canSet: Bool { positives.count >= Self.phraseTarget - 1 && !calibrating && calibration == nil }

    /// Entering the step reads the permission and the device list; nothing listens until Start.
    func enterTuning() {
        micStatus = app.hooks.microphoneStatus()
        refreshDevices()
        tuningStarted = false
        problem = nil
    }

    /// The Start button (and Try again after a miss).
    func startListening() {
        startTuning()
    }

    private func startTuning() {
        refreshMicrophone()
        guard micStatus == .authorized else { return }
        stopTuning()
        tuningStarted = true
        // The live engine shares the mic; pause it so a "Hey <name>" here can't start a real call.
        if app.engine.isListening { app.engine.stop() }
        tuneError = nil; problem = nil; soundHeard = false; listenStart = now()
        lastAudio = nil; loudest = -160
        levels.reset()
        do {
            try tuner.start(phrase: app.settings.phrase, inputUID: app.settings.inputDeviceUID, onLevel: { [weak self] db, sound in
                self?.level(db, sound: sound)
            }, onUtterance: { [weak self] u in self?.heard(u) })
            listening = true
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkSilence() }
            }
        } catch {
            listening = false
            micStatus = app.hooks.microphoneStatus()  // a denied permission shows its own controls
            tuneError = AppModel.describe(error)
            app.log.write("tuning: start failed: \(error)")
        }
    }

    func level(_ db: Float, sound: Bool) {
        lastAudio = now()
        loudest = max(loudest, db)
        levels.push(db)
        if sound && !soundHeard { soundHeard = true; if problem == .quiet { problem = nil } }
    }

    func stopTuning() {
        tuner.stop()
        silenceTimer?.invalidate(); silenceTimer = nil
        listening = false
    }

    /// Once a second while listening. No buffer for 3 s, or nothing but digital silence (what a microphone gives
    /// without permission or a working device), stops with `.noAudio`; real audio with no speech for 10 s is
    /// only a hint. The clock starts at Start, not on entering the step.
    func checkSilence() {
        guard listening else { return }
        let t = now()
        let sinceAudio = t.timeIntervalSince(lastAudio ?? listenStart)
        let digitalSilence = t.timeIntervalSince(listenStart) >= 3 && loudest < -100
        if sinceAudio >= 3 || digitalSilence {
            app.log.write("tuning: no audio from the \(app.settings.inputDeviceUID == nil ? "built-in" : "chosen") microphone"
                          + (lastAudio == nil ? " (no buffers in 3 s)" : (digitalSilence ? " (only digital silence)" : " (buffers stopped)")))
            stopTuning()
            withAnimation(.easeOut(duration: 0.2)) { problem = .noAudio }
        } else if !soundHeard && positives.isEmpty && negatives.isEmpty && t.timeIntervalSince(listenStart) >= 10, problem == nil {
            withAnimation(.easeOut(duration: 0.2)) { problem = .quiet }
        }
    }

    /// One utterance while tuning. A wake-phrase slot ticks only when the model heard the phrase; anything
    /// else gets a truthful hint and no tick, so a confusable ("Hey John") is never counted as a success.
    func heard(_ u: Utterance) {
        let say = "Say \u{201C}\(phraseTitle)\u{201D}"
        switch stage {
        case .phrase:
            guard u.duration <= 4 else { hint = "That was a long one. \(say), then pause."; return }
            switch u.hearing {
            case .phrase:
                hint = "Heard it."
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { positives.append(u.clip) }
            case .otherName(let words):
                hint = "That sounded like \u{201C}\(Phrase.title(words.lowercased()))\u{201D}, a different name. \(say)."
            case .missingStart(let words):
                hint = "Heard \u{201C}\(Phrase.title(words.lowercased()))\u{201D} without the start. \(say)."
            case .nothing:
                hint = "Didn\u{2019}t catch that. \(say) again."
            }
        case .others:
            guard u.duration >= 0.3 else { return }
            guard !u.matched else {
                hint = "That was \u{201C}\(phraseTitle)\u{201D}. Now say \u{201C}\(otherPrompts[negatives.count])\u{201D}."
                return
            }
            hint = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { negatives.append(u.clip) }
            if negatives.count >= Self.otherTarget { stopTuning() }
        case .permission, .ready:
            break
        }
    }

    func resetTuning() {
        positives = []; negatives = []
        calibration = nil; tuningSummary = nil; hint = nil; tuneError = nil
    }

    var canStartOver: Bool { (!positives.isEmpty || !negatives.isEmpty) && !calibrating && micStatus == .authorized }

    /// Start over: clears every sample (and any result) and listens again from the first wake phrase.
    func startOver() {
        resetTuning()
        if step == .voice && micStatus == .authorized && tuningStarted { startTuning() }
    }

    /// Retries one sample: removes that wake phrase (or other phrase) so the next utterance fills it again.
    func retry(phrase index: Int) {
        guard positives.indices.contains(index), !calibrating else { return }
        positives.remove(at: index)
        retried()
    }

    func retry(other index: Int) {
        guard negatives.indices.contains(index), !calibrating else { return }
        negatives.removeSubrange(index...)  // the prompts are asked in order
        retried()
    }

    private func retried() {
        calibration = nil; tuningSummary = nil; hint = nil
        if step == .voice && micStatus == .authorized && tuningStarted && !listening { startTuning() }
    }

    func calibrate() async {
        guard canSet else { return }
        stopTuning()
        calibrating = true
        defer { calibrating = false }
        do {
            let result = try await app.enroller.calibrate(phrase: app.settings.phrase, positives: positives, negatives: negatives)
            let tuning = Tuning(result)
            calibration = tuning
            tuningSummary = Self.summary(tuning, phrase: phraseTitle, positives: positives.count, negatives: negatives.count)
            app.update { $0.wake = result.settings; $0.calibrationNote = result.note }
        } catch {
            tuneError = AppModel.describe(error)
        }
    }

    /// The tuning result in plain words (the heading says whether it was perfect).
    static func summary(_ t: Tuning, phrase: String, positives p: Int, negatives n: Int) -> String {
        if t.caught == p && t.falseHits == 0 {
            return n > 0 ? "HeyDot caught all \(p) of your \u{201C}\(phrase)\u{201D}s and ignored all \(n) other phrases."
                         : "HeyDot caught all \(p) of your \u{201C}\(phrase)\u{201D}s."
        }
        let answered = n > 0 ? " and answered \(t.falseHits) of the \(n) other phrases" : ""
        return "HeyDot caught \(t.caught) of your \(p) \u{201C}\(phrase)\u{201D}s\(answered). Try again somewhere quieter, or keep this."
    }

    var tunedPerfectly: Bool { calibration.map { $0.caught == positives.count && $0.falseHits == 0 } ?? false }

    func skipTuning() {
        stopTuning()
        let settings = WakeSettings(phrase: app.settings.phrase)
        calibration = Tuning(settings: settings, caught: 0, falseHits: 0, note: "Standard settings")
        tuningSummary = "Using the standard settings. You can tune HeyDot to your voice later in Settings."
        app.update { $0.wake = settings; $0.calibrationNote = nil }
        next()
    }

    func refreshDevices() { devices = AudioInputs.all() }

    /// HeyDot's own microphone choice (nil: built-in). The macOS default input is left alone.
    func pickDevice(_ uid: String?) {
        guard uid != app.settings.inputDeviceUID else { return }
        app.update { $0.inputDeviceUID = uid }
        if listening || problem != nil { startTuning() }
    }

    // MARK: Built-in browser

    func signIn() { app.showSignIn() }

    func startWatchingWeb() {
        stopWatchingWeb()
        Task { await readWeb() }
        webTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.readWeb() }
        }
    }

    func stopWatchingWeb() { webTimer?.invalidate(); webTimer = nil }

    func readWeb() async {
        guard !webReading else { return }
        webReading = true
        defer { webReading = false }
        let state = await app.refreshWebState()
        if let signedIn = state.signedIn { webSignedIn = signedIn }
        webChallenge = state.challenge
        for dot in state.dots where !webDots.contains(where: { $0.url == dot.url }) { webDots.append(dot) }
        if urlDraft.isEmpty, let first = webDots.first { urlDraft = first.url }
    }

    // MARK: Pick dot

    @discardableResult
    func commitURL() -> Bool {
        switch Phrase.validateDotURL(urlDraft) {
        case .success(let url):
            urlError = nil
            app.update { $0.dotURL = url }
            return true
        case .failure(let problem):
            urlError = problem.message
            return false
        }
    }

    func pick(_ tab: DotTab) {
        urlDraft = tab.url
        checkResult = nil
    }

    func check() async {
        guard commitURL() else { return }
        checking = true
        checkResult = await app.check(dotURL: urlDraft)
        checking = false
    }

    // MARK: Done

    func startTest() {
        heard = false
        testResult = nil
        app.wakeOverride = { [weak self] _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { self?.heard = true }
        }
        app.refreshListening()
    }

    func stopTest() {
        app.wakeOverride = nil
        app.refreshListening()
    }

    func realTestCall() async {
        testCalling = true
        testResult = await app.placeCall()
        testCalling = false
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
