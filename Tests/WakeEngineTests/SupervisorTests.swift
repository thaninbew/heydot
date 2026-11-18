import AppKit
import AVFoundation
import Foundation
import CoreAudio
import Testing
@testable import WakeEngine

/// A capture that records starts and can deliver audio or fail on demand.
final class FakeCapture: AudioCapturing, @unchecked Sendable {
    let engine = NSObject()
    var receive: (@Sendable (Clip) -> Void)?
    var stopped = false
    var configurationObject: AnyObject? { engine }
    let fail: Bool
    let device: String?
    init(fail: Bool = false, device: String? = "BuiltInMicrophoneDevice") { self.fail = fail; self.device = device }
    func start(receive: @escaping @Sendable (Clip) -> Void) throws {
        if fail { throw WakeEngineError.engine("no input device") }
        self.receive = receive
    }
    func stop() { stopped = true }
    func deliver() { receive?([0, 0, 0]) }
}

/// The Mac's audio inputs as the fakes see them: the built-in microphone (1) by default.
enum Mics {
    static let builtIn = AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    static let headphones = AudioInput(id: 2, uid: "AA-BB-CC:input", name: "AirPods Pro", transport: .bluetooth)
    static let usb = AudioInput(id: 3, uid: "AppleUSBAudioEngine:Mic", name: "USB Mic", transport: .usb)
    static let iPhone = AudioInput(id: 4, uid: "ContinuityCapture", name: "iPhone Microphone", transport: .continuity)
}

@MainActor
final class Rig {
    let center = NotificationCenter(), workspace = NotificationCenter(), distributed = NotificationCenter()
    var captures: [FakeCapture] = []
    var failNext = 0
    /// Connected inputs, in the order Core Audio lists them, and the user's choice.
    var devices: [AudioInput] = [Mics.builtIn]
    var preferred: String?
    var devicesChanged: (@MainActor () -> Void)?
    var lines: [String] = []
    var initialHolds: Set<String> = []
    lazy var supervisor = ListenerSupervisor(
        timing: .init(debounce: 0.02, maxBackoff: 0.2, stallAfter: 60, checkEvery: 60, healthyAfter: 60),
        resolveInput: { [unowned self] in AudioInputs.choose(preferredUID: self.preferred, among: self.devices)?.uid },
        makeCapture: { [unowned self] device in
            let c = FakeCapture(fail: self.failNext > 0, device: device)
            if self.failNext > 0 { self.failNext -= 1 }
            self.captures.append(c); return c
        },
        center: center, workspace: workspace, distributed: distributed,
        watchDevices: { [unowned self] changed in self.devicesChanged = changed; return { self.devicesChanged = nil } },
        initialHolds: initialHolds,
        log: { [unowned self] in self.lines.append($0) })
    /// Captures still holding the microphone.
    var open: [FakeCapture] { captures.filter { !$0.stopped } }
    func settle(_ seconds: Double = 0.15) async { try? await Task.sleep(for: .seconds(seconds)) }
}

@MainActor @Test func wakeAndConfigurationChangeRestartTheCaptureOnce() async throws {
    let rig = Rig()
    try rig.supervisor.start { _ in }
    #expect(rig.captures.count == 1)
    // Sleep/wake fires several signals together; they coalesce into one restart.
    rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    rig.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    rig.center.post(name: .AVAudioEngineConfigurationChange, object: rig.captures[0].engine)
    await rig.settle()
    #expect(rig.captures.count == 2)
    #expect(rig.captures[0].stopped)
    #expect(!rig.captures[1].stopped)
    #expect(rig.supervisor.restarts == 1)
    #expect(rig.lines.count == 1)
    #expect(rig.lines[0].contains("Mac woke") && rig.lines[0].contains("audio configuration changed") && rig.lines[0].contains("ok"))
    rig.supervisor.stop()
    #expect(rig.captures[1].stopped)
}

@MainActor @Test func anotherEnginesConfigurationChangeIsIgnored() async throws {
    let rig = Rig()
    try rig.supervisor.start { _ in }
    rig.center.post(name: .AVAudioEngineConfigurationChange, object: NSObject())  // e.g. voice tuning's own engine
    await rig.settle()
    #expect(rig.captures.count == 1)
    rig.supervisor.stop()
}

// MARK: Headphones shared with a phone (the example dropped FaceTime calls)

