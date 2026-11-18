import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// One microphone capture: an input tap on an audio engine. A capture is used once; restarts make a new one.
protocol AudioCapturing: AnyObject {
    func start(receive: @escaping @Sendable (Clip) -> Void) throws
    func stop()
    /// The object `AVAudioEngineConfigurationChange` is posted for (the capture's engine).
    var configurationObject: AnyObject? { get }
}

extension Capture: AudioCapturing {
    var configurationObject: AnyObject? { session }
}

/// Watches something about the audio hardware. Returns a cancel closure.
typealias InputWatch = @MainActor (@escaping @MainActor () -> Void) -> () -> Void

/// Time of the last audio buffer, written from the capture queue and read on the main actor.
final class FrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval
    init(_ now: TimeInterval) { last = now }
    func tick(_ now: TimeInterval) { lock.lock(); last = now; lock.unlock() }
    var lastFrame: TimeInterval { lock.lock(); defer { lock.unlock() }; return last }
}

/// Keeps one capture alive while listening, on one device: the user's chosen input or the built-in microphone
/// (`resolveInput`, see `AudioInputs.choose`), never the macOS default input. A capture dies silently when the
/// Mac sleeps or the audio hardware is reconfigured, so the supervisor tears it down and starts a fresh one on
/// any of: `AVAudioEngineConfigurationChange`, `NSWorkspace.didWakeNotification`, `screensDidWakeNotification`,
/// a device connecting or disconnecting that changes which device should be used, or no audio buffer for
/// `stallAfter` seconds. Restarts coalesce (`debounce`), back off exponentially to `maxBackoff` while they keep
/// happening, and the backoff resets once audio has flowed for `healthyAfter` seconds. Every restart is logged.
///
/// The microphone is released, not merely muted, while the displays sleep, the Mac sleeps, the screen is
/// locked or the session is switched away (`holds`), and opened again once all of those have ended. Holds track
/// the system for the supervisor's whole life, so a listener started while the display is off waits too.
@MainActor
final class ListenerSupervisor {
    struct Timing: Sendable {
        var debounce: TimeInterval = 0.5
        var maxBackoff: TimeInterval = 30
        var stallAfter: TimeInterval = 6
        var checkEvery: TimeInterval = 2
        var healthyAfter: TimeInterval = 10
    }

    /// System events that release the microphone (`on`) or allow it again, with the restart reason they log.
    static let presenceEvents: [(name: Notification.Name, hold: String, on: Bool, reason: String)] = [
        (NSWorkspace.screensDidSleepNotification, "displays asleep", true, "displays slept"),
        (NSWorkspace.screensDidWakeNotification, "displays asleep", false, "screens woke"),
        (NSWorkspace.willSleepNotification, "Mac asleep", true, "Mac slept"),
        (NSWorkspace.didWakeNotification, "Mac asleep", false, "Mac woke"),
        (NSWorkspace.sessionDidResignActiveNotification, "session inactive", true, "session switched away"),
        (NSWorkspace.sessionDidBecomeActiveNotification, "session inactive", false, "session active"),
    ]
    static let lockEvents: [(name: Notification.Name, on: Bool, reason: String)] = [
        (Notification.Name("com.apple.screenIsLocked"), true, "screen locked"),
        (Notification.Name("com.apple.screenIsUnlocked"), false, "screen unlocked"),
    ]

    private let timing: Timing
    private let resolveInput: @MainActor () -> String?
    private let makeCapture: (String?) -> AudioCapturing
    private let center: NotificationCenter
    private let workspace: NotificationCenter
    private let distributed: NotificationCenter
    private let watchDevices: InputWatch
    private let log: (String) -> Void
    private let now: @Sendable () -> TimeInterval

    private var capture: AudioCapturing?
    /// The UID of the device the current capture was opened on.
    private(set) var device: String?
    private var receive: (@Sendable (Clip) -> Void)?
    private var clock: FrameClock
    private var observers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var presenceObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancelDeviceWatch: (() -> Void)?
    private var watchdog: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var pendingReasons: [String] = []
    private var attempt = 0
    private var startedAt: TimeInterval = 0
    /// Restarts performed since `start` (for tests and the log).
    private(set) var restarts = 0
    private(set) var running = false
    /// Why the microphone is released right now; empty while the user is at the Mac.
    private(set) var holds: Set<String>
    var holding: Bool { !holds.isEmpty }

    init(timing: Timing = Timing(), resolveInput: @escaping @MainActor () -> String? = { AudioInputs.current(preferredUID: nil) },
         makeCapture: @escaping (String?) -> AudioCapturing = { Capture(input: $0) },
         center: NotificationCenter = .default, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         watchDevices: @escaping InputWatch = AudioInputs.watchDevices, initialHolds: Set<String>? = nil,
         log: @escaping (String) -> Void = { _ in },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.timing = timing; self.resolveInput = resolveInput; self.makeCapture = makeCapture
        self.center = center; self.workspace = workspace; self.distributed = distributed
        self.watchDevices = watchDevices; self.log = log; self.now = now
        holds = initialHolds ?? SystemPresence.current()
        clock = FrameClock(now())
        observePresence()
    }

    deinit { for (center, token) in presenceObservers { center.removeObserver(token) } }

