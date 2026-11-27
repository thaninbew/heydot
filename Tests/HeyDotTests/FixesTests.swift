import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WakeEngine
@testable import HeyDotKit

// MARK: Wake phrase

@Test func wakePhraseRules() throws {
    #expect(try Phrase.validateWakePhrase("Okay  Tray").get() == "okay tray")
    #expect(Phrase.validateWakePhrase("tray") == .failure(.wordCount))
    #expect(Phrase.validateWakePhrase("one two three four five six seven") == .failure(.wordCount))
    #expect(Phrase.validateWakePhrase("hey tray2") == .failure(.characters("tray2")))
    #expect(Phrase.validateWakePhrase("hey o'neil") == .failure(.characters("o'neil")))
    #expect(Phrase.validateWakePhrase("Hey Siri") == .failure(.reserved("siri")))
    #expect(Phrase.validateWakePhrase("hey jarvis") == .failure(.reserved("jarvis")))
    #expect(Phrase.validateWakePhrase("ok google play") == .failure(.reserved("ok google")))
    #expect(Phrase.validateWakePhrase("hey tray", encodable: { _ in false }) == .failure(.notEncodable))
    #expect(Phrase.title("okay tray") == "Okay Tray")
}

@Test func wakePhraseIsEncodedByTheRealKeywordModel() throws {
    guard let dir = try? ModelFiles.locate() else { return }  // the model is fetched by Scripts/fetch-vendor.sh
    let tokenizer = try KeywordTokenizer(modelDirectory: dir)
    #expect(try !tokenizer.pieces(for: "okay tray").isEmpty)
}

@Test func wakePhraseIsIndependentOfTheName() throws {
    var s = AppSettings()
    s.rename("Tray")
    #expect(s.phrase == "hey tray" && s.wakePhrase == nil)
    s.wake.score = 1.5; s.calibrationNote = "Caught 4 of 4"
    s.setWakePhrase("okay tray")
    #expect(s.phrase == "okay tray" && s.wake.phrase == "okay tray" && s.wake.score == WakeSettings().score && s.calibrationNote == nil)
    s.calibrationNote = "tuned"
    s.rename("Sol")  // a custom phrase survives a rename, and so does its tuning
    #expect(s.phrase == "okay tray" && s.calibrationNote == "tuned" && s.dotName == "Sol")
    s.setWakePhrase("hey sol")  // the name's own phrase is stored as "follow the name"
    #expect(s.wakePhrase == nil && s.phrase == "hey sol")
    s.setWakePhrase("okay sol"); s.morningMinutes = 7 * 60 + 30
    let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
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

// MARK: Pause

@MainActor @Test func pauseUntilMorningAndTimeLeft() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
    let evening = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 21, minute: 41))!
    #expect(AppModel.nextMorning(minutes: 480, now: evening, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 8)))
    let night = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 1, minute: 5))!
    #expect(AppModel.nextMorning(minutes: 7 * 60 + 30, now: night, calendar: cal)
            == cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 7, minute: 30)))
    let now = Date()
    #expect(AppModel.remaining(until: now.addingTimeInterval(42 * 60), now: now) == "42 min left")
    #expect(AppModel.remaining(until: now.addingTimeInterval(65 * 60), now: now) == "1 h 5 min left")
    #expect(AppModel.remaining(until: now.addingTimeInterval(2 * 3600), now: now) == "2 h left")
    #expect(AppModel.remaining(until: now.addingTimeInterval(20), now: now) == "Less than a minute left")
    #expect(AppModel.pauseDurations.map(\.1) == [900, 1800, 3600, 7200, 14400])
}

// MARK: Privacy and security

@Test func callViewStaysOnChatGPTAndSignInStaysOnHTTPS() {
    func allows(_ s: String, main: Bool = true, call: Bool) -> Bool { WebCallBackend.allowsNavigation(to: URL(string: s), mainFrame: main, callView: call) }
    #expect(allows("https://chatgpt.com/dots/sol", call: true))
    #expect(!allows("https://auth.openai.com/log-in", call: true))
    #expect(!allows("https://evil.example/chatgpt.com", call: true))
    #expect(!allows("http://chatgpt.com/", call: true))
    #expect(allows("https://challenges.cloudflare.com/x", main: false, call: true))  // the page's own frames
    #expect(allows("https://accounts.google.com/o/oauth2", call: false))
    #expect(!allows("http://accounts.google.com/", call: false))
    #expect(WebCallBackend.keepsData(for: "chatgpt.com") && WebCallBackend.keepsData(for: "openai.com"))
    #expect(!WebCallBackend.keepsData(for: "google.com") && !WebCallBackend.keepsData(for: "apple.com"))
}

