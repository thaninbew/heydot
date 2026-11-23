import AVFoundation
import Foundation
import Testing
import WebKit
@testable import WakeEngine
@testable import HeyDotKit

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heydot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: Settings migration and reset

@MainActor @Test func legacySettingsKeepLoadingAndFollowTheCurrentDefaults() async throws {
    #expect(DotDesign.default.signature == .mic)
    let old = #"{"backend":"chrome","onboarded":true,"dotURL":"https://chatgpt.com/dots/sol","design":{"shape":"circle","color":"violet","eyes":"oval","glasses":"none","accessory":"none","accessoryColor":"charcoal","nickname":"","fill":"inkBody","signature":"hey"}}"#
    let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    #expect(s.design == .default)
    let previousMic = old.replacingOccurrences(of: "\"signature\":\"hey\"", with: "\"signature\":\"mic\"")
    #expect(try JSONDecoder().decode(AppSettings.self, from: Data(previousMic.utf8)).design == .default)
    #expect(s.onboarded && s.dotURL == "https://chatgpt.com/dots/sol")
    let web = FakeWeb()
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: QARender.fakeHooks(), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    await model.call()
    #expect(web.calls == ["https://chatgpt.com/dots/sol"])
    #expect(model.lastResult?.pressed == true)
}

@Test func resetOnboardingMovesSettingsAsideAndKeepsThem() throws {
    let home = try tempDir()
    let paths = Paths(home: home)
    var settings = AppSettings(); settings.onboarded = true
    try SettingsStore(url: paths.settings).save(settings)
    #expect(HeyDotMain.resetOnboarding(paths: paths, running: { _ in true }) == 1)  // refuses while the app runs
    #expect(FileManager.default.fileExists(atPath: paths.settings.path))
    #expect(HeyDotMain.resetOnboarding(paths: paths, running: { _ in false }) == 0)
    #expect(!FileManager.default.fileExists(atPath: paths.settings.path))
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("settings.json.reset-") }
    #expect(backups.count == 1)
    let kept = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: paths.support.appendingPathComponent(backups[0])))
    #expect(kept.onboarded)
    #expect(try SettingsStore(url: paths.settings).load().onboarded == false)  // next launch starts setup
    #expect(HeyDotMain.resetOnboarding(paths: paths, running: { _ in false }) == 0)  // nothing left to move
}

// MARK: Listener usage

@MainActor @Test func listenerUsageIsListenerCPUPerWallSecond() {
    let usage = ListenerUsage()
    var cpu = 10.0, wall = 100.0
    usage.cpuSeconds = { cpu }; usage.uptime = { wall }; usage.bytes = { 18 * 1_048_576 }
    usage.sample()
    cpu = 10.008; wall = 102
    usage.sample()
    #expect(abs((usage.latest?.cpu ?? 0) - 0.4) < 0.0001)
    #expect(usage.latest?.megabytes == 18)
    #expect(ListenerUsage.describe(usage.latest!) == "Listener: 0.4% CPU \u{00B7} ~18 MB")
}

@Test func listenerMeterCountsOnlyMeasuredWork() {
    let before = ListenerMeter.cpuSeconds
    var x = 0.0
    for i in 0..<2_000_000 { x += sqrt(Double(i)) }  // outside the meter
    #expect(ListenerMeter.cpuSeconds == before)
    #expect(x > 0)
}

// MARK: Built-in browser

@Test func microphoneIsGrantedOnlyToChatGPTDuringACall() {
    func allow(_ scheme: String = "https", host: String = "chatgpt.com", port: Int = 0, frame: String = "chatgpt.com",
               type: WKMediaCaptureType = .microphone, call: Bool = true, active: Bool = true) -> Bool {
        WebCallBackend.allowsMicrophone(origin: (scheme, host, port), frameHost: frame, type: type, callView: call, active: active)
    }
    #expect(allow())
    #expect(!allow(active: false))                 // not placing or in a call
    #expect(!allow(call: false))                   // the sign-in window never gets the mic
    #expect(!allow(type: .camera))
    #expect(!allow(type: .cameraAndMicrophone))
    #expect(!allow("http"))
    #expect(!allow(host: "evil.example"))
    #expect(!allow(host: "chatgpt.com.evil.example"))
    #expect(!allow(port: 8443))
    #expect(!allow(frame: "ads.example"))          // an embedded third-party frame
}

@MainActor final class FakeWeb: WebCalling {
    var inCall = false
    var onCallChange: ((String?) -> Void)?
    var calls: [String] = []
    var outcome = "pressed"
    func call(dotURL: String, wakeAt: Date) async -> CallResult { calls.append(dotURL); return CallResult(outcome: outcome) }
    func check(dotURL: String) async -> CallResult { CallResult(outcome: "would-press") }
    func endCall() { inCall = false; onCallChange?(nil) }
    func warm(dotURL: String?) {}
    func pageState() async -> WebPageState { WebPageState(signedIn: true) }
    func showSignIn(onClose: @escaping () -> Void) {}
    func signOut() async {}
}

