import AppKit
import AVFoundation
import SwiftUI
import WakeEngine
import WebKit

/// Stand-ins for QA renders: no microphone, no login items, no files outside the output folder.
@MainActor
final class FakeEngine: WakeListening {
    var inputLevel: Float = -17
    var isListening = false
    var inputDeviceUID: String?
    func start(_ settings: WakeSettings, onWake: @escaping @MainActor (WakeEvent) -> Void) throws { isListening = true }
    func stop() { isListening = false }
}

@MainActor
final class FakeTuner: VoiceTuner {
    func start(phrase: String, inputUID: String?, onLevel: @escaping @MainActor (Float, Bool) -> Void,
               onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
    func stop() {}
}

struct FakeEnroller: WakeEnrolling {
    func record(seconds: Double) async throws -> Clip { Array(repeating: 0.2, count: 16000) }
    // QA fixtures set the tuning result directly; `Calibration` has no public initializer to fake.
    func calibrate(phrase: String, positives: [Clip], negatives: [Clip]) async throws -> Calibration {
        throw WakeEngineError.engine("QA fake does not calibrate")
    }
}

@MainActor
enum QARender {
    static func fakeHooks(mic: AVAuthorizationStatus = .authorized) -> SystemHooks {
        SystemHooks(setLaunchAtLogin: { _ in },
                    launchAtLoginEnabled: { true }, microphoneStatus: { mic }, requestMicrophone: { _ in },
                    openURL: { _ in })
    }

    static func model(_ change: (inout AppSettings) -> Void = { _ in }, mic: AVAuthorizationStatus = .authorized,
                      web: WebCalling? = nil, signedIn: Bool? = true) -> AppModel {
        var s = AppSettings()
        s.onboarded = true
        s.dotName = "Dot"
        s.wake = WakeSettings(phrase: "hey tray")
        s.dotURL = "https://chatgpt.com/dots/tray"
        s.design = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones)
        s.calibrationNote = "Caught 4 of 4, no false hits."
        change(&s)
        let m = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web, hooks: fakeHooks(mic: mic), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
        m.setFixture(result: nil, signedIn: signedIn)
        return m
    }

