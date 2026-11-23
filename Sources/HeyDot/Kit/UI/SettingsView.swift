import AppKit
import SwiftUI
import WakeEngine

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var retune: () -> Void
    var rerunSetup: () -> Void
    var openDotMaker: () -> Void
    @State private var nameDraft = ""
    @State private var nameError: String?
    @State private var phraseDraft = ""
    @State private var phraseError: String?
    @State private var urlDraft = ""
    @State private var urlError: String?
    @State private var loginError: String?
    @State private var devices: [AudioInput] = []
    @State private var checking = false
    static let minimumHeight: CGFloat = 360

    var body: some View {
        Form {
            Section("Your dot") {
                HStack(spacing: 14) {
                    DotTile(model.settings.design, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(.headline)
                        Text("Wake phrase: \u{201C}\(model.settings.phrase.capitalized)\u{201D}").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Design\u{2026}", action: openDotMaker)
                }
                LabeledContent("Menu bar icon") {
                    MenuBarIconPicker(design: model.settings.design, selection: Binding(get: { model.settings.menuBarIcon },
                                                                                        set: { v in model.update { $0.menuBarIcon = v } }), compact: true)
                }
                LabeledContent("Name") {
                    HStack {
                        TextField("Name", text: $nameDraft, prompt: Text("Dot")).labelsHidden().frame(width: 180).onSubmit(applyName)
                        Button("Rename", action: applyName).disabled(nameDraft == model.settings.dotName)
                    }
                }
                if let nameError { Text(nameError).foregroundStyle(.orange).font(.callout) }
                LabeledContent {
                    HStack {
                        TextField("Wake phrase", text: $phraseDraft, prompt: Text(Phrase.title(Phrase.phrase(forName: model.settings.dotName))))
                            .labelsHidden().frame(width: 180).onSubmit(applyPhrase)
                        Button("Change", action: applyPhrase).disabled(phraseDraft.lowercased() == model.settings.phrase)
                    }
                } label: {
                    Text("Wake phrase")
                    Text(model.settings.wakePhrase == nil ? "Follows the name. Two to six words." : "Two to six words. Clear it to use \u{201C}Hey \(model.settings.dotName)\u{201D}.")
                }
                if let phraseError { Text(phraseError).foregroundStyle(.orange).font(.callout) }
                LabeledContent("Voice tuning") {
                    HStack {
                        Text(model.settings.calibrationNote ?? "Standard settings").foregroundStyle(.secondary)
                            .lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
                        Button("Re-run\u{2026}", action: retune)
                    }
                }
            }
            Section {
                LabeledContent("Microphone") {
                    MicrophoneMenu(devices: devices, selection: Binding(get: { model.settings.inputDeviceUID },
                                                                         set: { v in model.update { $0.inputDeviceUID = v } }))
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("HeyDot never switches to headphones on its own, and lets go of the microphone while the display is off or the Mac is locked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ChatGPT") {
                LabeledContent("Dot link") {
                    HStack {
                        TextField("Dot link", text: $urlDraft, prompt: Text("https://chatgpt.com/\u{2026}")).labelsHidden().frame(width: 260).onSubmit(applyURL)
                        Button("Save", action: applyURL).disabled(urlDraft == (model.settings.dotURL ?? ""))
                    }
                }
                if let urlError { Text(urlError).foregroundStyle(.orange).font(.callout) }
                LabeledContent("Call button") {
                    HStack {
                        if let result = model.lastResult, result.outcome != "pressed" {
                            Label(result.message, systemImage: result.wouldPress ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.wouldPress ? AnyShapeStyle(.frostMark) : AnyShapeStyle(.orange)).lineLimit(2)
                                .frame(maxWidth: 260, alignment: .trailing)
                        }
                        Button(checking ? "Checking\u{2026}" : "Check") {
                            Task { checking = true; await model.checkCallButton(); checking = false }
                        }
                        .disabled(model.settings.dotURL == nil || checking || model.calling)
                        .help("Looks for your dot's call button. Never presses it.")
                    }
                }
                LabeledContent("Sign-in") {
                    HStack {
                        Text(model.webSignedIn == true ? "Signed in" : (model.webSignedIn == false ? "Signed out" : "Checking\u{2026}"))
                            .foregroundStyle(model.webSignedIn == true ? AnyShapeStyle(.frostMark) : AnyShapeStyle(.secondary))
                        Button(model.webSignedIn == true ? "Open ChatGPT\u{2026}" : "Sign in\u{2026}", action: model.showSignIn)
                        if model.webSignedIn == true {
                            Button("Sign out", role: .destructive) { Task { await model.signOutWeb() } }
                        }
                    }
                }
            }
            Section("General") {
                Toggle(isOn: Binding(get: { model.settings.paused }, set: { v in model.update { $0.paused = v; $0.pausedUntil = nil } })) {
                    Text("Pause listening")
                    if let until = model.settings.pausedUntil {
                        TimelineView(.everyMinute) { _ in
                            Text("\(AppModel.remaining(until: until)), resumes at \(AppModel.time(until)).")
                        }
                    } else {
                        Text("Stops listening for \u{201C}\(model.settings.phrase.capitalized)\u{201D}. Calls you start yourself still work.")
                    }
                }
                LabeledContent {
                    DatePicker("Morning", selection: Binding(get: { Self.date(minutes: model.settings.morningMinutes) },
                                                             set: { d in model.update { $0.morningMinutes = Self.minutes(d) } }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                } label: {
                    Text("Tomorrow morning is")
                    Text("\u{201C}Pause until tomorrow morning\u{201D} resumes listening at this time.")
                }
                Toggle("Open at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: setLogin))
                if let loginError { Text(loginError).foregroundStyle(.orange).font(.callout) }
            }
            Section("Privacy") {
                PrivacyNote(phrase: model.settings.phrase, viewer: "settings")
            }
            Section {
                HStack {
                    Button("Show log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.log.location]) }
                    Spacer()
                    Button("Run setup again\u{2026}", action: rerunSetup)
                }
            }
            if let error = model.settingsError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        // One Frost treatment for the whole form: every button is a chip, on the frosted window.
        .buttonStyle(FrostButtonStyle(role: .chip))
        .scrollContentBackground(.hidden)
        .background(FrostBackdrop(animated: false).ignoresSafeArea())
        // The grouped form scrolls itself. It must not be fixed to its ideal height: the window would grow past the
        // screen with nothing to scroll, leaving everything below the fold unreachable.
        .frame(width: 560)
        .frame(minHeight: SettingsView.minimumHeight, idealHeight: 680, maxHeight: .infinity)
        .frostAccent(model.settings.design)
        .onAppear {
            nameDraft = model.settings.dotName
            phraseDraft = Phrase.title(model.settings.phrase)
            urlDraft = model.settings.dotURL ?? ""
            devices = AudioInputs.all()
            Task { await model.refreshWebState() }
        }
    }

    func applyName() {
        switch Phrase.validateName(nameDraft) {
        case .success(let name):
            var next = model.settings
            next.rename(name)
            // A name the model can't spell needs its own wake phrase first.
            if case .failure(let problem) = Phrase.validateWakePhrase(next.phrase) {
                nameError = problem.message + " Set a wake phrase below, then rename."
                return
            }
            nameError = nil
            nameDraft = name
            changePhrase { $0.rename(name) }
        case .failure(let problem):
            nameError = problem.message
        }
    }

    /// An empty field goes back to "Hey <Name>".
    func applyPhrase() {
        let raw = phraseDraft.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { phraseError = nil; changePhrase { $0.setWakePhrase(nil) }; return }
        switch Phrase.validateWakePhrase(raw) {
        case .success(let phrase): phraseError = nil; changePhrase { $0.setWakePhrase(phrase) }
        case .failure(let problem): phraseError = problem.message
        }
    }

    /// Applies a change and, when the wake phrase moved, re-runs voice tuning (it was measured on the old one).
    func changePhrase(_ change: (inout AppSettings) -> Void) {
        let before = model.settings.phrase
        model.update(change)
        phraseDraft = Phrase.title(model.settings.phrase)
        if model.settings.phrase != before { retune() }
    }

    static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 8) * 60 + (c.minute ?? 0)
    }

    func applyURL() {
        switch Phrase.validateDotURL(urlDraft) {
        case .success(let url): urlError = nil; model.update { $0.dotURL = url }
        case .failure(let problem): urlError = problem.message
        }
    }

    func setLogin(_ on: Bool) {
        do { try model.hooks.setLaunchAtLogin(on); loginError = nil } catch {
            loginError = "macOS didn't accept the change: \(error.localizedDescription)"
        }
        model.update { $0.launchAtLogin = model.hooks.launchAtLoginEnabled() }
    }
}
