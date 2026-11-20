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
    }

    enum Problem: Equatable {
        case micNotAsked, micDenied, paused, engine, silent, quiet, phraseMissed, signedOut, challenge, unreachable, callButton
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

    /// For QA fixtures only.
    func setFixture(_ fixture: [Step: State], running: Bool = false) { states = fixture; self.running = running }

    // MARK: Fixes

    func allowMicrophone() {
        app.hooks.requestMicrophone { _ in Task { @MainActor [weak self] in self?.retry(.microphoneAccess) } }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
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

struct TroubleshootView: View {
    @ObservedObject var doctor: Troubleshooter
    @ObservedObject var model: AppModel
    var retune: () -> Void
    var signIn: () -> Void
    var close: () -> Void
    @State private var devices: [AudioInput] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let\u{2019}s find what\u{2019}s wrong").font(.system(size: 20, weight: .bold))
                Text("HeyDot checks each step a call takes, in order, and stops at the first one that fails.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Troubleshooter.Step.allCases) { step in row(step) }
            }
            footer
        }
        .padding(24)
        .frame(width: 460)
        .background(FrostBackdrop(animated: false, material: false).ignoresSafeArea())
        .frostAccent(model.settings.design)
        .onAppear { devices = AudioInputs.all() }
    }

    static func title(_ step: Troubleshooter.Step, phrase: String) -> String {
        switch step {
        case .microphoneAccess: "Microphone access"
        case .listening: "Listening"
        case .hearing: "HeyDot can hear you"
        case .phrase: "Hears \(phrase)"
        case .signIn: "ChatGPT sign-in"
        case .callButton: "Call button"
        }
    }

    @ViewBuilder func row(_ step: Troubleshooter.Step) -> some View {
        let state = doctor.state(step)
        HStack(alignment: .top, spacing: 12) {
            icon(state).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.title(step, phrase: doctor.phraseTitle)).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state == .waiting ? .secondary : .primary)
                switch state {
                case .ok(let text): Text(text).font(.callout).foregroundStyle(.secondary)
                case .running: running(step)
                case .problem(let problem, let text):
                    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    fixes(step, problem)
                case .waiting: EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder func icon(_ state: Troubleshooter.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.tertiary).font(.system(size: 17))
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 17))
        case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 17))
        }
    }

    @ViewBuilder func running(_ step: Troubleshooter.Step) -> some View {
        switch step {
        case .hearing:
            HStack(spacing: 10) {
                Text("Say anything, at your normal volume.").font(.callout.weight(.medium))
                LevelBars(level: doctor.level)
            }
        case .phrase:
            Text("Now say \(doctor.phraseTitle) like you normally would.").font(.callout.weight(.medium))
        default:
            Text("Checking\u{2026}").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func fixes(_ step: Troubleshooter.Step, _ problem: Troubleshooter.Problem) -> some View {
        HStack(spacing: 6) {
            switch problem {
            case .micNotAsked:
                fix("Allow microphone", primary: true, action: doctor.allowMicrophone)
            case .micDenied:
                fix("Open Privacy Settings", primary: true, action: doctor.openPrivacySettings)
                fix("Check again") { doctor.retry(step) }
            case .paused:
                fix("Resume listening", primary: true, action: doctor.resume)
            case .engine:
                fix("Try again", primary: true) { doctor.retry(step) }
            case .silent, .quiet:
                MicrophoneMenu(devices: devices, selection: Binding(get: { model.settings.inputDeviceUID },
                                                                     set: { v in model.update { $0.inputDeviceUID = v } }))
                fix("Try again", primary: true) { doctor.retry(.listening) }
            case .phraseMissed:
                fix("Try again", primary: true) { doctor.retry(step) }
                fix("Re-tune voice\u{2026}", action: retune)
            case .signedOut, .challenge:
                fix("Sign in\u{2026}", primary: true, action: signIn)
                fix("Check again") { doctor.retry(step) }
            case .unreachable, .callButton:
                fix("Reload", primary: true, action: doctor.reloadChatGPT)
                fix("Open ChatGPT\u{2026}", action: signIn)
            }
        }
        if problem == .micDenied {
            Text("Turn on HeyDot under Microphone, then come back and check again.").font(.caption).foregroundStyle(.secondary)
        }
        if problem == .silent || problem == .quiet {
            Text("Pick the microphone you talk into. HeyDot uses the Mac\u{2019}s built-in one unless you choose another.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func fix(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fontWeight(primary ? .semibold : .regular).lineLimit(1).fixedSize().padding(.horizontal, 3)
        }
        .frostButton(.chip)
    }

    @ViewBuilder var footer: some View {
        Divider()
        HStack {
            if doctor.done {
                Label("Everything checks out.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
            } else if doctor.running {
                Text("Checking\u{2026}").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if doctor.done {
                Button("Call \(model.displayName)") { close(); Task { await model.callNow() } }.frostButton(.primary)
            } else if !doctor.running {
                Button(doctor.failed == nil ? "Start" : "Start over") { doctor.start() }.frostButton(.chip)
            }
        }
    }
}