    /// Renders a SwiftUI view through a real (offscreen) AppKit window so native controls draw.
    static func snapshot<V: View>(_ view: V, to url: URL, dark: Bool = false, size fixed: CGSize? = nil,
                                  background: NSColor = .windowBackgroundColor) throws {
        let themed = view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.frostSnapshot, true).fontDesign(.rounded)
        let root: AnyView = fixed.map { AnyView(themed.frame(width: $0.width, height: $0.height)) } ?? AnyView(themed.fixedSize())
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        let window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : background
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    /// The popover as it sits on the desktop: rounded, on the sample wallpaper.
    static func popover(_ m: AppModel, customPause: Bool = false) -> some View {
        PopoverView(model: m, openDotMaker: {}, openSettings: {}, openOnboarding: {}, quit: {}, customPause: customPause)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 0.75))
            .padding(24)
            .background(SampleWallpaper())
    }

    static func run(into dir: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try DotBoards.renderAll(into: dir)
            func out(_ name: String) -> URL { dir.appendingPathComponent(name + ".png") }

            // Every screen in light and dark.
            func both<V: View>(_ name: String, size: CGSize? = nil, _ make: () -> V) throws {
                try snapshot(make(), to: out(name), size: size)
                try snapshot(make(), to: out(name + "-dark"), dark: true, size: size)
            }

            // Real measurement once, so the fixture below isn't the only evidence the sampler works.
            ListenerUsage.shared.fixture = (ListenerUsage.Sample(cpu: 0.4, megabytes: 39),
                                           [0.3, 0.5, 0.4, 0.4, 0.6, 0.3, 0.4, 0.5, 0.4, 0.3, 0.4, 0.4, 0.7, 0.4, 0.3, 0.4, 0.4, 0.5, 0.4, 0.4])

            // Popover states
            try both("popover-listening") { popover(model()) }
            try both("popover-star") { popover(model { $0.callsStarted = 3 }) }
            try snapshot(popover(model { $0.paused = true }), to: out("popover-paused"))
            let until = Calendar.current.date(bySettingHour: 21, minute: 41, second: 0, of: Date()) ?? Date()
            try both("popover-paused-timed") { popover(model { $0.paused = true; $0.pausedUntil = until }) }
            try both("popover-paused-1h") { popover(model { $0.paused = true; $0.pausedUntil = Date().addingTimeInterval(3600 + 20 * 60) }) }
            try both("popover-pause-custom") { popover(model(), customPause: true) }
            try both("popover-call-started") {
                let m = model(); m.setFixture(result: CallResult(outcome: "pressed"), signedIn: true); return popover(m)
            }
            try both("popover-check-ready") {
                let m = model(); m.setFixture(result: CallResult(outcome: "would-press"), signedIn: true); return popover(m)
            }
            let muted = NoWeb(); muted.inCall = true; muted.microphoneMuted = true
            try both("popover-in-call-muted") { popover(model(web: muted)) }
            try snapshot(popover(model({ $0 = AppSettings() })), to: out("popover-setup-needed"))
            try snapshot(popover(model(signedIn: false)), to: out("popover-sign-in-needed"))
            let inCall = NoWeb(); inCall.inCall = true; inCall.microphoneMuted = false
            try both("popover-in-call") { popover(model(web: inCall)) }
            try both("popover-call-failed") {
                let failed = model(); failed.setFixture(result: CallResult(outcome: "not-found", message: WebCallBackend.describe("not-found")), signedIn: true); return popover(failed)
            }

            // Not working?: running, stopped at each kind of problem, and all clear.
            func doctor(_ name: String, running: Bool = false, _ states: [Troubleshooter.Step: Troubleshooter.State]) throws {
                try both(name) {
                    let m = model(), d = Troubleshooter(app: m)
                    d.setFixture(states, running: running)
                    return TroubleshootView(doctor: d, model: m, retune: {}, signIn: {}, close: {})
                }
            }
            let mic = "the built-in microphone"
            try doctor("troubleshoot-hearing", running: true, [.microphoneAccess: .ok("HeyDot can use the microphone."),
                .listening: .ok("Listening on \(mic)."), .hearing: .running])
            try doctor("troubleshoot-silent", [.microphoneAccess: .ok("HeyDot can use the microphone."),
                .listening: .ok("Listening on \(mic)."), .hearing: .problem(.silent, "No sound at all is coming from \(mic).")])
            try doctor("troubleshoot-mic-denied", [.microphoneAccess: .problem(.micDenied, "Microphone access for HeyDot is off in System Settings.")])
            try doctor("troubleshoot-call-button", [.microphoneAccess: .ok("HeyDot can use the microphone."),
                .listening: .ok("Listening on \(mic)."), .hearing: .ok("Sound is reaching HeyDot from \(mic)."),
                .phrase: .ok("Heard \u{201C}Hey Tray\u{201D}."), .signIn: .ok("Signed in to ChatGPT."),
                .callButton: .problem(.callButton, WebCallBackend.describe("not-found"))])
            try doctor("troubleshoot-done", Dictionary(uniqueKeysWithValues: Troubleshooter.Step.allCases.map { ($0, .ok("Fine.")) }))

            // Onboarding: every step and the tuning screen's states.
            func flow(_ step: OnboardingStep, mic: AVAuthorizationStatus = .authorized, signedIn: Bool? = true,
                      settings change: (inout AppSettings) -> Void = { _ in }, tweak: (OnboardingModel) -> Void = { _ in }) -> OnboardingView {
                let m = model({ s in
                    s.onboarded = false; s.dotName = "Dot"; s.wake = WakeSettings(); s.design = .default; s.dotURL = nil
                    s.calibrationNote = nil; change(&s)
                }, mic: mic, signedIn: signedIn)
                let f = OnboardingModel(app: m, tuner: FakeTuner())
                f.step = step
                // Back history as if the guided path led here.
                f.trail = Array([OnboardingStep.welcome, .name, .voice, .connect].prefix { $0 != step })
                f.micStatus = mic
                f.devices = [AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn),
                             AudioInput(id: 2, uid: "AA-BB:input", name: "AirPods Pro", transport: .bluetooth)]
                tweak(f)
                return OnboardingView(flow: f)
            }
            let speech: [Float] = (0..<72).map { i in
                let t = Float(i)
                return i < 18 ? -58 : (i % 23 < 13 ? -28 + 14 * sin(t * 0.9) * sin(t * 0.21) : -55)
            }
            try both("onboarding-1-welcome") { flow(.welcome) }
            try both("onboarding-3-name") { flow(.name) }
            try both("onboarding-3b-name-wake-word") { flow(.name, tweak: { f in f.nameDraft = "Tray"; f.editPhrase(); f.phraseDraft = "Okay Tray" }) }
            try both("onboarding-3c-name-wake-word-reserved") { flow(.name, tweak: { f in f.nameDraft = "Tray"; f.editPhrase(); f.phraseDraft = "Hey Siri" }) }
            try both("onboarding-4a-voice-permission") { flow(.voice, mic: .notDetermined) }
            try both("onboarding-4b-voice-listening") { flow(.voice, tweak: { f in
                f.positives = [[0], [0]]; f.listening = true; f.tuningStarted = true; f.levels.set(speech)
            }) }
            try both("onboarding-4h-voice-different-name") { flow(.voice, tweak: { f in
                f.positives = [[0]]; f.listening = true; f.tuningStarted = true; f.levels.set(speech)
                f.hint = "That sounded like \u{201C}Hey John\u{201D}, a different name. Say \u{201C}\(f.phraseTitle)\u{201D}."
            }) }
            try both("onboarding-4c-voice-no-audio") { flow(.voice, tweak: { f in f.tuningStarted = true; f.problem = .noAudio }) }
            try both("onboarding-4f-voice-start") { flow(.voice) }
            try both("onboarding-4g-voice-permission-denied") { flow(.voice, mic: .denied) }
            try both("onboarding-3d-name-design-later") { flow(.name, tweak: { $0.designDeferred = true }) }
            try both("onboarding-6c-done-design-later", { flow(.done, settings: { $0.dotURL = "https://chatgpt.com/dots/sol" }, tweak: { $0.designDeferred = true }) })
            try both("onboarding-4d-voice-something-else") { flow(.voice, tweak: { f in
                f.positives = [[0], [0], [0], [0]]; f.negatives = [[0]]
                f.listening = true; f.tuningStarted = true; f.levels.set(speech)
            }) }
            try both("onboarding-4e-voice-tuned") { flow(.voice, settings: { $0.calibrationNote = "Caught 4 of 4, no false hits." }, tweak: { f in
                f.positives = [[0], [0], [0], [0]]; f.negatives = [[0], [0], [0]]
                let t = Tuning(settings: WakeSettings(), caught: 4, falseHits: 0, note: "Caught 4 of 4, no false hits.")
                f.calibration = t
                f.tuningSummary = OnboardingModel.summary(t, phrase: "Hey Dot", positives: 4, negatives: 3)
            }) }
            try both("onboarding-5a-connect-builtin") { flow(.connect, signedIn: false, tweak: { $0.webSignedIn = false }) }
            try both("onboarding-5b-connect-builtin-signed-in") { flow(.connect, tweak: { f in
                f.webSignedIn = true
                f.webDots = [DotTab(url: "https://chatgpt.com/dots/sol", title: "Sol"), DotTab(url: "https://chatgpt.com/dots/tray", title: "Tray")]
                f.urlDraft = "https://chatgpt.com/dots/sol"
                f.checkResult = CallResult(outcome: "would-press")
            }) }
            try both("onboarding-6a-done", { flow(.done, settings: { $0.dotURL = "https://chatgpt.com/dots/sol"; $0.calibrationNote = "Caught 4 of 4" }) })
            try both("onboarding-6b-done-heard", { flow(.done, settings: { $0.dotURL = "https://chatgpt.com/dots/sol"; $0.calibrationNote = "Caught 4 of 4" }, tweak: { $0.heard = true }) })

            // Dot maker and settings
            let maker = CGSize(width: 900, height: 680)
            try both("dotmaker-default", size: maker) { DotMakerView(draft: .default, onSave: { _, _ in }, onCancel: {}) }
            try both("dotmaker-custom", size: maker) { DotMakerView(draft: .default, showCustom: true, onSave: { _, _ in }, onCancel: {}) }
            // A real import of a sample avatar (validated and normalised like a user's), into a throwaway folder.
            let avatars = FileManager.default.temporaryDirectory.appendingPathComponent("heydot-qa-avatars-\(UUID().uuidString)")
            Avatars.directory = avatars
            defer { try? FileManager.default.removeItem(at: avatars) }
            let sample = avatars.appendingPathComponent("sample.svg")
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try Self.sampleAvatar.write(to: sample, atomically: true, encoding: .utf8)
            let imported = try Avatars.importFile(sample)
            let avatar = DotDesign(nickname: "Pip", custom: imported.art)
            try both("dotmaker-imported-avatar", size: maker) {
                DotMakerView(draft: avatar, menuBarIcon: .color, showCustom: true, onSave: { _, _ in }, onCancel: {})
            }
            try both("popover-imported-avatar") { popover(model { $0.design = avatar; $0.menuBarIcon = .color }) }
            try DotBoards.write(GlyphStrip(extra: [avatar]), to: out("menubar-glyphs-with-avatar"), scale: 2)
            try snapshot(DotMakerView(draft: DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, nickname: "Tray"),
                                      onSave: { _, _ in }, onCancel: {}), to: out("dotmaker-triangle-headphones"), size: CGSize(width: 900, height: 680))
            try snapshot(DotMakerView(draft: DotDesign(shape: .circleTwoEars, color: .pink, eyes: .roundHighlights, glasses: .roundSunglasses,
                                                       accessory: .beret, accessoryColor: .brown, nickname: "Mochi"),
                                      onSave: { _, _ in }, onCancel: {}), to: out("dotmaker-mochi-dark"), dark: true, size: CGSize(width: 900, height: 680))
            try both("settings") { SettingsView(model: model { $0.menuBarIcon = .color }, retune: {}, rerunSetup: {}, openDotMaker: {}) }
            // The smallest Settings window: the form must scroll to reach the sections below the fold.
            try both("settings-smallest", size: CGSize(width: 560, height: SettingsView.minimumHeight)) {
                SettingsView(model: model(), retune: {}, rerunSetup: {}, openDotMaker: {})
            }

            // The dot-derived accent for three very different dot colours: the lime example (lime), a pale yellow
            // and a near-black, each with its contrast numbers, plus the popover and the tuning step in each.
            try both("accent-board") { AccentBoard() }
            for (name, design) in AccentBoard.samples {
                try both("accent-\(name)-popover") { popover(model { $0.design = design; $0.dotName = "Dot" }) }
                try both("accent-\(name)-voice") { flow(.voice, settings: { $0.design = design }, tweak: { f in
                    f.positives = [[0], [0]]; f.listening = true; f.tuningStarted = true; f.levels.set(speech)
                }) }
            }
            // The sign-in window's header (the page itself is chatgpt.com, rendered by --qa-signin).
            let signInSize = CGSize(width: 980, height: 560)
            try both("signin-window", size: signInSize) { SignInView(web: nil, state: SignInState(), done: {}) }
            try both("signin-window-trouble", size: signInSize) {
                let state = SignInState(); state.trouble = true
                return SignInView(web: nil, state: state, done: {})
            }
            // Theme from dot: six dots, each themed through welcome, the naming step and the popover, and a board.
            for (name, design, override) in ThemeBoard.samples {
                Theme.renderOverride = override
                defer { Theme.renderOverride = nil }
                try both("theme-\(name)-welcome") { flow(.welcome, settings: { $0.design = design }) }
                try both("theme-\(name)-name") { flow(.name, settings: { $0.design = design }) }
                try both("theme-\(name)-popover") { popover(model { $0.design = design }) }
            }
            try both("theme-board") { ThemeBoard() }
            try both("settings-monochrome") { SettingsView(model: model(), retune: {}, rerunSetup: {}, openDotMaker: {}) }
            try both("settings-custom-wake-paused") {
                SettingsView(model: model { $0.setWakePhrase("okay tray"); $0.paused = true; $0.pausedUntil = Date().addingTimeInterval(2 * 3600 + 5 * 60)
                    $0.morningMinutes = 7 * 60 + 30 }, retune: {}, rerunSetup: {}, openDotMaker: {})
            }

            // Menu bar glyphs at 18 pt (2x): monochrome and colour, on light and dark bars
            try DotBoards.write(GlyphStrip(), to: out("menubar-glyphs"), scale: 2)
            // The default (Mic) logo as tiles, light and dark.
            try both("logo-mic") { LogoSheet() }
            return 0
        } catch {
            FileHandle.standardError.write(Data("qa-render failed: \(error)\n".utf8))
            return 1
        }
    }

    /// Focused logo evidence via `--qa-render DIR --logo-only`, without unrelated QA boards.
    static func renderLogo(into dir: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                let m = model { $0 = AppSettings() }
                let flow = OnboardingModel(app: m, tuner: FakeTuner())
                try snapshot(OnboardingView(flow: flow), to: dir.appendingPathComponent("welcome-\(mode).png"), dark: dark)
                try snapshot(popover(model { $0.design = .default }), to: dir.appendingPathComponent("popover-\(mode).png"), dark: dark)
                for pixels in [16, 18, 32] {
                    let glyph = DotGlyph.image(.default, state: .listening, points: CGFloat(pixels))
                    try DotBoards.write(Image(nsImage: glyph).resizable().renderingMode(.template)
                        .foregroundStyle(dark ? Color.white : Color.black)
                        .frame(width: CGFloat(pixels), height: CGFloat(pixels))
                        .background(dark ? Color(hex: 0x1E1E1E) : Color(hex: 0xECECEC)),
                        to: dir.appendingPathComponent("glyph-\(pixels)-\(mode).png"), scale: 1)
                }
            }
            try DotBoards.write(DotView(.default).frame(width: 128, height: 128).padding(12)
                .background(Color(hex: 0xF2F2F5)), to: dir.appendingPathComponent("dot-flat.png"), scale: 2)
            return renderIcon(into: dir)
        } catch {
            FileHandle.standardError.write(Data("qa-logo failed: \(error)\n".utf8))
            return 1
        }
    }

    /// Designer master plus a macOS iconset (16 to 1024), including hinted small reps.
    static func renderIcon(into dir: URL) -> Int32 {
        _ = NSApplication.shared
        do {
            let set = dir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            try LogoAsset.png(pixels: 1024).write(to: dir.appendingPathComponent("AppIcon-1024.png"))
            for points in [16, 32, 128, 256, 512] {
                for s in [1, 2] {
                    let name = s == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                    try LogoAsset.png(pixels: points * s).write(to: set.appendingPathComponent(name))
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("render-icon failed: \(error)\n".utf8))
            return 1
        }
    }
}

