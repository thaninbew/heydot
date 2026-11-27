import SwiftUI

@MainActor
final class PopoverActivity: ObservableObject {
    @Published var visible: Bool
    init(visible: Bool = true) { self.visible = visible }
}

/// The menu bar popover: status, one Call button, one-tap pause chips, and small Design, Settings and Quit icons.
/// Hang up and Mute replace Call only during a call. The privacy note and the listener readout live in Settings.
struct PopoverView: View {
    @ObservedObject var activity = PopoverActivity()
    @ObservedObject var model: AppModel
    var openDotMaker: () -> Void
    var openSettings: () -> Void
    var openOnboarding: () -> Void
    var signIn: () -> Void = {}
    var troubleshoot: () -> Void = {}
    var quit: () -> Void

    var body: some View {
        // The whole subtree, including the level bars' timeline, exists only while the popover is shown.
        if activity.visible { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let result = model.lastResult {
                // Successes clear themselves after a few seconds; only problems need dismissing.
                ResultBanner(result: result, onDismiss: dismiss(result))
                    .transition(.opacity)
            } else if let hint {
                Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            microphoneAction
            if showsRecovery { recovery }
            if model.asksForStar, model.lastResult == nil, !model.web.inCall { starCard.transition(.opacity) }
            primary
            if model.status != .setupNeeded && !model.web.inCall { pauseControls }
            Divider().padding(.top, 2)
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(FrostBackdrop(animated: false, material: false).ignoresSafeArea())
        .frostTheme(model.settings.design)
        .animation(.easeOut(duration: 0.2), value: model.lastResult)
    }

    /// Asked once, after a few calls that worked. Either button answers it for good.
    var starCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "star.fill").foregroundStyle(.frostMark)
            VStack(alignment: .leading, spacing: 8) {
                Text("Enjoying HeyDot? A star on GitHub helps other people find it.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Star on GitHub") { model.answerStarCard(star: true) }.frostButton(.chip)
                    Button("Not now") { model.answerStarCard(star: false) }.frostButton(.chip)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.frostMark.opacity(0.12), in: RoundedRectangle(cornerRadius: Frost.Radius.inset, style: .continuous))
    }

    func dismiss(_ result: CallResult) -> (() -> Void)? {
        result.pressed || result.wouldPress ? nil : { model.clearResult() }
    }

    var header: some View {
        HStack(spacing: 12) {
            DotTile(model.settings.design, size: 52)
                .overlay {
                    if model.web.inCall {
                        RoundedRectangle(cornerRadius: 52 * 0.23 + 4, style: .continuous)
                            .strokeBorder(.frostMark, lineWidth: 2.5).padding(-4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName).font(.system(size: 16, weight: .semibold))
                StatusPill(status: model.status, text: model.statusLine)
            }
            Spacer(minLength: 0)
            if model.status == .listening {
                // 10 Hz only while the popover is open and listening.
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in LevelBars(level: model.engine.inputLevel) }
            }
        }
    }

    var hint: String? {
        switch model.status {
        case .micAccessNeeded: "Enable the microphone to use your wake phrase."
        case .micDenied: "Turn on HeyDot in System Settings > Privacy & Security > Microphone."
        case .signInNeeded: "HeyDot's sign-in to ChatGPT ended."
        case .failed(let message): message
        default: nil
        }
    }

    @ViewBuilder var microphoneAction: some View {
        switch model.status {
        case .micAccessNeeded:
            Button("Enable microphone") { Task { await model.requestMicrophoneAccess() } }
                .frostButton(.chip)
                .disabled(model.requestingMicrophoneAccess)
        case .micDenied:
            Button("Open Privacy Settings", action: model.openMicrophoneSettings).frostButton(.chip)
        default: EmptyView()
        }
    }

    /// One main action: finish setup, sign in, Call, or (in a built-in call) Mute and Hang up.
    @ViewBuilder var primary: some View {
        switch model.status {
        case .setupNeeded:
            wide("Finish setup", symbol: "wand.and.stars", action: openOnboarding)
        case .signInNeeded:
            wide("Sign in to ChatGPT", symbol: "person.crop.circle", action: signIn)
        default:
            if model.web.inCall {
                inCall
            } else {
                Button { Task { await model.callNow() } } label: {
                    Label(model.calling ? "Calling\u{2026}" : "Call \(model.displayName)", systemImage: "phone.fill")
                }
                .frostButton(.wide)
                .disabled(!model.canCallNow)
                .help("Starts your dot's call now, the same way \u{201C}\(Phrase.title(model.settings.phrase))\u{201D} does.")
            }
        }
    }

    /// After a call that didn't start (not a microphone or listener problem): reload the hidden ChatGPT page
    /// from scratch, or open ChatGPT in a window to see what's wrong and sign in again there.
    var showsRecovery: Bool {
        guard case .failed = model.status else { return false }
        return model.engineError == nil
    }

    var recovery: some View {
        HStack(spacing: 6) {
            Button { model.reloadWeb() } label: { Label("Reload", systemImage: "arrow.clockwise").fixedSize() }
                .frostButton(.chip)
                .help("Reloads HeyDot's ChatGPT page from scratch and checks the sign-in again.")
            Button(action: signIn) { Label("Open ChatGPT", systemImage: "macwindow").fixedSize() }
                .frostButton(.chip)
                .help("Shows ChatGPT in a window, so you can see what's wrong and sign in again if you need to.")
            Spacer(minLength: 0)
        }
    }

