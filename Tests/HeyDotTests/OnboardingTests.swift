import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@MainActor @Test func setupStaysOpenUntilSettingsCanBeSaved() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    var settings = AppSettings()
    settings.dotURL = "https://chatgpt.com/dots/tray"
    let engine = FakeEngine()
    var hooks = QARender.fakeHooks()
    var loginChanges: [Bool] = []
    hooks.setLaunchAtLogin = { loginChanges.append($0) }
    let app = AppModel(settings: settings, engine: engine, enroller: FakeEnroller(), hooks: hooks, store: store,
                       log: Log(url: URL(fileURLWithPath: "/dev/null")))
    let flow = OnboardingModel(app: app, tuner: FakeTuner())
    flow.step = .done
    var finished = false
    flow.finish = { finished = true }
    try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

    flow.primary()
    #expect(!finished && !app.settings.onboarded && !engine.isListening)
    #expect(loginChanges.isEmpty)
    #expect(app.settingsError != nil)

    try FileManager.default.removeItem(at: store.url)
    flow.primary()
    #expect(finished && app.settings.onboarded && engine.isListening)
    #expect(loginChanges == [true])
    #expect(app.settingsError == nil)
    #expect(try store.load() == app.settings)
}

@MainActor @Test func rejectedLoginItemKeepsSetupOpenAndCanBeSkipped() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    var hooks = QARender.fakeHooks()
    hooks.launchAtLoginEnabled = { false }
    hooks.setLaunchAtLogin = { requested in
        if requested { throw POSIXError(.EPERM) }
    }
    let app = AppModel(settings: AppSettings(), engine: FakeEngine(), enroller: FakeEnroller(),
                       hooks: hooks, store: store, log: Log(url: home.appendingPathComponent("test.log")))
    let flow = OnboardingModel(app: app, tuner: FakeTuner())
    flow.step = .done
    var finished = false
    flow.finish = { finished = true }

    flow.primary()
    #expect(!finished && flow.loginError != nil)
    #expect(!app.settings.onboarded)
    #expect(try !store.load().onboarded)

    flow.launchAtLogin = false
    flow.primary()
    #expect(finished && flow.loginError == nil)
    let saved = try store.load()
    #expect(saved.onboarded && !saved.launchAtLogin)
}

@MainActor @Test func standaloneVoiceTuningDoesNotCompleteSetup() {
    let app = QARender.model { $0.onboarded = false; $0.dotURL = nil }
    let flow = OnboardingModel(app: app, tuner: FakeTuner())
    flow.step = .voice
    flow.returnAfterTuning = true
    var finished = false
    flow.finish = { finished = true }

    flow.skipTuning()
    #expect(finished)
    #expect(!app.settings.onboarded)
}

@MainActor @Test func namingStepSavesTheWakePhraseAndRetunes() {
    let m = QARender.model({ $0.onboarded = false; $0.dotName = "Dot"; $0.wake = WakeSettings(); $0.calibrationNote = "tuned" })
    let f = OnboardingModel(app: m, tuner: FakeTuner())
    f.step = .name
    f.nameDraft = "Tray"; f.editPhrase()
    #expect(f.phraseDraft == "Hey Tray")
    f.phraseDraft = "Hey Siri"
    #expect(!f.canContinue)
    f.phraseDraft = "Okay Tray"
    f.calibration = Tuning(settings: WakeSettings(), caught: 4, falseHits: 0, note: "old")
    #expect(f.commitName())
    #expect(m.settings.phrase == "okay tray" && m.settings.wake.phrase == "okay tray" && m.settings.calibrationNote == nil)
    #expect(f.calibration == nil, "a new phrase is tuned again on the next step")
}

@MainActor @Test func signedInDiscoveryFillsOneLinkAndLeavesSeveralForTheUser() async {
    let web = NoWeb()
    let model = QARender.model({ $0.dotURL = nil }, web: web)
    let first = DotTab(url: "https://chatgpt.com/dots/one", title: "One")
    let second = DotTab(url: "https://chatgpt.com/dots/two", title: "Two")
    let picker = OnboardingModel(app: model)
    web.state = WebPageState(signedIn: true, dots: [first, second])
    await picker.readWeb()
    #expect(picker.webDots == [first, second])
    #expect(picker.urlDraft.isEmpty)
    web.state = WebPageState(signedIn: true, dots: [first])
    let single = OnboardingModel(app: model)
    await single.readWeb()
    #expect(single.urlDraft == first.url)
    web.state = WebPageState(signedIn: true, dots: [first, second])
    await single.readWeb()
    #expect(single.urlDraft.isEmpty)
    single.pick(second)
    await single.readWeb()
    #expect(single.urlDraft == second.url)
    web.state = WebPageState(signedIn: false)
    await single.readWeb()
    #expect(single.webDots.isEmpty && single.urlDraft.isEmpty)
    single.urlDraft = first.url
    await single.readWeb()
    #expect(single.urlDraft == first.url)
}