extension QARender {
    /// The sign-in window over the live, logged-out chatgpt.com, in a throwaway non-persistent store.
    /// WebKit draws out of process, so the page is captured with `takeSnapshot` and composited under the header.
    static func renderSignIn(into dir: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let size = NSSize(width: 980, height: 760)
            let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: {
                let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); return c
            }())
            web.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
            let deadline = Date().addingTimeInterval(20)
            while (web.isLoading || web.url == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            RunLoop.main.run(until: Date().addingTimeInterval(4))  // let the page render after load
            for dark in [false, true] {
                let host = NSHostingView(rootView: SignInView(web: nil, state: SignInState(), done: {}).frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless],
                                       backing: .buffered, defer: false)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
                host.cacheDisplay(in: host.bounds, to: rep)
                window.orderOut(nil)
                // The header's height: everything above the web area (the Divider sits at its bottom).
                let header = host.subviews.isEmpty ? 70 : headerHeight(rep)
                web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                var page: NSImage?
                var done = false
                let config = WKSnapshotConfiguration()
                config.rect = NSRect(x: 0, y: 0, width: size.width, height: size.height - header)
                web.setFrameSize(NSSize(width: size.width, height: size.height - header))
                web.takeSnapshot(with: config) { image, _ in page = image; done = true }
                while !done && Date() < deadline.addingTimeInterval(10) { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                let composite = NSImage(size: size)
                composite.lockFocus()
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(origin: .zero, size: size).fill()
                NSImage(cgImage: rep.cgImage!, size: size).draw(in: NSRect(origin: .zero, size: size))
                page?.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height - header))
                composite.unlockFocus()
                guard let tiff = composite.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: dir.appendingPathComponent(dark ? "signin-window-dark.png" : "signin-window.png"))
            }
            print("qa-signin: page \(web.url?.absoluteString ?? "none"), title \(web.title ?? "")")
            return 0
        } catch {
            FileHandle.standardError.write(Data("qa-signin failed: \(error)\n".utf8))
            return 1
        }
    }

    /// Finds the header's divider: the first row from the top, below 40 px, that differs from the row above it
    /// across the whole width (the web area of the header-only render is a flat fill).
    private static func headerHeight(_ rep: NSBitmapImageRep) -> CGFloat {
        let scale = CGFloat(rep.pixelsHigh) / rep.size.height
        var last: NSColor?
        var y = Int(40 * scale)
        while y < rep.pixelsHigh {
            let c = rep.colorAt(x: rep.pixelsWide - 2, y: y)
            if let last, let c, abs(last.brightnessComponent - c.brightnessComponent) > 0.03 { return CGFloat(y) / scale + 1 }
            last = c; y += 1
        }
        return 70
    }
}

