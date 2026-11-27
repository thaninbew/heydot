import AppKit
import SwiftUI
import WakeEngine

/// "Not working?": walks the path a wake takes, in order, and stops at the first step that fails with the fix
/// for that step beside it. Microphone access, listening, sound reaching HeyDot, the wake phrase itself,
/// the ChatGPT sign-in, then the call button (found, never pressed).
@MainActor
final class Troubleshooter: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case microphoneAccess, listening, hearing, phrase, signIn, callButton
        var id: Int { rawValue }

        var reportCode: String {
            switch self {
            case .microphoneAccess: "microphone-access"
            case .listening: "listening"
            case .hearing: "hearing"
            case .phrase: "wake-phrase"
            case .signIn: "sign-in"
            case .callButton: "call-button"
            }
        }
    }

    enum Problem: String {
        case micNotAsked = "microphone-permission-needed"
        case micDenied = "microphone-permission-denied"
        case paused = "listening-paused"
        case engine = "listener-failed"
        case silent = "no-microphone-input"
        case quiet = "microphone-input-too-quiet"
        case phraseMissed = "wake-phrase-missed"
        case signedOut = "signed-out"
        case challenge = "sign-in-challenge"
        case unreachable = "chatgpt-unreachable"
        case callButton = "call-button-unavailable"
    }

    enum State: Equatable {
        case waiting, running, ok(String), problem(Problem, String)
        var isProblem: Bool { if case .problem = self { return true }; return false }
    }

    @Published private(set) var states: [Step: State] = [:]
    @Published private(set) var running = false
    /// Live level in dBFS while the hearing step runs, for the meter.
    @Published private(set) var level: Float = -160
    /// Peak dBFS a voice must reach for "HeyDot hears you" (quiet speech at arm's length is about -35).
    var speechLevel: Float = -45
    var hearTimeout: Duration = .seconds(8)
    var phraseTimeout: Duration = .seconds(12)
    var reloadSettle: Duration = .seconds(2)

    let app: AppModel
    private var task: Task<Void, Never>?
    private var heardPhrase = false

    init(app: AppModel) { self.app = app }

    var done: Bool { Step.allCases.allSatisfy { if case .ok = states[$0] { return true }; return false } }
    var failed: Step? { Step.allCases.first { states[$0]?.isProblem == true } }

    func state(_ step: Step) -> State { states[step] ?? .waiting }

    /// Runs from `step` to the end, stopping at the first problem. Earlier results are kept.
    func start(from step: Step = .microphoneAccess) {
        task?.cancel()
        for s in Step.allCases where s.rawValue >= step.rawValue { states[s] = .waiting }
        running = true
        app.log.write("troubleshoot: started at \(step)")
        task = Task { [weak self] in
            guard let self else { return }
            for s in Step.allCases where s.rawValue >= step.rawValue {
                if Task.isCancelled { return }
                self.states[s] = .running
                let result = await self.check(s)
                if Task.isCancelled { return }
                self.states[s] = result
                if case .problem(_, let text) = result { self.app.log.write("troubleshoot: \(s) problem: \(text)") }
                else { self.app.log.write("troubleshoot: \(s) ok") }
                if result.isProblem { break }
            }
            self.endTestListening()
            self.running = false
        }
    }

    /// Closing the window: stop, hand wakes back to calls and listening back to the user's settings.
    func stop() {
        task?.cancel(); task = nil
        running = false
        endTestListening()
    }

    func retry(_ step: Step) { start(from: step) }

    func copyReport(to pasteboard: NSPasteboard = .general) -> Bool {
        guard !running, let failed, case .problem(let problem, _) = state(failed) else { return false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let report = """
            HeyDot version: \(version)
            Step: \(failed.reportCode)
            Reason: \(problem.rawValue)
            """
        pasteboard.clearContents()
        return pasteboard.setString(report, forType: .string)
    }

    /// For QA fixtures only.
    func setFixture(_ fixture: [Step: State], running: Bool = false) { states = fixture; self.running = running }

    // MARK: Fixes

    func allowMicrophone() {
        Task { [weak self, app] in
            await app.requestMicrophoneAccess()
            self?.retry(.microphoneAccess)
        }
    }

    func openPrivacySettings() {
        app.openMicrophoneSettings()
    }

    func resume() { app.resume(); retry(.listening) }

    func reloadChatGPT() {
        app.reloadWeb()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.reloadSettle)
            self.retry(.signIn)
        }
    }

    var microphoneName: String {
        let inputs = AudioInputs.all()
        return AudioInputs.choose(preferredUID: app.settings.inputDeviceUID, among: inputs)?.name ?? "the built-in microphone"
    }

    var phraseTitle: String { "\u{201C}\(Phrase.title(app.settings.phrase))\u{201D}" }

    // MARK: Checks

    /// Wakes go to the troubleshooter while it runs, so saying the phrase never places a call, and listening
    /// runs even while paused (the paused check reports the pause itself).
    private func beginTestListening() {
        guard app.wakeOverride == nil else { return }
        heardPhrase = false
        app.wakeOverride = { [weak self] _ in self?.heardPhrase = true }
        app.refreshListening()
    }

    private func endTestListening() {
        guard app.wakeOverride != nil else { return }
        app.wakeOverride = nil
        app.refreshListening()
    }

    private func check(_ step: Step) async -> State {
        switch step {
        case .microphoneAccess:
            switch app.hooks.microphoneStatus() {
            case .authorized: return .ok("HeyDot can use the microphone.")
            case .notDetermined: return .problem(.micNotAsked, "HeyDot hasn't been allowed to use the microphone yet.")
            default: return .problem(.micDenied, "Microphone access for HeyDot is off in System Settings.")
            }
        case .listening:
            if app.settings.paused { return .problem(.paused, "Listening is paused, so HeyDot isn't listening for \(phraseTitle).") }
            beginTestListening()
            if let error = app.engineError { return .problem(.engine, error) }
            guard app.engine.isListening else { return .problem(.engine, "HeyDot couldn't start listening.") }
            return .ok("Listening on \(microphoneName).")
        case .hearing:
            beginTestListening()
            var peak: Float = -160
            let deadline = ContinuousClock.now + hearTimeout
            while ContinuousClock.now < deadline, !Task.isCancelled {
                level = app.engine.inputLevel
                peak = max(peak, level)
                if peak >= speechLevel { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            level = -160
            if peak >= speechLevel { return .ok("Sound is reaching HeyDot from \(microphoneName).") }
            if peak < -90 { return .problem(.silent, "No sound at all is coming from \(microphoneName).") }
            return .problem(.quiet, "\(microphoneName) is barely picking you up.")
        case .phrase:
            beginTestListening()
            heardPhrase = false
            let deadline = ContinuousClock.now + phraseTimeout
            while ContinuousClock.now < deadline, !heardPhrase, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return heardPhrase ? .ok("Heard \(phraseTitle).") : .problem(.phraseMissed, "Didn't catch \(phraseTitle).")
        case .signIn:
            let page = await app.refreshWebState()
            if page.challenge { return .problem(.challenge, "ChatGPT wants to check it's you.") }
            switch page.signedIn {
            case true?: return .ok("Signed in to ChatGPT.")
            case false?: return .problem(.signedOut, "HeyDot's ChatGPT sign-in has ended.")
            case nil: return .problem(.unreachable, "Couldn't open ChatGPT. Check the internet connection, then reload.")
            }
        case .callButton:
            guard let url = app.settings.dotURL else { return .problem(.callButton, CallResult.describe("no-dot")) }
            let result = await app.check(dotURL: url)
            return result.wouldPress ? .ok("Found \(app.displayName)'s call button.") : .problem(.callButton, result.message)
        }
    }
}