@Test func autoSelectionIsAlwaysTheBuiltInMicrophone() {
    // Bluetooth headphones and an iPhone's Continuity mic are listed first, as when they just became the default.
    let all = [Mics.headphones, Mics.iPhone, Mics.usb, Mics.builtIn]
    #expect(AudioInputs.choose(preferredUID: nil, among: all) == Mics.builtIn)
    // A deliberate choice is honoured while it is connected, Bluetooth included.
    #expect(AudioInputs.choose(preferredUID: Mics.usb.uid, among: all) == Mics.usb)
    #expect(AudioInputs.choose(preferredUID: Mics.headphones.uid, among: all) == Mics.headphones)
    // A chosen device that left falls back to built-in, not to whatever the default became.
    #expect(AudioInputs.choose(preferredUID: Mics.usb.uid, among: [Mics.headphones, Mics.builtIn]) == Mics.builtIn)
    // No built-in microphone and no choice: nothing, never a Bluetooth or Continuity input.
    #expect(AudioInputs.choose(preferredUID: nil, among: [Mics.headphones, Mics.iPhone]) == nil)
}

@MainActor @Test func bluetoothHeadphonesBecomingTheDefaultKeepTheBuiltInMicrophone() async throws {
    let rig = Rig()
    let heard = Counter()
    try rig.supervisor.start { _ in heard.add() }
    #expect(rig.captures.map(\.device) == [Mics.builtIn.uid])
    // Headphones connect and become the macOS default input: nothing restarts, nothing moves to them.
    rig.devices = [Mics.headphones, Mics.builtIn]
    rig.devicesChanged?()
    await rig.settle()
    #expect(rig.captures.count == 1 && rig.open.count == 1)
    // The phone takes the headphones and the hardware reconfigures: the restart stays on built-in.
    rig.center.post(name: .AVAudioEngineConfigurationChange, object: rig.captures[0].engine)
    await rig.settle()
    #expect(rig.captures.map(\.device) == [Mics.builtIn.uid, Mics.builtIn.uid])
    rig.captures[1].deliver()
    #expect(heard.value == 1)
    #expect(!rig.lines.joined().contains("AirPods"))
    rig.supervisor.stop()
    #expect(rig.devicesChanged == nil)  // listener removed
}

@MainActor @Test func aStallRestartsOnTheSelectedDeviceNotTheDefault() async throws {
    let clock = TestClock()
    let rig = Rig()
    rig.devices = [Mics.headphones, Mics.builtIn]
    let supervisor = ListenerSupervisor(
        timing: .init(debounce: 0.01, maxBackoff: 0.1, stallAfter: 6, checkEvery: 0.02, healthyAfter: 10),
        resolveInput: { AudioInputs.choose(preferredUID: nil, among: rig.devices)?.uid },
        makeCapture: { let c = FakeCapture(device: $0); rig.captures.append(c); return c },
        center: rig.center, workspace: rig.workspace, distributed: rig.distributed, watchDevices: { _ in {} },
        initialHolds: [], log: { rig.lines.append($0) }, now: { clock.t })
    try supervisor.start { _ in }
    clock.t = 7; await rig.settle(0.1)
    #expect(rig.captures.count == 2)
    #expect(rig.captures.allSatisfy { $0.device == Mics.builtIn.uid })
    supervisor.stop()
}

@MainActor @Test func aChosenMicrophoneFallsBackToBuiltInAndReturns() async throws {
    let rig = Rig()
    rig.devices = [Mics.builtIn, Mics.usb]
    rig.preferred = Mics.usb.uid
    try rig.supervisor.start { _ in }
    #expect(rig.captures.map(\.device) == [Mics.usb.uid])
    rig.devices = [Mics.headphones, Mics.builtIn]  // the USB mic is unplugged as headphones connect
    rig.devicesChanged?()
    await rig.settle()
    #expect(rig.captures.map(\.device) == [Mics.usb.uid, Mics.builtIn.uid])
    #expect(rig.lines.last?.contains("input devices changed") == true)
    rig.devices = [Mics.headphones, Mics.builtIn, Mics.usb]  // plugged back in
    rig.devicesChanged?()
    await rig.settle()
    #expect(rig.captures.map(\.device) == [Mics.usb.uid, Mics.builtIn.uid, Mics.usb.uid])
    #expect(rig.open.count == 1)
    rig.supervisor.stop()
}

// MARK: Display sleep and lock release the microphone