/// The default logo as the user sees it: app-style tiles at 128, 64 and 32 pt plus the popover avatar size.
struct LogoSheet: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ForEach([128.0, 64, 52, 32], id: \.self) { size in
                VStack(spacing: 6) {
                    DotTile(.default, size: size)
                    Text("\(Int(size)) pt").font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                DotTile(.default, size: 64, dark: true)
                Text("dark tile").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

/// Accent swatches with the contrast each one reaches.
struct AccentBoard: View {
    static let samples: [(String, DotDesign)] = [
        ("tray", DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody)), ("pale", DotDesign(color: .yellow)), ("near-black", DotDesign(color: .charcoal)), ("default", .default),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.samples, id: \.0) { name, design in
                let raw = Accent.source(for: design), ui = Accent.hex(for: design)
                HStack(spacing: 14) {
                    Text(name).font(.headline).frame(width: 90, alignment: .leading)
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: raw)).frame(width: 44, height: 30)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: ui)).frame(width: 44, height: 30)
                    Text(String(format: "#%06X  white text %.1f:1  dark window %.1f:1  light window %.1f:1", ui,
                                Accent.contrast(ui, 0xFFFFFF), Accent.contrast(ui, Accent.darkWindow), Accent.contrast(ui, Accent.lightWindow)))
                        .font(.system(size: 12, design: .monospaced))
                    Button("Continue") {}.frostButton(.primary)
                    TileRings(size: 14, level: -20).frame(width: 30, height: 30)
                }
                .frostAccent(design)
            }
        }
        .padding(20)
        .background(FrostBackdrop())
    }
}

