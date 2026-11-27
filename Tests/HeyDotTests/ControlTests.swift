import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

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
    let home = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    #expect(ControlCLI.run(arguments: ["HeyDot", "--control-ssh"], environment: [:], paths: paths) == 2)
    #expect(ControlCLI.run(arguments: ["HeyDot", "--control-ssh"], environment: ["SSH_ORIGINAL_COMMAND": "bash"], paths: paths) == 2)
    #expect(ControlCLI.run(arguments: ["HeyDot"], environment: [:], paths: paths) == nil)  // the menu bar app
}

@MainActor
@Test func pauseAndResumeReportWakeAndPersist() throws {
    let home = try shortTempDir()
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
    let home = try shortTempDir()
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
    let home = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let (model, _) = readyModel(home: home, settings: AppSettings())  // setup not finished
    #expect(model.controlState["wake"] == .null && model.controlState["state"] == "setup_needed")
}

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

@MainActor
@Test func controlSocketRoundTripAndTimedPauseEndsInsideTheApp() async throws {
    let home = try shortTempDir()
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
    let home = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    #expect(ControlCLI.execute(["status", "--json"], paths: paths) == 0)
    #expect(ControlCLI.execute(["pause", "--json"], paths: paths) == 1)
    #expect(ControlCLI.execute(["resume"], paths: paths) == 1)
}

@MainActor @Test func stoppedPauseServiceCannotRearmOrResume() async throws {
    let home = try shortTempDir()
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

@Test func missingAppReportsNoHelper() throws {
    let root = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("control.sock")
    #expect(!ControlSocket.isHelperRunning(socket: socket))
    #expect(ControlSocket.request(["op": "status"], socket: socket)["outcome"] == "no-helper")
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    @discardableResult func mutate<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&stored) }
}

@Test func socketDeadlineBoundsAnUnresponsivePeer() throws {
    let root = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("hang.sock")
    let server = try ControlSocket.Server(socket: socket)
    defer { server.close() }
    Thread.detachNewThread { server.serve { _ in Thread.sleep(forTimeInterval: 0.3); return ["outcome": "ok"] } }
    let start = ProcessInfo.processInfo.systemUptime
    #expect(ControlSocket.request(["op": "status"], socket: socket, timeout: 0.05)["outcome"] == "no-reply")
    #expect(ProcessInfo.processInfo.systemUptime - start < 0.25)
    server.close()  // repeated shutdown must not close a reused descriptor
    #expect(!FileManager.default.fileExists(atPath: socket.path))
}

@Test func socketReadDeadlineDoesNotResetForEachByte() throws {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    let input = fds[0], output = fds[1]
    defer { close(input); close(output) }
    // Data is already buffered but lacks a newline. A total deadline must still expire.
    _ = ControlSocket.writeAll(output, Data("{\"outcome\":".utf8))
    let start = ProcessInfo.processInfo.systemUptime
    #expect(ControlSocket.readLine(input, deadline: start + 0.04) == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 0.25)
}