@MainActor @Test func displaySleepReleasesTheMicrophoneUntilTheDisplaysWake() async throws {
    let rig = Rig()
    try rig.supervisor.start { _ in }
    rig.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    #expect(rig.open.isEmpty)
    #expect(rig.lines.last?.contains("released the microphone (displays slept)") == true)
    // Nothing reopens it while the displays are off: no stall check, device change or reconfiguration.
    rig.supervisor.checkStall()
    rig.devices = [Mics.headphones, Mics.builtIn]
    rig.devicesChanged?()
    rig.supervisor.schedule("audio configuration changed")
    await rig.settle()
    #expect(rig.captures.count == 1 && rig.open.isEmpty)
    rig.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    await rig.settle()
    #expect(rig.captures.count == 2 && rig.open.count == 1)
    #expect(rig.open.first?.device == Mics.builtIn.uid)
    rig.supervisor.stop()
}

@MainActor @Test func lockAndDisplaySleepMustBothEndBeforeListeningResumes() async throws {
    let rig = Rig()
    try rig.supervisor.start { _ in }
    rig.distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
    rig.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    #expect(rig.open.isEmpty)
    rig.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    await rig.settle()
    #expect(rig.open.isEmpty)  // still locked
    rig.distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    await rig.settle()
    #expect(rig.open.count == 1)
    // Switching to another user releases it too.
    rig.workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    #expect(rig.open.isEmpty)
    rig.workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    await rig.settle()
    #expect(rig.open.count == 1)
    rig.supervisor.stop()
}

@MainActor @Test func listeningStartedWhileTheDisplayIsOffWaitsForIt() async throws {
    let rig = Rig()
    rig.initialHolds = ["displays asleep"]
    try rig.supervisor.start { _ in }  // e.g. a timed pause ending overnight
    #expect(rig.captures.isEmpty)
    rig.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    await rig.settle()
    #expect(rig.open.count == 1)
    rig.supervisor.stop()
    #expect(rig.open.isEmpty)
    // Holds outlive stop: a later start while the screen is locked opens nothing.
    rig.distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
    try rig.supervisor.start { _ in }
    #expect(rig.open.isEmpty)
    rig.supervisor.stop()
}

@MainActor @Test func failedRestartsBackOffAndRetryUntilOneWorks() async throws {
    let rig = Rig()
    try rig.supervisor.start { _ in }
    rig.failNext = 2
    rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    await rig.settle(0.6)  // 0.02 debounce, then 0.04 and 0.08 backoff
    #expect(rig.captures.count == 4)
    #expect(rig.lines.filter { $0.contains("failed") }.count == 2)
    #expect(rig.lines.last?.contains("ok") == true)
    rig.supervisor.stop()
}

@MainActor @Test func silentStallRestartsTheCapture() async throws {
    let clock = TestClock()
    let rig = Rig()
    let supervisor = ListenerSupervisor(
        timing: .init(debounce: 0.01, maxBackoff: 0.1, stallAfter: 6, checkEvery: 0.02, healthyAfter: 10),
        resolveInput: { Mics.builtIn.uid }, makeCapture: { let c = FakeCapture(device: $0); rig.captures.append(c); return c },
        center: rig.center, workspace: rig.workspace, distributed: rig.distributed, watchDevices: { _ in {} },
        initialHolds: [], log: { rig.lines.append($0) }, now: { clock.t })
    try supervisor.start { _ in }
    rig.captures[0].deliver()
    clock.t = 5; await rig.settle(0.1)
    #expect(rig.captures.count == 1)  // 5 s of quiet is not a stall yet
    clock.t = 7; await rig.settle(0.1)
    #expect(rig.captures.count == 2)
    #expect(rig.lines.first?.contains("no audio for 7 s") == true)
    supervisor.stop()
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class TestClock: @unchecked Sendable { var t = 0.0 }

@MainActor @Test func failedInitialCaptureIsStoppedAndStopCancelsPendingRestart() async throws {
    let rig = Rig()
    rig.failNext = 1
    #expect(throws: WakeEngineError.self) { try rig.supervisor.start { _ in } }
    #expect(rig.captures.first?.stopped == true)
    #expect(!rig.supervisor.running)
    try rig.supervisor.start { _ in }
    rig.supervisor.schedule("test")
    rig.supervisor.stop()
    await rig.settle()
    #expect(rig.captures.count == 2)
    #expect(rig.captures.allSatisfy { $0.stopped })
}