@MainActor @Test func wakeUsesTheBuiltInBrowserAndIgnoresWakesDuringACall() async {
    let web = FakeWeb()
    var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: QARender.fakeHooks(), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    await model.call()
    #expect(web.calls == ["https://chatgpt.com/dots/sol"])
    #expect(model.lastResult?.pressed == true)
    web.inCall = true
    #expect(model.status == .calling)
    model.handleWake(WakeEvent(phrase: "hey dot", at: Date()))
    await Task.yield()
    #expect(web.calls.count == 1)
    web.outcome = "signed-out"; web.inCall = false
    await model.call()
    #expect(model.status == .signInNeeded)
    model.handleWake(WakeEvent(phrase: "hey dot", at: Date()))
    for _ in 0..<20 { await Task.yield() }
    let callsAfterWake = web.calls.count
    #expect(callsAfterWake == 3)
    for _ in 0..<8 { model.handleWake(WakeEvent(phrase: "hey dot", at: Date())) }
    for _ in 0..<20 { await Task.yield() }
    #expect(web.calls.count == callsAfterWake)  // cooldown still applies after a fast failure
}

// MARK: The page script's fail-closed rules (run in Node with a fake DOM)

@Test func builtInPressScriptFailsClosed() throws {
    let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", NSHomeDirectory() + "/.local/bin/node"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let node else { print("skipped: node not found"); return }
    let dir = try tempDir()
    let harness = """
    const press = async (dotPath, label, click) => { \(PageScripts.press) };
    const cases = [];
    function page({ host = "chatgpt.com", path = "/dots/sol", buttons = [["Start call"]], links = [], title = "ChatGPT", text = "hello", visible = true }) {
      const made = buttons.map(([label, disabled = false, attrs = {}]) => ({ clicked: 0, disabled, textContent: "",
        getAttribute: (k) => (k === "aria-label" ? label : (attrs[k] ?? null)), click() { this.clicked++; } }));
      globalThis.__heyDotProfileOpenedAt = 0;
      globalThis.location = { host, pathname: path, href: "https://" + host + path };
      globalThis.document = { title, body: { innerText: text }, visibilityState: visible ? "visible" : "hidden",
        querySelector: () => null,
        querySelectorAll: (sel) => sel === "button" ? made
          : [...made, ...links.map((label) => ({ textContent: label, getAttribute: () => null }))] };
      return made;
    }
    const run = async (name, spec, click, want, wantClicks = want === "pressed" ? 1 : 0) => {
      const made = page(spec);
      const got = (await press("/dots/sol", "Start call", click)).outcome;
      const clicks = made.reduce((n, b) => n + b.clicked, 0);
      cases.push({ name, got, want, clicks, wantClicks });
    };
    await run("presses", {}, true, "pressed");
    await run("check only", {}, false, "would-press");
    await run("trailing slash", { path: "/dots/sol/" }, true, "pressed");
    await run("hidden page waits", { visible: false }, true, "not-visible");
    await run("other dot", { path: "/dots/tray" }, true, "wrong-dot");
    await run("other host", { host: "example.com" }, true, "wrong-dot");
    await run("login host", { host: "auth.openai.com" }, true, "signed-out");
    await run("login page", { path: "/auth/login" }, true, "signed-out");
    await run("login buttons", { buttons: [["Log in"], ["Start call"]] }, true, "signed-out");
    await run("login link", { buttons: [], links: ["Log in"] }, true, "signed-out");
    await run("two buttons", { buttons: [["Start call"], ["Start call"]] }, true, "ambiguous");
    await run("disabled", { buttons: [["Start call", true]] }, true, "disabled");
    await run("near label", { buttons: [["Start call now"]] }, true, "not-found");
    await run("cloudflare title", { title: "Just a moment..." }, true, "challenge");
    await run("cloudflare text", { text: "Verify you are human" }, true, "challenge");
    await run("opens the profile", { buttons: [["Open sol’s profile"]] }, true, "not-found", 1);
    await run("profile already open", { buttons: [["Open sol’s profile", false, { "aria-expanded": "true" }]] }, true, "not-found", 0);
    await run("two profiles", { buttons: [["Open sol’s profile"], ["Open sol's profile"]] }, true, "not-found", 0);
    await run("call toggle on", { buttons: [["Start call", false, { "aria-pressed": "true" }]] }, true, "disabled");
    console.log(JSON.stringify(cases));
    """
    let file = dir.appendingPathComponent("harness.mjs")
    try harness.write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [file.path]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let cases = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [[String: Any]] ?? []
    #expect(cases.count == 19)
    for c in cases {
        let name = c["name"] as? String ?? "?", got = c["got"] as? String, want = c["want"] as? String
        #expect(got == want, "\(name): \(got ?? "nil") != \(want ?? "nil")")
        #expect((c["clicks"] as? Int ?? -1) == (c["wantClicks"] as? Int ?? -2), "\(name) clicked wrongly")
    }
    try? FileManager.default.removeItem(at: dir)
}