@Test func privateDirectoriesAndNewParentsAre0700() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("heydot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let run = root.appendingPathComponent("HeyDot/run")
    try Paths.ensureDirectory(run, mode: 0o700)
    for dir in [run, run.deletingLastPathComponent()] {
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o700, "\(dir.lastPathComponent)")
    }
}

// MARK: Sign-in window

@MainActor @Test func returnInTheSignInWindowNeverPressesDone() {
    _ = NSApplication.shared
    func pressesOnReturn<V: View>(_ make: (@escaping () -> Void) -> V) -> Bool {
        var fired = false
        let window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: make { fired = true })
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = window.performKeyEquivalent(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.orderOut(nil)
        return fired
    }
    // The harness does see a default button take Return...
    #expect(pressesOnReturn { done in Button("Done", action: done).keyboardShortcut(.defaultAction).padding() })
    // ...and the sign-in window's Done is not one.
    #expect(!pressesOnReturn { done in SignInView(web: nil, state: SignInState(), done: done) })
}

// MARK: Voice tuning: Start, and telling a dead microphone from a quiet room

@MainActor
final class RecordingTuner: VoiceTuner {
    var starts: [String?] = []
    var onLevel: (@MainActor (Float, Bool) -> Void)?
    var stopped = 0
    func start(phrase: String, inputUID: String?, onLevel: @escaping @MainActor (Float, Bool) -> Void,
               onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
        starts.append(inputUID); self.onLevel = onLevel
    }
    func stop() { stopped += 1; onLevel = nil }
}

@MainActor private func tuningFlow(mic: AVAuthorizationStatus = .authorized) -> (OnboardingModel, RecordingTuner, () -> Void) {
    let m = QARender.model({ $0.onboarded = false }, mic: mic)
    let tuner = RecordingTuner()
    let f = OnboardingModel(app: m, tuner: tuner)
    var clock = Date(timeIntervalSince1970: 1_000)
    f.now = { clock }
    f.step = .voice
    f.enter(.voice)
    return (f, tuner, { clock.addTimeInterval(1) })
}

@MainActor @Test func tuningWaitsForStartAndNeverStartsWithoutPermission() {
    let (f, tuner, _) = tuningFlow()
    #expect(tuner.starts.isEmpty && !f.listening, "entering the step must not open the microphone")
    f.startListening()
    #expect(tuner.starts.count == 1 && f.listening && f.tuningStarted)
    for status in [AVAuthorizationStatus.notDetermined, .denied] {
        let (g, t, _) = tuningFlow(mic: status)
        #expect(g.stage == .permission)
        g.startListening()
        #expect(t.starts.isEmpty && !g.listening)
    }
}

@MainActor @Test func noBuffersOrDigitalSilenceStopWithNoAudioButAQuietRoomOnlyHints() {
    // No buffer at all within 3 s (the round-1 capture bound to a dead I/O unit): stop and offer Try again.
    var (f, tuner, tick) = tuningFlow()
    f.startListening()
    tick(); tick(); f.checkSilence()
    #expect(f.problem == nil, "2 s is not yet a dead microphone")
    tick(); f.checkSilence()
    #expect(f.problem == .noAudio && !f.listening && tuner.stopped > 0)
    f.startListening()
    #expect(f.problem == nil && f.listening && tuner.starts.count == 2, "Try again reopens it")

    // Buffers that are pure digital silence, as without a working microphone: the same.
    (f, tuner, tick) = tuningFlow()
    f.startListening()
    for _ in 0..<3 { tuner.onLevel?(-160, false); tick() }
    f.checkSilence()
    #expect(f.problem == .noAudio)

    // A real but quiet room (noise floor, no speech): keep listening, with a hint after 10 s.
    (f, tuner, tick) = tuningFlow()
    f.startListening()
    for _ in 0..<10 { tuner.onLevel?(-62, false); tick(); f.checkSilence() }
    #expect(f.problem == .quiet && f.listening)
    tuner.onLevel?(-20, true)
    #expect(f.problem == nil, "speech clears the hint")
}

// MARK: Accent

