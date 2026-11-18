import AVFoundation
import Foundation
import Testing
import WakeEngine
@testable import HeyDotKit

// MARK: Fakes: the engine and system hooks never touch the mic or login items.

@MainActor
final class FakeEngine: WakeListening {
    var isListening = false
    var inputLevel: Float = -60
    var inputDeviceUID: String?
    /// The microphone each start used.
    var startedOn: [String?] = []
    func start(_ settings: WakeSettings, onWake: @escaping @MainActor (WakeEvent) -> Void) throws {
        isListening = true; startedOn.append(inputDeviceUID)
    }
    func stop() { isListening = false }
}

private func shortHome() throws -> URL {
    // sun_path is 104 bytes, so the control socket's home stays under /tmp.
    let dir = URL(fileURLWithPath: "/tmp/hc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func readyModel(home: URL, settings: AppSettings? = nil) -> (AppModel, FakeEngine) {
    var s = settings ?? AppSettings()
    if settings == nil { s.rename("Tray"); s.dotURL = "https://chatgpt.com/dots/tray"; s.onboarded = true }
    let paths = Paths(home: home)
    let hooks = SystemHooks(
                            setLaunchAtLogin: { _ in }, launchAtLoginEnabled: { false },
                            microphoneStatus: { .authorized }, requestMicrophone: { $0(true) })
    let engine = FakeEngine()
    let model = AppModel(settings: s, engine: engine, enroller: Enroller(),
                         hooks: hooks, store: SettingsStore(url: paths.settings))
    model.refreshListening()
    return (model, engine)
}

// MARK: Parsing

@Test func timesParseAsLocalOrWithOffsetAndRejectNonsense() throws {
    let est = TimeZone(identifier: "America/New_York")!
    let local = try #require(WakeControl.parseTime("2026-11-15T07:00", timeZone: est))
    #expect(WakeControl.format(local, timeZone: est) == "2026-11-15T07:00:00-05:00")
    #expect(WakeControl.parseTime("2026-11-15T12:00:00Z") == local)
    #expect(WakeControl.parseTime("2026-11-15T04:00:00-08:00") == local)
    for bad in ["tonight", "2026-02-30T07:00", "2026-11-15T25:00", "2026-11-15 07:00", "2026-11-15T07:00+99:00", ""] {
        #expect(WakeControl.parseTime(bad) == nil, "accepted \(bad)")
    }
}

@Test func controlVerbsParse() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(try WakeControl.parse(["status", "--json"]).get() == .init(verb: .status, json: true))
    #expect(try WakeControl.parse(["resume"]).get() == .init(verb: .resume, json: false))
    #expect(try WakeControl.parse(["pause"]).get() == .init(verb: .pause(until: nil), json: false))
    let later = try WakeControl.parse(["pause", "--until", "2099-01-01T00:00Z", "--json"], now: now).get()
    #expect(later == .init(verb: .pause(until: WakeControl.parseTime("2099-01-01T00:00Z")), json: true))
    for bad in [[], ["status", "extra"], ["pause", "--until"], ["pause", "--until", "2000-01-01T00:00Z"], ["quit"], ["--json"]] {
        #expect(throws: WakeControl.Failure.self, "accepted \(bad)") { try WakeControl.parse(bad, now: now).get() }
    }
}

@Test func sshAllowsOnlyTheControlVerbs() throws {
    let allowed: [String: [String]] = [
        "status --json": ["status", "--json"], "status": ["status"], "pause": ["pause"], "resume --json": ["resume", "--json"],
        "pause --until 2026-11-15T07:00 --json": ["pause", "--until", "2026-11-15T07:00", "--json"],
        "/tmp/example/Applications/HeyDot.app/Contents/MacOS/HeyDot --control status --json": ["status", "--json"],
    ]
    for (original, words) in allowed { #expect(try WakeControl.sshWords(original).get() == words) }
    let refused: [String?] = [nil, "", "bash", "bash -i", "status; id", "status --json && rm -rf ~", "$(id)", "`id`",
        "status\tid", "status\n", "pause --until 'now'", "pause --until tonight", "quit", "--control-ssh",
        "/bin/sh --control status", "HeyDot --qa-render /tmp/x", "internal-sftp", "scp -t /tmp", "status --json extra"]
    for original in refused {
        #expect(throws: WakeControl.Failure.self, "allowed \(String(describing: original))") {
            try WakeControl.sshWords(original).get()
        }
    }
}

@Test func sshEntryRefusesBeforeTouchingTheApp() throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    #expect(ControlCLI.run(arguments: ["HeyDot", "--control-ssh"], environment: [:], paths: paths) == 2)
    #expect(ControlCLI.run(arguments: ["HeyDot", "--control-ssh"], environment: ["SSH_ORIGINAL_COMMAND": "bash"], paths: paths) == 2)
    #expect(ControlCLI.run(arguments: ["HeyDot"], environment: [:], paths: paths) == nil)  // the menu bar app
}

// MARK: The app side

@MainActor
@Test func pauseAndResumeReportWakeAndPersist() throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let (model, engine) = readyModel(home: home)
    #expect(model.controlState["wake"] == "on" && model.controlState["state"] == "listening")

    let until = Date().addingTimeInterval(3600)
    model.pause(until: until)
    #expect(!engine.isListening)
    #expect(model.controlState["wake"] == "off" && model.controlState["paused_until"] == .string(WakeControl.format(until)))
    let saved = try SettingsStore(url: Paths(home: home).settings).load()
    #expect(saved.paused && saved.pausedUntil?.timeIntervalSince1970.rounded() == until.timeIntervalSince1970.rounded())

    model.resume()
    #expect(engine.isListening && model.controlState["wake"] == "on" && model.controlState["paused_until"] == .null)
    #expect(try SettingsStore(url: Paths(home: home).settings).load().pausedUntil == nil)
}