@MainActor @Test func quittingMidSetupStopsTuningAndLeavesSetupUnfinished() {
    let m = QARender.model({ $0.onboarded = false })
    let tuner = RecordingTuner()
    let f = OnboardingModel(app: m, tuner: tuner)
    f.step = .voice; f.enter(.voice); f.startListening()
    #expect(f.listening)
    m.engine.stop()
    f.shutDown()
    #expect(!f.listening && tuner.stopped > 0, "the tuning microphone is released")
    #expect(!m.engine.isListening, "quitting doesn't start the live listener")
    #expect(!m.settings.onboarded, "the next launch opens setup again")
}

/// The 46 pt buttons (Back, Later, the primary) of a setup screen, read from its accessibility tree, in window points
/// from the top left.
@MainActor private func setupRowButtons(_ view: OnboardingView) -> [(label: String, frame: CGRect)] {
    _ = NSApplication.shared
    // SwiftUI builds its accessibility tree only once an assistive client asks for it.
    NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    let host = NSHostingView(rootView: view.environment(\.frostSnapshot, true))
    let window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 600), styleMask: [.borderless],
                           backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()
    _ = host.accessibilityChildren()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    defer { window.orderOut(nil) }
    func walk(_ element: Any) -> [(String, CGRect)] {
        guard let node = element as? NSObject, let screen = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return [] }
        let frame = CGRect(x: screen.minX - window.frame.minX, y: window.frame.maxY - screen.maxY, width: screen.width, height: screen.height)
        let isPill = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue
            && abs(frame.height - Frost.pillHeight) < 0.5
        let here = isPill ? [(node.value(forKey: "accessibilityLabel") as? String ?? "", frame)] : []
        return here + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(walk)
    }
    return walk(host)
}

@MainActor @Test func setupButtonRowStaysPutOnEveryStepAndState() {
    let url = "https://chatgpt.com/dots/sol"
    let screens: [(String, OnboardingView)] = [
        ("welcome", QARender.flow(.welcome)),
        ("name", QARender.flow(.name)),
        ("name with a problem", QARender.flow(.name, tweak: { $0.nameDraft = "Tray"; $0.editPhrase(); $0.phraseDraft = "Hey Siri" })),
        ("name, design later", QARender.flow(.name, tweak: { $0.designDeferred = true })),
        ("voice permission", QARender.flow(.voice, mic: .notDetermined)),
        ("voice permission denied", QARender.flow(.voice, mic: .denied)),
        ("voice start", QARender.flow(.voice)),
        ("voice listening", QARender.flow(.voice, tweak: { $0.takes = [take("HEY DOT"), take("HEY DOT")]; $0.listening = true; $0.tuningStarted = true })),
        ("voice hint", QARender.flow(.voice, tweak: { $0.takes = [take("HEY DOT")]; $0.listening = true; $0.tuningStarted = true
            $0.hint = "That one sounded different from your others. Say it the way you usually do." })),
        ("voice no audio", QARender.flow(.voice, tweak: { $0.tuningStarted = true; $0.problem = .noAudio })),
        ("voice tuned", QARender.flow(.voice, tweak: { f in
            f.takes = Array(repeating: take("HEY DOT"), count: 4)
            let t = Tuning(settings: WakeSettings(), caught: 4, falseHits: 0, note: "Caught 4 of 4, no false hits.")
            f.calibration = t
            f.tuningSummary = OnboardingModel.summary(t, phrase: "Hey Dot", positives: 4)
        })),
        ("sign in", QARender.flow(.connect, signedIn: false, tweak: { $0.webSignedIn = false })),
        ("sign in, checking it's you", QARender.flow(.connect, signedIn: false, tweak: { $0.webSignedIn = false; $0.webChallenge = true })),
        ("pick a dot", QARender.flow(.connect, tweak: { f in
            f.webSignedIn = true
            f.webDots = [DotTab(url: url, title: "Sol"), DotTab(url: "https://chatgpt.com/dots/tray", title: "Tray")]
            f.urlDraft = url
            f.checkResult = CallResult(outcome: "would-press")
        })),
        ("done", QARender.flow(.done, settings: { $0.dotURL = url })),
        ("done, call result", QARender.flow(.done, settings: { $0.dotURL = url }, tweak: { $0.testResult = CallResult(outcome: "pressed") })),
        ("done, design later", QARender.flow(.done, settings: { $0.dotURL = url }, tweak: { $0.designDeferred = true })),
    ]
    var rowTop: CGFloat?
    for (name, view) in screens {
        let buttons = setupRowButtons(view)
        #expect(!buttons.isEmpty, "\(name): has a button row")
        guard let first = buttons.first else { continue }
        let row = buttons.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        // The row sits at one height on every screen, centred, each pill one height, the wide ones at least 132 wide.
        #expect(abs(row.minY - (rowTop ?? row.minY)) < 0.5, "\(name): row top \(row.minY), first screen \(rowTop ?? 0)")
        rowTop = rowTop ?? row.minY
        #expect(abs(row.midX - 380) < 0.5, "\(name): row centred (mid \(row.midX))")
        for button in buttons where button.label != "Back" {
            #expect(button.frame.width >= FrostButtonStyle.baseWidth, "\(name): \(button.label) is \(button.frame.width) wide")
        }
        if let back = buttons.first(where: { $0.label == "Back" }) { #expect(back.frame.size == CGSize(width: 46, height: 46)) }
    }
}

/// Holds each calibration until the test finishes it.
final class GatedEnroller: WakeEnrolling, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Calibration, Error>] = []
    var pending: Int { lock.withLock { waiting.count } }
    func calibrate(phrase: String, positives: [Clip], negatives: [Clip]) async throws -> Calibration {
        try await withCheckedThrowingContinuation { c in lock.withLock { waiting.append(c) } }
    }
    func finish(_ settings: WakeSettings) {
        lock.withLock { waiting.removeFirst() }.resume(returning: Calibration(settings: settings, caught: 4, falseHits: 0, note: "tuned"))
    }
}