/// The six reference dots and their themes side by side: the backdrop each one gets, its stops and its accent.
struct ThemeBoard: View {
    /// (name, the dot, a palette override for colours no dot option expresses: a true red and a pale pastel).
    static let samples: [(String, DotDesign, Theme?)] = {
        var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue  // the lime example: lime with blue headphones
        return [
            ("default", .default, nil),
            ("tray", tray, nil),
            ("green-blue", DotDesign(color: .teal, accessory: .headphones, accessoryColor: .blue), Theme.from(palette: [0x2DB84D, 0x2F6BFF])),
            ("red", DotDesign(color: .coral), Theme.from(palette: [0xE0353B])),
            ("pale", DotDesign(color: .pink), Theme.from(palette: [0xF6D6E8])),
            ("near-black", DotDesign(color: .charcoal), nil),
        ]
    }()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Self.samples, id: \.0) { name, design, override in
                let theme = override ?? Theme.forDesign(design)
                VStack(spacing: 10) {
                    ZStack {
                        FrostBackdrop()
                        VStack(spacing: 14) {
                            DotTile(design, size: 64, dark: true)
                            Button("Continue") {}.frostButton(.primary)
                            HStack(spacing: 5) {
                                Capsule().fill(Color(hex: Accent.mark(theme.accent, dark: scheme == .dark))).frame(width: 18, height: 6)
                                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.primary.opacity(0.18)).frame(width: 6, height: 6) }
                            }
                        }
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Frost.Radius.card, style: .continuous))
                    Text(name).font(.headline)
                    HStack(spacing: 4) {
                        ForEach(theme.stops(dark: scheme == .dark), id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 4).fill(Color(hex: hex)).frame(width: 30, height: 18)
                        }
                        Circle().fill(Color(hex: theme.accent)).frame(width: 18, height: 18).padding(.leading, 4)
                    }
                    Text(String(format: "accent #%06X  label %.1f:1", theme.accent, Accent.contrast(theme.accent, Accent.label(on: theme.accent))))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frostTheme(theme)
            }
        }
        .padding(20)
        .background(SampleWallpaper())
    }
}