@MainActor
@Test func onlyADueTimedPauseResumesByItself() throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let (model, _) = readyModel(home: home)
    model.pause(until: Date().addingTimeInterval(60))
    model.resumeIfDue()
    #expect(model.controlState["wake"] == "off")
    model.resumeIfDue(now: Date().addingTimeInterval(61))
    #expect(model.controlState["wake"] == "on")
    model.pause(until: nil)  // untimed ("for tonight" without a time): stays off until resume
    model.resumeIfDue(now: .distantFuture)
    #expect(model.controlState["wake"] == "off")
    model.togglePause()  // the menu's Resume also ends a timed pause
    #expect(model.controlState["wake"] == "on" && model.settings.pausedUntil == nil)
}

@MainActor
@Test func wakeIsUnknownWhenNotListeningForAnotherReason() throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let (model, _) = readyModel(home: home, settings: AppSettings())  // setup not finished
    #expect(model.controlState["wake"] == .null && model.controlState["state"] == "setup_needed")
}

@MainActor
@Test func controlSocketRoundTripAndTimedPauseEndsInsideTheApp() async throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    let (model, engine) = readyModel(home: home)
    let service = try ControlService(model: model, paths: paths)
    defer { service.stop() }
    let mode = try FileManager.default.attributesOfItem(atPath: paths.controlSocket.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    func send(_ words: [String]) async -> Int32 {
        await Task.detached { ControlCLI.execute(words, paths: paths) }.value
    }
    #expect(await send(["status", "--json"]) == 0)
    let soon = WakeControl.format(Date().addingTimeInterval(4))
    #expect(await send(["pause", "--until", soon, "--json"]) == 0)
    #expect(model.controlState["wake"] == "off" && !engine.isListening)
    try await Task.sleep(for: .seconds(5.5))  // the app's own wall-clock timer resumes it
    #expect(model.controlState["wake"] == "on" && engine.isListening && model.settings.pausedUntil == nil)
    #expect(await send(["pause"]) == 0 && model.controlState["wake"] == "off")
    #expect(await send(["resume"]) == 0 && model.controlState["wake"] == "on")
    let raw = await Task.detached { ControlSocket.request(["op": "quit"], socket: paths.controlSocket, timeout: 5) }.value
    #expect(raw["outcome"] == "error")
}

@Test func notRunningIsAReadableStatusButPauseFails() throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    #expect(ControlCLI.execute(["status", "--json"], paths: paths) == 0)
    #expect(ControlCLI.execute(["pause", "--json"], paths: paths) == 1)
    #expect(ControlCLI.execute(["resume"], paths: paths) == 1)
}

@MainActor @Test func stoppedPauseServiceCannotRearmOrResume() async throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let (model, _) = readyModel(home: home)
    let service = try ControlService(model: model, paths: Paths(home: home))
    model.pause(until: Date().addingTimeInterval(0.04))
    model.pause(until: Date().addingTimeInterval(0.08))
    service.stop()
    service.scheduleExpiry()
    try await Task.sleep(for: .milliseconds(130))
    #expect(model.settings.paused)
    #expect(service.handle(["op": "resume"])["outcome"] == "error")
}

@MainActor private final class PendingCallWeb: WebCalling {
    var inCall = false
    var onCallChange: ((String?) -> Void)?
    var calls = 0
    var pending: CheckedContinuation<CallResult, Never>?
    func call(dotURL: String, wakeAt: Date) async -> CallResult {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func check(dotURL: String) async -> CallResult { CallResult(outcome: "would-press") }
    func endCall() { inCall = false }
    func warm(dotURL: String?) {}
    func pageState() async -> WebPageState { WebPageState(signedIn: nil) }
    func showSignIn(onClose: @escaping () -> Void) {}
    func signOut() async {}
}

@MainActor @Test func overlappingCallsAreRejectedAndQuitDropsLateResults() async throws {
    let web = PendingCallWeb()
    var settings = AppSettings(); settings.dotURL = "https://chatgpt.com/dots/test"; settings.onboarded = true
    let model = AppModel(settings: settings, engine: FakeEngine(), enroller: FakeEnroller(),
                         web: web, hooks: QARender.fakeHooks(), store: nil,
                         log: Log(url: URL(fileURLWithPath: "/dev/null")))
    let first = Task { await model.call() }
    while web.pending == nil { await Task.yield() }
    await model.call()
    #expect(web.calls == 1)
    model.stop()
    web.pending?.resume(returning: CallResult(outcome: "pressed")); web.pending = nil
    await first.value
    #expect(!model.calling && model.lastResult == nil)
    await model.call()
    #expect(web.calls == 1)
}

// MARK: Microphone choice

@MainActor @Test func microphoneChoiceReachesTheListenerAndPersists() throws {
    let home = try shortHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let (model, engine) = readyModel(home: home)
    #expect(engine.startedOn == [nil])  // built-in by default
    model.update { $0.inputDeviceUID = "AppleUSBAudioEngine:Mic" }
    #expect(engine.startedOn == [nil, "AppleUSBAudioEngine:Mic"])  // takes effect at once
    #expect(try SettingsStore(url: Paths(home: home).settings).load().inputDeviceUID == "AppleUSBAudioEngine:Mic")
    model.update { $0.inputDeviceUID = nil }
    #expect(engine.startedOn.last == .some(nil))
}
