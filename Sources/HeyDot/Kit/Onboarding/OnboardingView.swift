import AppKit
import AVFoundation
import SwiftUI
import WakeEngine

/// Setup, in the Frost look: one centred idea per step, the floating tile, centred glass buttons, and on every step
/// that can wait a Later that says where to find it again. The microphone and the call route can't wait.
struct OnboardingView: View {
    @ObservedObject var flow: OnboardingModel
    @ObservedObject var app: AppModel
    @Environment(\.colorScheme) private var scheme
    /// This view sets the accent for its children, so it derives its own from the design directly.
    private var accentHex: UInt32 { Theme.forDesign(app.settings.design).accent }
    /// The fill accent (behind white), and the mark accent (text and marks on the window).
    private var accent: Color { Color(hex: accentHex) }
    private var mark: Color { Color(hex: Accent.mark(accentHex, dark: scheme == .dark)) }

    init(flow: OnboardingModel) {
        self.flow = flow
        self.app = flow.app
    }

    var body: some View {
        SetupStepLayout(back: showsBack ? { flow.back() } : nil) {
            if flow.step != .welcome { progress }
        } content: {
            stepContent
        } note: {
            stepNote
        } buttons: {
            stepButtons
        }
        .background { FrostBackdrop().ignoresSafeArea() }
        .frostTheme(app.settings.design)
        // Back from System Settings: show the permission as it is now, never as assumed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in flow.refreshMicrophone() }
    }