struct GlyphStrip: View {
    static let designs: [DotDesign] = [.default, DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones),
                                       DotDesign(shape: .heart, color: .pink, fill: .colorBody), DotDesign(shape: .hexagon, color: .coral, accessory: .crown)]
    var extra: [DotDesign] = []
    var designs: [DotDesign] { Self.designs + extra }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([false, true], id: \.self) { color in
                Text(color ? "Menu bar icon: Color" : "Menu bar icon: Monochrome (default)").font(.system(size: 11, weight: .semibold))
                ForEach([(false, Color(hex: 0xECECEC)), (true, Color(hex: 0x1E1E1E))], id: \.0) { dark, bg in
                    HStack(spacing: 18) {
                        ForEach(designs, id: \.self) { design in
                            ForEach([GlyphState.listening, .paused, .attention, .ok], id: \.self) { state in
                                let image = DotGlyph.image(design, state: state, color: color, darkBar: dark)
                                if color { Image(nsImage: image) }
                                else { Image(nsImage: image).renderingMode(.template).foregroundStyle(dark ? Color.white : Color.black) }
                            }
                            Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 24).background(bg)
                }
            }
        }
        .padding(10)
        .background(Color.white)
    }
}

extension QARender {
    /// A sample avatar written to the agent prompt's contract: ink body with eye holes, accent eyes in
    /// `<g id="eyes">`, a coral bow separated by a gutter.
    static let sampleAvatar = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
      <title>Pip</title>
      <path fill="#0A0A0B" fill-rule="evenodd" d="M48 24c17 0 28 11 28 28s-11 28-28 28s-28-11-28-28s11-28 28-28Z M34.75 49a5.25 5.25 0 0 1 10.5 0v8a5.25 5.25 0 0 1 -10.5 0Z M50.75 49a5.25 5.25 0 0 1 10.5 0v8a5.25 5.25 0 0 1 -10.5 0Z"/>
      <path fill="#0A0A0B" d="M24 10l14 16l-16 8Z M72 10l-14 16l16 8Z"/>
      <g id="eyes"><rect x="34.75" y="43.75" width="10.5" height="18.5" rx="5.25" fill="#FF5FA2"/><rect x="50.75" y="43.75" width="10.5" height="18.5" rx="5.25" fill="#FF5FA2"/></g>
      <path fill="#FF7A1A" d="M35 83l12 5l-12 5Z M61 83l-12 5l12 5Z"/>
    </svg>
    """
}

/// Borderless windows normally can't be key; QA needs key status so prominent buttons draw as they do live.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