@Test func accentReadsOnEveryDotColourInLightAndDark() {
    let sources = DotColor.allCases.map(\.hex) + [Accent.defaultHex, 0x1F1F23, 0xF4F0FF, 0xFFFFFF, 0x000000]
    for raw in sources {
        let fill = Accent.ui(raw)
        #expect(Accent.contrast(fill, 0xFFFFFF) >= 4.5, "white button text on \(String(raw, radix: 16))")
        #expect(Accent.contrast(fill, Accent.lightWindow) >= 3, "marks on a light window")
        #expect(Accent.contrast(fill, Accent.darkWindow) >= 3, "button on a dark window")
        #expect(Accent.contrast(Accent.mark(fill, dark: true), Accent.darkWindow) >= Accent.markContrast, "marks on a dark window (3:1 since round 7)")
    }
    #expect(Accent.hex(for: .default) == Accent.ui(Accent.defaultHex), "an undesigned dot uses the logo's coral")
    #expect(Accent.hex(for: DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody)) == Accent.ui(DotColor.lime.hex))
    #expect(Accent.hex(for: DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody)) != Accent.hex(for: DotDesign(color: .yellow)))
}

// MARK: Settings scroll

@MainActor @Test func settingsScrollsAtItsSmallestWindowSize() async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: SettingsView(model: QARender.model(), retune: {}, openDotMaker: {}, eraseAndRestart: {})
        .frame(width: 560, height: SettingsView.minimumHeight))
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: SettingsView.minimumHeight),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
    let scroll = try #require(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    let content = try #require(scroll.documentView).frame.height
    #expect(content > scroll.contentView.bounds.height + 100, "Settings is taller than its smallest window")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: content - scroll.contentView.bounds.height))
    #expect(scroll.contentView.bounds.origin.y > 100, "and scrolls to its last section")
    window.orderOut(nil)
}

// MARK: Embedded sign-in errors

@Test func googlesEmbeddedBrowserRefusalIsDetected() {
    #expect(WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://accounts.google.com/v3/signin/rejected?continue=x")))
    #expect(WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://accounts.google.com/signin/rejected")))
    #expect(!WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://accounts.google.com/v3/signin/identifier")))
    #expect(!WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://chatgpt.com/rejected")))
}

// MARK: Command-Q and the main menu

@MainActor @Test func mainMenuQuitsClosesAndEdits() {
    let menu = AppDelegate.mainMenu()
    let items = menu.items.compactMap(\.submenu).flatMap(\.items)
    func item(_ key: String) -> NSMenuItem? { items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command } }
    #expect(item("q")?.action == #selector(NSApplication.terminate(_:)))
    #expect(item("w")?.action == #selector(NSWindow.performClose(_:)))
    for (key, action) in [("x", "cut:"), ("c", "copy:"), ("v", "paste:"), ("a", "selectAll:"), ("z", "undo:")] {
        #expect(item(key)?.action == Selector(action), "Command-\(key.uppercased())")
    }
    #expect(items.contains { $0.keyEquivalent == "Z" && $0.action == Selector(("redo:")) })
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

// MARK: Theme from dot

@Test func themeIsFrostUntilThereIsADotAndDeterministicAfter() {
    #expect(Theme.forDesign(.default) == Theme.from(palette: [Accent.defaultHex]), "the default logo themes from its coral")
    let body = Accent.defaultHex, eyes = Accent.ink(for: body)  // the drawn logo: coral body, same-hue ink eyes
    #expect(DotDesign.default.fill == .colorBody)
    #expect(Accent.contrast(body, eyes) >= 4.4)
    #expect(OKLCH.hueDistance(OKLCH(hex: body).h, OKLCH(hex: eyes).h) < 3)
    #expect(Theme.frost.light == [0xFB9890, 0xF4BF8C, 0xF4A0C8] && Theme.frost.accent == Accent.ui(Accent.defaultHex))
    var avatar = DotDesign.default; avatar.signature = nil
    avatar.custom = CustomArt(id: "x", silhouette: true)
    #expect(Theme.forDesign(avatar) == .frost, "an imported avatar has no palette to read")
    for design in [DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody), DotDesign(color: .teal, accessory: .headphones, accessoryColor: .blue), DotDesign(color: .charcoal)] {
        #expect(Theme.forDesign(design) == Theme.forDesign(design))
    }
    #expect(Theme.from(palette: [0x2DB84D, 0x2F6BFF]) == Theme.from(palette: [0x2DB84D, 0x2F6BFF]))
}