    func wide(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }.frostButton(.wide)
    }

    /// Round Mute (built-in calls only, where WebKit reports the real state) and Hang up.
    var inCall: some View {
        HStack(spacing: 40) {
            if model.canMute {
                roundAction(model.muted ? "Unmute" : "Mute", symbol: model.muted ? "mic.slash.fill" : "mic.slash", role: .round,
                            help: model.muted ? "Your microphone is muted in the call." : "Mutes your microphone. The call keeps going.") {
                    Task { await model.setMuted(!model.muted) }
                }
            }
            roundAction("Hang up", symbol: "phone.down.fill", role: .hangUp, help: "Ends the call HeyDot started.") { model.endCall() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    func roundAction(_ title: String, symbol: String, role: FrostRole, help: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).frame(width: 54, height: 54)
            }
            .frostButton(role)
            .accessibilityLabel(title)
            .help(help)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Pause

    /// One-tap chips (15 minutes, 1 hour, tomorrow morning) and a timer menu with every option: 15 or 30 minutes,
    /// 1, 2 or 4 hours, tomorrow morning, until resumed, or a custom duration. While paused: the time left and Resume.
    @ViewBuilder var pauseControls: some View {
        if model.settings.paused {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let until = model.settings.pausedUntil {
                        // Ticks once a minute, and only while a timed pause is showing.
                        TimelineView(.everyMinute) { _ in
                            Text(AppModel.remaining(until: until)).font(.callout.weight(.semibold).monospacedDigit())
                        }
                        Text("Calls you start still work").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Paused").font(.callout.weight(.semibold))
                        Text("Until you resume").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Resume") { model.resume() }.frostButton(.chip)
            }
        } else if customPause {
            customPauseRow
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Pause listening", systemImage: "pause").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    chip("15 min") { model.pause(until: Date().addingTimeInterval(15 * 60)) }
                    chip("1 hour") { model.pause(until: Date().addingTimeInterval(3600)) }
                    chip("Tomorrow") { model.pause(until: AppModel.nextMorning(minutes: model.settings.morningMinutes)) }
                        .help("Until \(AppModel.clock(minutes: model.settings.morningMinutes)) tomorrow. The time is set in Settings.")
                    Spacer(minLength: 0)
                    pauseMenu
                }
            }
        }
    }

    func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).lineLimit(1).fixedSize() }
            .frostButton(.chip)
    }

    var pauseMenu: some View {
        Menu {
            ForEach(AppModel.pauseDurations, id: \.0) { label, seconds in
                Button("For \(label)") { model.pause(until: Date().addingTimeInterval(seconds)) }
            }
            Divider()
            Button("Until tomorrow morning (\(AppModel.clock(minutes: model.settings.morningMinutes)))") {
                model.pause(until: AppModel.nextMorning(minutes: model.settings.morningMinutes))
            }
            Button("Until I turn it back on") { model.pause(until: nil) }
            Divider()
            Button("Custom duration\u{2026}") { customPause = true }
        } label: {
            Image(systemName: "timer")
        }
        .menuStyle(.button)
        .frostButton(.chip)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More pause options")
        .help("More: 30 minutes, 2 or 4 hours, until you turn it back on, or a custom time.")
    }

    @State var customPause = false
    @State private var customHours = 1
    @State private var customMinutes = 0

    /// A custom pause: hours and minutes, up to 24 hours.
    var customPauseRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pause for").font(.callout.weight(.semibold))
            HStack(spacing: 12) {
                Stepper("\(customHours) h", value: $customHours, in: 0...24).monospacedDigit()
                Stepper("\(customMinutes) min", value: $customMinutes, in: 0...55, step: 5).monospacedDigit()
                    .disabled(customHours == 24)
            }
            HStack {
                Button("Cancel") { customPause = false }.frostButton(.chip)
                Spacer()
                Button("Pause") {
                    let minutes = customHours * 60 + (customHours == 24 ? 0 : customMinutes)
                    model.pause(until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
                    customPause = false
                }
                .frostButton(.chip)
                .disabled(customHours == 0 && customMinutes == 0)
            }
        }
    }

    // MARK: Footer

    var footer: some View {
        HStack(spacing: 4) {
            // Always here, since a wake that is never heard leaves no error to act on.
            Button(action: troubleshoot) {
                Label("Not working?", systemImage: "questionmark.circle").font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showsRecovery ? Color.primary : Color.secondary)
            .help("Checks the microphone, the wake phrase, your ChatGPT sign-in and the call button, and helps fix what's wrong.")
            Spacer()
            IconButton(symbol: "paintpalette", title: "Design your dot", action: openDotMaker)
            IconButton(symbol: "gearshape", title: "Settings", action: openSettings).keyboardShortcut(",", modifiers: .command)
            IconButton(symbol: "power", title: "Quit HeyDot", action: quit).keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// A small icon-only button with a hover circle.
struct IconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(hover ? Color.primary.opacity(0.08) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A status dot plus line, coloured by state.
struct StatusPill: View {
    let status: AppStatus
    let text: String
    @Environment(\.self) private var env

    var color: Color {
        switch status {
        case .listening: env.frostMark
        case .calling: env.frostMark
        case .paused: .secondary
        default: .orange
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