/// A calibration still running when its flow is left (setup closed or reopened) or the wake phrase changes in
/// Settings saves nothing; one that is still current saves its tuning.
@MainActor @Test func staleCalibrationNeverSavesTuning() async throws {
    let enroller = GatedEnroller()
    var settings = AppSettings()
    settings.rename("Tray")
    let app = AppModel(settings: settings, engine: FakeEngine(), enroller: enroller, hooks: QARender.fakeHooks(), store: nil,
                       log: Log(url: URL(fileURLWithPath: "/dev/null")))
    let tuned = WakeSettings(phrase: "hey tray", threshold: 0.2, learned: ["▁HE Y ▁TRA Y"])
    func calibrating(_ change: (OnboardingModel) -> Void) async throws -> OnboardingModel {
        let flow = OnboardingModel(app: app, tuner: FakeTuner())
        flow.step = .voice
        flow.takes = Array(repeating: take("HEY TRAY"), count: 4)
        flow.primary()
        while enroller.pending == 0 { try await Task.sleep(for: .milliseconds(5)) }
        change(flow)
        enroller.finish(tuned)
        while flow.calibrating { try await Task.sleep(for: .milliseconds(5)) }
        return flow
    }

    let before = app.settings.wake
    let left = try await calibrating { $0.leave(.voice) }
    #expect(app.settings.wake == before && left.calibration == nil, "a left flow saves nothing")

    let renamed = try await calibrating { _ in app.update { $0.rename("Dot") } }
    #expect(app.settings.wake == WakeSettings(phrase: "hey dot"), "tuning for hey tray isn't saved under hey dot")
    #expect(renamed.calibration == nil && app.settings.calibrationNote == nil)

    app.update { $0.rename("Tray") }
    let current = try await calibrating { _ in }
    #expect(app.settings.wake == tuned && current.calibration != nil)
}

/// Reopening setup while it is open (the menu, Settings > Re-run, Not working?) leaves the open flow's step first:
/// the Done step's wake test stops swallowing wakes.
@MainActor @Test func reopeningSetupLeavesTheOpenFlow() throws {
    _ = NSApplication.shared
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let app = QARender.model { $0.onboarded = false }
    let delegate = AppDelegate(paths: Paths(home: home), finishingErase: false)
    delegate.model = app
    delegate.showOnboarding(startAt: .done)
    defer { NSApp.windows.filter { $0.delegate === delegate }.forEach { $0.close() } }
    #expect(app.wakeOverride != nil, "the Done step answers wakes itself")
    delegate.showOnboarding()
    #expect(app.wakeOverride == nil, "wakes reach the dot again")
}