@Test func themeStaysSoftAndReadableAcrossASpreadOfDots() {
    let faces = DotColor.faceColors.map(\.hex)
    let extremes: [UInt32] = [0xE0353B, 0xF6D6E8, 0xF4F0FF, 0x39FF14, 0xFF00FF, 0x00FFFF, 0x1F1F23, 0x000000, 0xFFFFFF, 0x808080]
    let palettes = (faces + extremes).map { [$0] } + faces.flatMap { a in faces.filter { $0 != a }.map { [a, $0] } }
    for palette in palettes {
        let theme = Theme.from(palette: palette)
        #expect(theme.light.count == 3 && theme.dark.count == 3)
        let label = Accent.label(on: theme.accent)
        let text = Accent.contrast(theme.accent, label)
        #expect(text >= 4.5 || (label == 0xFFFFFF && text >= 3), "pill label on \(palette): \(text)")
        for dark in [false, true] {
            let mark = Accent.mark(theme.accent, dark: dark)
            #expect(Accent.contrast(mark, dark ? Accent.darkWindow : Accent.lightWindow) >= Accent.markContrast, "marks for \(palette)")
        }
        for (stops, bounds) in [(theme.light, Theme.lightnessBounds.light), (theme.dark, Theme.lightnessBounds.dark)] {
            for stop in stops {
                let c = OKLCH(hex: stop)
                #expect(bounds.contains(c.l) || abs(c.l - bounds.lowerBound) < 0.02 || abs(c.l - bounds.upperBound) < 0.02,
                        "lightness \(c.l) for \(palette)")
                #expect(c.c <= Theme.chromaBounds.upperBound + 0.01, "chroma \(c.c) for \(palette)")
            }
        }
    }
}

@Test func themeHuesFollowTheDotAndFillTheGap() {
    // One hue: the dot's own hue leads.
    let red = Theme.from(palette: [0xE0353B])
    #expect(OKLCH.hueDistance(OKLCH(hex: red.light[0]).h, OKLCH(hex: 0xE0353B).h) < 10)
    // Two hues: both lead, the third sits in the widest gap, away from both.
    let greenBlue = Theme.from(palette: [0x2DB84D, 0x2F6BFF])
    let (g, b) = (OKLCH(hex: 0x2DB84D).h, OKLCH(hex: 0x2F6BFF).h)
    #expect(OKLCH.hueDistance(OKLCH(hex: greenBlue.light[0]).h, g) < 10)
    #expect(OKLCH.hueDistance(OKLCH(hex: greenBlue.light[1]).h, b) < 10)
    let third = OKLCH(hex: greenBlue.light[2]).h
    #expect(OKLCH.hueDistance(third, g) > 90 && OKLCH.hueDistance(third, b) > 90)
    // No hue (near-black, grey): a quiet slate theme.
    for gray: UInt32 in [0x1F1F23, 0x808080] {
        #expect(Theme.from(palette: [gray]).light.allSatisfy { OKLCH(hex: $0).c < 0.05 })
    }
    // The lime example with blue headphones reads both colours.
    var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue
    #expect(Theme.palette(for: tray) == [DotColor.lime.hex, DotColor.blue.hex])
}

// MARK: Round 7: the accent is the dot's main colour