/// A press that never returns (a hung page) must not wedge HeyDot: Reload frees it and the next call works.
@MainActor private final class HungWeb: WebCalling {
    var inCall = false
    var onCallChange: ((String?) -> Void)?
    var hang = true
    var resets = 0
    var calls = 0
    var signedIn: Bool? = true
    var checkOutcome = "would-press"
    private var pending: CheckedContinuation<CallResult, Never>?
    func call(dotURL: String, wakeAt: Date) async -> CallResult {
        calls += 1
        guard hang else { return CallResult(outcome: "pressed") }
        return await withCheckedContinuation { pending = $0 }
    }
    func release() { pending?.resume(returning: CallResult(outcome: "not-found")); pending = nil }
    func check(dotURL: String) async -> CallResult { CallResult(outcome: checkOutcome) }
    func endCall() {}
    func warm(dotURL: String?) {}
    func pageState() async -> WebPageState { WebPageState(signedIn: signedIn) }
    func showSignIn(onClose: @escaping () -> Void) {}
    func signOut() async {}
    func reset() { resets += 1 }
}

@MainActor @Test func reloadFreesAHungCallAndAFailedCallRechecksSignIn() async {
    let web = HungWeb()
    var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: QARender.fakeHooks(), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    let hung = Task { await model.call() }
    while web.calls == 0 { await Task.yield() }
    #expect(model.calling && !model.canCallNow)
    model.reloadWeb()
    #expect(web.resets == 1 && !model.calling && model.canCallNow)
    web.hang = false
    await model.call()
    #expect(model.lastResult?.pressed == true)
    web.release(); await hung.value
    #expect(model.lastResult?.pressed == true)       // the stale press can't overwrite the newer result
    // A "not found" that is really a lapsed sign-in ends on Sign in, not on a dead Call button.
    web.hang = true; web.signedIn = false
    let failing = Task { await model.call() }
    while web.calls < 3 { await Task.yield() }
    web.release(); await failing.value
    for _ in 0..<20 { await Task.yield() }
    #expect(model.status == .signInNeeded)
}

/// "Not working?" walks the call path in order and stops at the first failure; it never places a call, and it
/// hands wakes and listening back when it ends.
@MainActor @Test func troubleshooterStopsAtTheFirstBrokenStepAndNeverCalls() async {
    func run(mic: AVAuthorizationStatus = .authorized, level: Float, wake: Bool, outcome: String = "would-press",
             signedIn: Bool? = true) async -> (Troubleshooter, HungWeb, FakeEngine, AppModel) {
        let web = HungWeb(); web.hang = false; web.signedIn = signedIn; web.checkOutcome = outcome
        let engine = FakeEngine(); engine.inputLevel = level
        var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
        let model = AppModel(settings: s, engine: engine, enroller: FakeEnroller(), web: web,
                             hooks: QARender.fakeHooks(mic: mic), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
        let doctor = Troubleshooter(app: model)
        doctor.hearTimeout = .milliseconds(300); doctor.phraseTimeout = .milliseconds(300)
        doctor.start()
        if wake {
            while doctor.state(.phrase) != .running { await Task.yield() }
            model.handleWake(WakeEvent(phrase: "hey sol", at: Date()))
        }
        while doctor.running { try? await Task.sleep(for: .milliseconds(20)) }
        return (doctor, web, engine, model)
    }
    let denied = await run(mic: .denied, level: -20, wake: false)
    #expect(denied.0.failed == .microphoneAccess && denied.0.state(.listening) == .waiting)
    let silent = await run(level: -160, wake: false)
    #expect(silent.0.failed == .hearing)
    let missed = await run(level: -20, wake: false)
    #expect(missed.0.failed == .phrase)
    let button = await run(level: -20, wake: true, outcome: "not-found")
    #expect(button.0.failed == .callButton)
    let fine = await run(level: -20, wake: true)
    #expect(fine.0.done && fine.0.failed == nil)
    #expect(fine.1.calls == 0)                                  // saying the phrase during the check placed no call
    #expect(fine.3.wakeOverride == nil)                         // wakes go back to calls afterwards
}

@MainActor @Test func theStarCardAsksOnceAfterThreeCallsThatStarted() async {
    let web = FakeWeb()
    var opened: [URL] = []
    var hooks = QARender.fakeHooks()
    hooks.openURL = { opened.append($0) }
    var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: hooks, store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    web.outcome = "not-found"
    await model.call()                       // a call that didn't start doesn't count
    web.outcome = "pressed"
    for _ in 0..<2 { await model.call() }
    #expect(!model.asksForStar)
    await model.call()
    #expect(model.asksForStar)
    model.answerStarCard(star: true)
    #expect(opened == [AppModel.repository])
    #expect(!model.asksForStar)
    await model.call()
    #expect(model.settings.callsStarted == 3)  // counting stops once it's answered
}
