import AppKit
import SwiftUI
import WakeEngine

struct TroubleshootView: View {
    @ObservedObject var doctor: Troubleshooter
    @ObservedObject var model: AppModel
    var retune: () -> Void
    var signIn: () -> Void
    var close: () -> Void
    @State private var devices: [AudioInput] = []
    @State private var reportFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let\u{2019}s find what\u{2019}s wrong").font(.system(size: 20, weight: .semibold))
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
        // A window has nothing behind it but the desktop, so it needs the blur material (the popover brings its own).
        .background(FrostBackdrop(animated: false).ignoresSafeArea())
        .frostTheme(model.settings.design)
        .onAppear { devices = AudioInputs.all() }
        .onReceive(doctor.$running) { running in
            if running { reportFeedback = nil }
        }
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
                    if !doctor.running && step == doctor.failed {
                        HStack(spacing: 8) {
                            fix("Copy troubleshooting report", action: copyReport)
                            if let reportFeedback {
                                Text(reportFeedback).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                case .waiting: EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private func copyReport() {
        let message = doctor.copyReport() ? "Report copied" : "Couldn't copy report"
        reportFeedback = message
        AccessibilityNotification.Announcement(message).post()
    }

    @ViewBuilder func icon(_ state: Troubleshooter.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.tertiary).font(.system(size: 17))
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.frostMark).font(.system(size: 17))
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
                    .disabled(model.requestingMicrophoneAccess)
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
            Text(title).fontWeight(primary ? .semibold : .regular).lineLimit(1).fixedSize()
        }
        .frostButton(.chip)
    }

    @ViewBuilder var footer: some View {
        Divider()
        HStack {
            if doctor.done {
                Label("Everything checks out.", systemImage: "checkmark.seal.fill").foregroundStyle(.frostMark)
                    .font(.callout.weight(.semibold))
            } else if doctor.running {
                Text("Checking\u{2026}").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if doctor.done {
                Button("Call \(model.displayName)") { close(); Task { await model.callNow() } }.frostButton(.primary)
            } else if !doctor.running {
                Button(doctor.failed == nil ? "Start" : "Start over") { doctor.start() }.frostButton(.secondary)
            }
        }
        // One pill height whether it shows Call, Start or nothing, so the window doesn't resize as checks run.
        .frame(height: Frost.pillHeight)
    }
}
