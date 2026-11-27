import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heydot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func shortTempDir() throws -> URL {
    // sun_path is 104 bytes, so keep test sockets under /tmp.
    let dir = URL(fileURLWithPath: "/tmp/hd-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

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

@MainActor
func readyModel(home: URL, settings: AppSettings? = nil) -> (AppModel, FakeEngine) {
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
    func showChatGPT(pickingDot: Bool, onClose: @escaping (DotTab?) -> Void) {}
    func signOut() async {}
}

/// A press that never returns (a hung page) must not wedge HeyDot: Reload frees it and the next call works.
@MainActor final class HungWeb: WebCalling {
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
    func showChatGPT(pickingDot: Bool, onClose: @escaping (DotTab?) -> Void) {}
    func signOut() async {}
    func reset() { resets += 1 }
}

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

func take(_ words: String, level: Float = 0.1) -> Utterance {
    Utterance(clip: Clip(repeating: level, count: 16000), heard: words.split(separator: " ").map { "▁" + $0 })
}