    /// Starts listening. Errors from the first capture (microphone denied, no input format, no allowed input) are
    /// thrown to the caller. While a hold is in effect nothing is opened until it ends.
    func start(receive: @escaping @Sendable (Clip) -> Void) throws {
        stop()
        self.receive = receive
        if holds.isEmpty {
            do { try open() } catch {
                stop()  // a partially started capture still owns a tap/engine
                throw error
            }
        } else {
            log("listener: waiting to open the microphone (\(holds.sorted().joined(separator: ", ")))")
        }
        running = true
        attempt = 0; restarts = 0
        observe()
    }

    func stop() {
        running = false
        pending?.cancel(); pending = nil; pendingReasons = []
        watchdog?.cancel(); watchdog = nil
        observers.forEach { center.removeObserver($0) }
        observers = []
        cancelDeviceWatch?(); cancelDeviceWatch = nil
        capture?.stop(); capture = nil; device = nil
        receive = nil
    }

    private func open() throws {
        guard let receive else { return }
        let clock = FrameClock(now())
        self.clock = clock
        startedAt = now()
        let device = resolveInput()
        self.device = device
        let capture = makeCapture(device)
        self.capture = capture
        let now = self.now
        try capture.start { samples in clock.tick(now()); receive(samples) }
    }

    /// Notifications that mean the current capture died, posted for its configuration object.
    static let captureEvents: [(Notification.Name, String)] = [
        (.AVAudioEngineConfigurationChange, "audio configuration changed"),
        (AVCaptureSession.runtimeErrorNotification, "capture error"),
        (AVCaptureSession.wasInterruptedNotification, "capture interrupted"),
    ]

    private func observe() {
        for (name, reason) in Self.captureEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, let mine = self.capture?.configurationObject, sender == ObjectIdentifier(mine) else { return }
                    self.schedule(reason)
                }
            })
        }
        cancelDeviceWatch = watchDevices { [weak self] in self?.devicesChanged() }
        let every = timing.checkEvery
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(every))
                guard let self, !Task.isCancelled else { return }
                self.checkStall()
            }
        }
    }

    /// A device connected or disconnected. Restart only when that changes which device should be used (the chosen
    /// one came back or the current one left); a new default input, such as headphones connecting, changes nothing.
    func devicesChanged() {
        guard running, holds.isEmpty, resolveInput() != device else { return }
        schedule("input devices changed")
    }

    private func observePresence() {
        for event in Self.presenceEvents {
            let token = workspace.addObserver(forName: event.name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presence(event.hold, on: event.on, reason: event.reason) }
            }
            presenceObservers.append((workspace, token))
        }
        for event in Self.lockEvents {
            let token = distributed.addObserver(forName: event.name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presence("screen locked", on: event.on, reason: event.reason) }
            }
            presenceObservers.append((distributed, token))
        }
    }

    /// Applies one system event. The first hold releases the microphone; when the last one ends the capture is
    /// opened again. A wake that ends no hold (the capture may have died anyway) still restarts it.
    func presence(_ hold: String, on: Bool, reason: String) {
        if on {
            guard holds.insert(hold).inserted, holds.count == 1, running else { return }
            pending?.cancel(); pending = nil; pendingReasons = []
            attempt = 0
            let had = capture != nil
            capture?.stop(); capture = nil; device = nil
            if had { log("listener: released the microphone (\(reason))") }
        } else {
            holds.remove(hold)
            guard holds.isEmpty else { return }
            schedule(reason)
        }
    }

    /// No buffer for `stallAfter` seconds while listening: the tap is dead even though nothing said so.
    func checkStall() {
        guard running, holds.isEmpty, pending == nil else { return }
        let t = now(), silent = t - max(clock.lastFrame, startedAt)
        if silent >= timing.stallAfter {
            schedule(String(format: "no audio for %.0f s", silent))
        } else if attempt > 0, t - startedAt >= timing.healthyAfter, t - clock.lastFrame < timing.stallAfter {
            attempt = 0  // audio has flowed long enough since the last restart
        }
    }

    /// Coalesces restart requests; waits `debounce` the first time, then backs off while restarts repeat.
    func schedule(_ reason: String) {
        guard running, holds.isEmpty else { return }
        if !pendingReasons.contains(reason) { pendingReasons.append(reason) }
        guard pending == nil else { return }
        let delay = attempt == 0 ? timing.debounce : min(timing.maxBackoff, timing.debounce * pow(2, Double(attempt)))
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.restart()
        }
    }

    private func restart() {
        let reasons = pendingReasons.joined(separator: ", ")
        pending = nil; pendingReasons = []
        guard running, holds.isEmpty else { return }
        attempt = min(attempt + 1, 30); restarts += 1
        let began = now()
        capture?.stop(); capture = nil
        do {
            try open()
            log(String(format: "listener: restart %d (%@) ok in %.0f ms", restarts, reasons, (now() - began) * 1000))
        } catch {
            capture?.stop(); capture = nil
            let next = min(timing.maxBackoff, timing.debounce * pow(2, Double(attempt)))
            log(String(format: "listener: restart %d (%@) failed: %@; retrying in %.1f s", restarts, reasons, "\(error)", next))
            schedule("retry after failure")
        }
    }
}

/// Whether the user is at the Mac right now, for a supervisor created while the display is off or the screen
/// is locked (later changes arrive as notifications).
enum SystemPresence {
    @MainActor static func current() -> Set<String> {
        var holds: Set<String> = []
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { holds.insert("displays asleep") }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (session["CGSSessionScreenIsLocked"] as? Bool) == true { holds.insert("screen locked") }
            if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { holds.insert("session inactive") }
        }
        return holds
    }
}