    var progress: some View {
        let steps = Array(OnboardingStep.allCases.dropFirst()), here = steps.firstIndex(of: flow.step) ?? 0
        return HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                Capsule()
                    .fill(i == here ? mark : Color.primary.opacity(i < here ? 0.35 : 0.14))
                    .frame(width: step == flow.step ? 20 : 6, height: 6)
            }
        }
        .frostTheme(app.settings.design)
        .animation(.easeOut(duration: 0.2), value: flow.step)
        .accessibilityElement()
        .accessibilityLabel("Step \(here + 1) of \(steps.count): \(flow.step.title)")
    }

    // MARK: Steps

    // Each step supplies only its content, the note above the buttons and its buttons; `SetupStepLayout` places them.

    @ViewBuilder var stepContent: some View {
        switch flow.step {
        case .welcome: welcome
        case .name: nameStep
        case .voice: voice
        case .connect: connect
        case .done: done
        }
    }

    @ViewBuilder var stepNote: some View {
        switch flow.step {
        case .welcome: EmptyView()
        case .name:
            if let problem = nameProblem { note(problem, problem: true) }
            else { laterHint("Change either one later in Settings.") }
        case .voice:
            if flow.returnAfterTuning, let error = app.settingsError { note(error, problem: true) }
            else if flow.calibration == nil && flow.stage != .permission {
                laterHint("Later uses standard settings. Tune any time in Settings > Voice tuning.")
            }
        case .connect:
            if flow.webSignedIn != true && flow.webChallenge {
                note("chatgpt.com is checking it\u{2019}s you. Finish that in the sign-in window.", problem: true)
            }
        case .done:
            laterHint("Change any of this later in Settings.")
            if let error = app.settingsError ?? flow.loginError { note(error, problem: true) }
        }
    }

    @ViewBuilder var stepButtons: some View {
        switch flow.step {
        case .welcome: primaryButton("Get started", action: flow.primary)
        case .name: primaryButton("Continue", enabled: flow.canContinue, action: flow.primary)
        case .voice: voiceActions
        case .connect:
            if flow.webSignedIn == true { primaryButton("Continue", enabled: flow.canContinue, action: flow.primary) }
            else { primaryButton("Sign in", action: flow.signIn) }
        case .done: doneActions
        }
    }

    /// Back goes to the step before, except from the first and last steps and when tuning was opened from Settings.
    var showsBack: Bool { flow.step != .welcome && flow.step != .done && flow.canGoBack && !flow.returnAfterTuning }

    // MARK: Shared pieces

    func heading(_ title: String, _ detail: String? = nil, size: CGFloat = 34) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: size, weight: .semibold)).tracking(size * -0.02)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.system(size: 16)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560)
    }

    func primaryButton(_ title: String, busy: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                Text(title)
            }
        }
        .frostButton(.primary)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled)
    }

    func laterButton(_ action: @escaping () -> Void) -> some View {
        Button("Later", action: action).frostButton(.secondary)
    }

    /// One plain line: a problem in orange, otherwise a quiet note.
    @ViewBuilder func note(_ text: String?, problem: Bool = false) -> some View {
        if let text {
            Text(text).font(.callout).foregroundStyle(problem ? Color.primary : .secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520)
        }
    }

    /// Where a skipped or changeable choice lives afterwards.
    func laterHint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
    }

    // MARK: Microphone access

    /// The permission as macOS reports it now: allowed, a button that asks, or a link to the Microphone pane.
    @ViewBuilder var microphoneAccess: some View {
        switch flow.micStatus {
        case .authorized:
            Label { Text("Microphone: allowed") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(mark) }
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
        case .denied, .restricted:
            HStack(spacing: 8) {
                Label("Microphone is off for HeyDot", systemImage: "mic.slash").foregroundStyle(.orange)
                Button("Open Privacy Settings", action: flow.openPrivacySettings).frostButton(.chip)
            }
            .font(.system(size: 14, weight: .medium))
        default:
            Button("Enable microphone", action: flow.requestMicrophone).frostButton(.chip)
                .disabled(app.requestingMicrophoneAccess)
        }
    }

    // MARK: Welcome

    var welcome: some View {
        VStack(spacing: 0) {
            FloatingTile(design: .default, size: 164)
            heading("Say \u{201C}Hey Dot.\u{201D}\nYour dot picks up.", "Listening stays on this Mac.", size: 40)
                .padding(.top, 40)
        }
    }

    // MARK: Name

    var nameProblem: String? {
        if case .failure(let problem) = Phrase.validateName(flow.nameDraft) { return problem.message }
        if case .failure(let problem) = flow.phraseResult { return problem.message }
        return flow.nameError
    }

    /// The name the wake word follows while it is on Auto.
    var autoPhrase: String {
        Phrase.title(Phrase.phrase(forName: (try? Phrase.validateName(flow.nameDraft).get()) ?? app.settings.dotName))
    }

    var nameStep: some View {
        VStack(spacing: 0) {
            FloatingTile(design: app.settings.design, size: 100)
            Group {
                if flow.designDeferred {
                    // Later keeps it here (and on the last step, the menu bar and Settings), just quieter.
                    Button { flow.openDotMaker() } label: { Label("Design your dot", systemImage: "paintpalette") }
                        .buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                        .help("Any time from the menu bar or Settings.")
                } else {
                    designPill
                }
            }
            .frame(height: 34)
            .padding(.top, 18)
            heading("Name your dot", "Use the name it has in ChatGPT.").padding(.top, 18)
            HStack(alignment: .top, spacing: 14) {
                field("Name") {
                    TextField("Name", text: $flow.nameDraft, prompt: Text("Dot"))
                        .modifier(FrostField())
                        .onSubmit { if flow.canContinue { flow.next() } }
                }
                .frame(width: 200)
                field("Wake word") {
                    ZStack(alignment: .trailing) {
                        TextField("Wake word", text: Binding(get: { flow.phraseDraft ?? "" },
                                                            set: { flow.phraseDraft = $0.isEmpty ? nil : $0 }),
                                  prompt: Text(autoPhrase))
                            .modifier(FrostField())
                            .onSubmit { if flow.canContinue { flow.next() } }
                        if flow.phraseDraft == nil {
                            Text("Auto").font(.caption.weight(.semibold)).foregroundStyle(mark)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(accent.opacity(0.12), in: Capsule())
                                .padding(.trailing, 12)
                                .help("Follows the name. Type to choose your own wake word.")
                        } else {
                            Button { flow.followName() } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
                                .help("Go back to \u{201C}\(autoPhrase)\u{201D}")
                                .accessibilityLabel("Use \(autoPhrase)")
                        }
                    }
                }
                .frame(width: 236)
            }
            .padding(.top, 22)
        }
    }

    func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 2)
            content()
        }
    }

    var designPill: some View {
        HStack(spacing: 0) {
            Button { flow.openDotMaker() } label: {
                Label("Design your dot", systemImage: "paintpalette").padding(.horizontal, 14).frame(height: 32)
            }
            Divider().frame(height: 18)
            Button { withAnimation(.easeOut(duration: 0.2)) { flow.designDeferred = true } } label: {
                Text("Later").foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 32)
            }
            .help("Design it any time from the menu bar or Settings.")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .fixedSize()
        .background(Capsule().fill(.background.opacity(0.75)).shadow(color: .black.opacity(0.08), radius: 2, y: 1))
    }

    // MARK: Voice

    var voice: some View {
        VStack(spacing: 0) {
            ZStack {
                LiveRings(history: flow.levels, size: 92, active: flow.listening)
                FloatingTile(design: app.settings.design, size: 92)
            }
            .frame(height: 196)
            voiceHeading.padding(.top, 16)
            if flow.calibration == nil {
                VStack(spacing: 14) {
                    phraseSlots
                    voiceStatus
                    if flow.micStatus == .authorized {
                        HStack(spacing: 16) { microphoneAccess; microphonePicker }
                    } else if flow.micStatus == .denied || flow.micStatus == .restricted {
                        note("Microphone access is off for HeyDot. Turn it on in Privacy & Security.", problem: true)
                    }
                }
                .padding(.top, 20)
            }
            if flow.canStartOver {
                Button("Start over", action: flow.startOver).frostButton(.chip)
                    .help("Clear every sample and tune again").padding(.top, 14)
            }
        }
    }

    @ViewBuilder var voiceHeading: some View {
        if flow.calibrating {
            heading("Tuning to your voice\u{2026}", "This takes a second.")
        } else if let summary = flow.tuningSummary {
            heading(flow.tunedPerfectly ? "Tuned to your voice" : "Tuned, as close as it gets", summary)
        } else {
            switch flow.stage {
            case .permission: heading("Turn on the microphone", "HeyDot needs it to hear your wake word. Listening stays on this Mac.")
            case .phrase:
                heading("Say \u{201C}\(flow.phraseTitle)\u{201D} \(Self.count(OnboardingModel.phraseTarget)) times",
                        flow.tuningStarted ? "The way you usually say it, with a pause between each one." : "Press Start, then say it the way you usually do.")
            case .ready: heading("That\u{2019}s everything", "Continue to tune HeyDot to your voice.")
            }
        }
    }

    static func count(_ n: Int) -> String { ["zero", "one", "two", "three", "four", "five", "six"][min(n, 6)] }

    /// Required: the microphone (no Later). Then Start, Try again after a miss, and Continue once enough was heard.
    @ViewBuilder var voiceActions: some View {
        if flow.calibration == nil && flow.stage == .permission {
            if flow.micStatus == .denied || flow.micStatus == .restricted {
                primaryButton("Open Privacy Settings", action: flow.openPrivacySettings)
            } else {
                primaryButton("Enable microphone", action: flow.requestMicrophone)
                    .disabled(app.requestingMicrophoneAccess)
            }
        } else if flow.calibration == nil && (!flow.tuningStarted || flow.problem == .noAudio) {
            laterButton(flow.skipTuning)
            primaryButton(flow.tuningStarted ? "Try again" : "Start", action: flow.startListening)
        } else {
            if flow.calibration == nil { laterButton(flow.skipTuning).disabled(flow.calibrating) }
            primaryButton(flow.calibrating ? "Tuning\u{2026}" : (flow.calibration != nil && flow.returnAfterTuning ? "Done" : "Continue"),
                          busy: flow.calibrating, enabled: flow.canContinue && !flow.calibrating, action: flow.primary)
        }
    }

    var phraseSlots: some View {
        HStack(spacing: 14) {
            ForEach(0..<OnboardingModel.phraseTarget, id: \.self) { i in
                let heard = i < flow.positives.count
                let next = i == flow.positives.count && flow.listening
                ZStack {
                    if heard {
                        Circle().fill(accent)
                        // The tick takes the pill label colour, so it stays readable on true-colour accents (Tray's lime).
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: Accent.label(on: accentHex)))
                    } else if next {
                        Circle().strokeBorder(mark, lineWidth: 2.5)
                        Circle().fill(accent).frame(width: 10, height: 10)
                    } else {
                        Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .onTapGesture { if heard { flow.retry(phrase: i) } }
                .help(heard ? "Say this one again" : "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(flow.phraseTitle), \(i + 1) of \(OnboardingModel.phraseTarget): \(heard ? "heard" : "not yet")")
                .accessibilityAction(named: "Say again") { flow.retry(phrase: i) }
            }
        }
    }

    /// One line under the slots: listening, a problem with what to do about it, or what the last attempt sounded like.
    @ViewBuilder var voiceStatus: some View {
        if flow.problem == .noAudio {
            note("No sound is coming from \(MicrophoneChoices(devices: flow.devices, selection: app.settings.inputDeviceUID).current). Try again, or pick another microphone.", problem: true)
        } else if let error = flow.tuneError {
            note(error, problem: true)
        } else if flow.problem == .quiet {
            note("Listening, but no speech yet. Say \u{201C}\(flow.phraseTitle)\u{201D} a little louder.")
        } else if let hint = flow.hint {
            note(hint)
        } else if flow.listening {
            Label("Listening", systemImage: "waveform").font(.callout.weight(.medium)).foregroundStyle(mark)
        } else {
            Color.clear.frame(height: 18)
        }
    }

    var microphonePicker: some View {
        MicrophoneMenu(devices: flow.devices, selection: Binding(get: { app.settings.inputDeviceUID }, set: { flow.pickDevice($0) }))
    }

    // MARK: Connect ChatGPT (required: no Later)

    @ViewBuilder var connect: some View {
        if flow.webSignedIn == true { pickDot } else { signIn }
    }

    var builtInNote: some View {
        VStack(spacing: 6) {
            Text("HeyDot reaches your dot through a hidden browser built into HeyDot, on this Mac. You sign in once.")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 500)
            Label("Nothing goes through HeyDot servers. There are none.", systemImage: "lock")
                .font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }

    var signIn: some View {
        VStack(spacing: 0) {
            FloatingTile(design: app.settings.design, size: 96)
            heading("Sign in to ChatGPT").padding(.top, 30)
            builtInNote.padding(.top, 12)
        }
    }

    var pickDot: some View {
        VStack(spacing: 0) {
            heading("Pick your dot")
            Label("Signed in. Nothing goes through HeyDot servers.", systemImage: "lock")
                .font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 10)
            dotList.padding(.top, 20)
        }
    }

    /// The dots found in the signed-in page, a link field, and Check.
    var dotList: some View {
        let list = flow.webDots
        return FrostCard {
            VStack(alignment: .leading, spacing: 10) {
                if list.isEmpty {
                    Text("Open your dot to fill in its link automatically, or paste a link below.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 36)
                } else {
                    ScrollView {
                        VStack(spacing: 4) { ForEach(list) { tabRow($0) } }
                    }
                    .frame(height: min(132, CGFloat(list.count) * 44))
                }
                Button("Open ChatGPT…") { flow.openChatGPT(pickingDot: true) }.frostButton(.chip)
                HStack(spacing: 8) {
                    TextField("Link", text: $flow.urlDraft, prompt: Text("https://chatgpt.com/\u{2026}"))
                        .modifier(FrostField(height: Frost.chipHeight + 2, fontSize: 13))
                    Button(flow.checking ? "Checking\u{2026}" : "Check") { Task { await flow.check() } }
                        .disabled(flow.checking || !Phrase.validateDotURL(flow.urlDraft).isSuccess)
                        .help("Finds the call button without pressing it.")
                    Button {
                        Task { await flow.readWeb() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help("Look again").accessibilityLabel("Refresh")
                }
                if let error = flow.urlError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                } else if let result = flow.checkResult {
                    ResultBanner(result: result)
                }
            }
            .frame(width: 470)
        }
    }

    func tabRow(_ tab: DotTab) -> some View {
        let selected = flow.urlDraft == tab.url
        return Button { flow.pick(tab) } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? mark : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title).lineLimit(1)
                    Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Done

    var done: some View {
        VStack(spacing: 0) {
            ZStack {
                TileRings(size: 112)
                FloatingTile(design: app.settings.design, size: 112)
                if flow.heard {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(.white, .frostMark)
                        .offset(x: 50, y: 50)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 232)
            Group {
                if app.settingsError != nil {
                    heading("Save your setup")
                } else {
                    heading(flow.heard ? "Heard you. You\u{2019}re set." : "You\u{2019}re set.",
                            flow.heard ? "Say \u{201C}\(flow.phraseTitle)\u{201D} anytime." : "Say \u{201C}\(flow.phraseTitle)\u{201D} anytime. Nothing to press.")
                }
            }
            .padding(.top, 16)
            HStack(spacing: 18) {
                Toggle("Open at login", isOn: $flow.launchAtLogin).toggleStyle(.switch).controlSize(.small)
                if flow.designDeferred {
                    Button { flow.openDotMaker() } label: { Label("Design your dot", systemImage: "paintpalette") }
                        .buttonStyle(.plain)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.top, 20)
            if app.settingsError == nil && flow.loginError == nil, let result = flow.testResult {
                ResultBanner(result: result).frame(width: 380).padding(.top, 16)
            }
        }
    }

    @ViewBuilder var doneActions: some View {
        Button { Task { await flow.realTestCall() } } label: {
            Label(flow.testCalling ? "Calling\u{2026}" : "Try a call", systemImage: "phone")
        }
        .frostButton(.secondary)
        .disabled(flow.testCalling || app.settings.dotURL == nil)
        .help("Presses your dot's call button once.")
        primaryButton(app.settingsError == nil ? "Done" : "Try Again", action: flow.primary)
    }
}