@Test func accentIsTheDotsOwnMainColourWithALabelThatReads() {
    var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue
    let theme = Theme.forDesign(tray)
    #expect(theme.accent == DotColor.lime.hex, "Tray's accent is the lime of its body, not a darkened olive")
    #expect(Accent.label(on: DotColor.lime.hex) != 0xFFFFFF, "dark ink on lime")
    #expect(Accent.contrast(DotColor.lime.hex, Accent.label(on: DotColor.lime.hex)) >= 4.5)
    #expect(Accent.label(on: 0x1B2A6B) == 0xFFFFFF, "white on navy")
    #expect(Accent.label(on: DotColor.violet.hex) == 0xFFFFFF, "white on the default violet")
    #expect(Accent.label(on: 0xB3141B) == 0xFFFFFF, "white on deep red")
    #expect(Accent.label(on: DotColor.yellow.hex) != 0xFFFFFF)
    // Every dot colour fills the pill as itself.
    for color in DotColor.faceColors { #expect(Accent.pill(color.hex) == color.hex) }
    // Marks keep the hue: lime deepens on a light window only as far as 3:1.
    let mark = Accent.mark(DotColor.lime.hex, dark: false)
    #expect(OKLCH.hueDistance(OKLCH(hex: mark).h, OKLCH(hex: DotColor.lime.hex).h) < 8)
    #expect(Accent.contrast(mark, Accent.lightWindow) < 3.4, "only as deep as needed")
    #expect(Accent.mark(DotColor.lime.hex, dark: true) == DotColor.lime.hex, "lime already reads on a dark window")
}

@Test func backdropIsLedByTheMainColour() {
    var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue
    let theme = Theme.forDesign(tray)
    #expect(theme.wash == theme.light[0] && theme.weights[0] > theme.weights[1] && theme.weights[1] >= theme.weights[2])
    #expect(OKLCH.hueDistance(OKLCH(hex: theme.light[0]).h, OKLCH(hex: DotColor.lime.hex).h) < 8, "the lead stop is lime")
    #expect(OKLCH(hex: theme.light[0]).c > OKLCH(hex: theme.light[1]).c, "supporting stops are quieter")
    #expect(Theme.frost.wash == nil && Theme.frost.weights == [1, 1, 1], "Frost is unchanged")
}


// MARK: Voice tuning: truthful feedback, retry and Start over

@MainActor @Test func tuningNeverCountsADifferentNameAsTheWakePhrase() {
    let (f, _, _) = tuningFlow()
    f.startListening()
    let clip = Clip(repeating: 0.1, count: 16000)
    f.heard(Utterance(clip: clip, hearing: .otherName("HEY JOHN")))
    #expect(f.positives.isEmpty, "Hey John must not tick a slot")
    #expect(f.hint?.contains("Hey John") == true && f.hint?.contains("different name") == true)
    f.heard(Utterance(clip: clip, hearing: .missingStart("LUMINA ROPOLIS")))
    f.heard(Utterance(clip: clip, hearing: .nothing))
    #expect(f.positives.isEmpty)
    f.heard(Utterance(clip: clip, hearing: .phrase))
    #expect(f.positives.count == 1 && f.hint == "Heard it.")
    for _ in 0..<3 { f.heard(Utterance(clip: clip, hearing: .phrase)) }
    #expect(f.stage == .others && f.otherPrompts.first == "Hey John")
    // In the other-phrases stage the wake phrase itself is not stored as a negative.
    f.heard(Utterance(clip: clip, hearing: .phrase))
    #expect(f.negatives.isEmpty)
    f.heard(Utterance(clip: clip, hearing: .otherName("HEY JOHN")))
    #expect(f.negatives.count == 1)
}

@MainActor @Test func eachSampleCanBeRetriedAndStartOverClearsEverything() {
    let (f, tuner, _) = tuningFlow()
    f.startListening()
    let clip = Clip(repeating: 0.1, count: 16000)
    for i in 0..<4 { f.heard(Utterance(clip: clip.map { $0 * Float(i + 1) }, hearing: .phrase)) }
    f.heard(Utterance(clip: clip, hearing: .otherName("HEY JOHN")))
    f.retry(phrase: 1)
    #expect(f.positives.count == 3 && f.positives[1].first == 0.3 && f.stage == .phrase, "only that sample is cleared")
    #expect(f.negatives.count == 1, "other phrases are kept")
    f.calibration = Tuning(settings: WakeSettings(), caught: 4, falseHits: 0, note: "")
    f.retry(other: 0)
    #expect(f.negatives.isEmpty && f.calibration == nil, "a retry invalidates the old result")
    #expect(f.canStartOver)
    let starts = tuner.starts.count
    f.startOver()
    #expect(f.positives.isEmpty && f.negatives.isEmpty && f.calibration == nil && f.hint == nil)
    #expect(tuner.starts.count == starts + 1 && f.listening, "listening restarts from the first wake phrase")
    #expect(!f.canStartOver)
}

@MainActor @Test func theConfusablePromptNeverUsesTheUsersOwnName() {
    let (f, _, _) = tuningFlow()
    f.app.update { $0.rename("John") }
    #expect(f.otherPrompts == ["Hey Sam", "John", "Hey there"])
}

// MARK: Setup button row

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
        ("voice listening", QARender.flow(.voice, tweak: { $0.positives = [[0], [0]]; $0.listening = true; $0.tuningStarted = true })),
        ("voice hint", QARender.flow(.voice, tweak: { $0.positives = [[0]]; $0.listening = true; $0.tuningStarted = true
            $0.hint = "That sounded like \u{201C}Hey John\u{201D}, a different name. Say \u{201C}Hey Dot\u{201D}." })),
        ("voice no audio", QARender.flow(.voice, tweak: { $0.tuningStarted = true; $0.problem = .noAudio })),
        ("voice tuned", QARender.flow(.voice, tweak: { f in
            f.positives = [[0], [0], [0], [0]]; f.negatives = [[0], [0], [0]]
            let t = Tuning(settings: WakeSettings(), caught: 4, falseHits: 0, note: "Caught 4 of 4, no false hits.")
            f.calibration = t
            f.tuningSummary = OnboardingModel.summary(t, phrase: "Hey Dot", positives: 4, negatives: 3)
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
