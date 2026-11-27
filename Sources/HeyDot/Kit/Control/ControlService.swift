import Foundation

extension Paths {
    /// The app's control socket (0600, in the 0700 run directory), served while the menu bar app runs.
    public var controlSocket: URL { runDirectory.appendingPathComponent("control.sock") }
}

// MARK: The app's side

extension AppModel {
    /// What `--control status` reports. `wake` is "on" while the engine listens for the phrase, "off" while
    /// paused, and null otherwise (setup needed, microphone off, engine failed).
    public var controlState: JSONValue {
        let wake: JSONValue = settings.paused ? "off"
            : (engine.isListening && settings.onboarded && settings.dotURL != nil ? "on" : .null)
        let state: String = switch status {
        case .setupNeeded: "setup_needed"
        case .micAccessNeeded: "mic_permission_needed"
        case .micDenied: "mic_denied"
        case .paused: "paused"
        case .signInNeeded: "sign_in_needed"
        case .listening: "listening"
        case .calling: "calling"
        case .failed: "failed"
        }
        return ["outcome": "ok", "wake": wake, "state": .string(state), "paused": .bool(settings.paused),
                "paused_until": settings.pausedUntil.map { .string(WakeControl.format($0)) } ?? .null]
    }

    /// Pauses listening; with `until`, the app resumes by itself then (see `ControlService`).
    public func pause(until: Date?) { update { $0.paused = true; $0.pausedUntil = until } }

    public func resume() { update { $0.paused = false } }

    /// Ends a timed pause whose time has come. A later untimed or re-timed pause is left alone.
    func resumeIfDue(now: Date = Date()) {
        if settings.paused, let until = settings.pausedUntil, until <= now { resume() }
    }
}

/// Serves `--control` requests from the running app and runs the timed-pause expiry.
/// One instance per app process; `stop()` closes the socket.
@MainActor
public final class ControlService {
    private let model: AppModel
    private let server: ControlSocket.Server
    private var expiry: DispatchWorkItem?
    private var stopped = false

    public init(model: AppModel, paths: Paths = Paths()) throws {
        self.model = model
        server = try ControlSocket.Server(socket: paths.controlSocket)
        let server = server
        Thread.detachNewThread { [weak self] in
            server.serve { request in
                return DispatchQueue.main.sync { MainActor.assumeIsolated { self?.handle(request) } }
                    ?? ["outcome": "error", "error": "HeyDot is quitting"]
            }
        }
        model.resumeIfDue()  // a timed pause that ended while the app was closed
        scheduleExpiry()
        // Pauses set from the popover (Pause for 1 hour, until 8 AM tomorrow) use the same expiry.
        model.onPauseChange = { [weak self] in self?.scheduleExpiry() }
    }

    func handle(_ request: JSONValue) -> JSONValue {
        guard !stopped else { return ["outcome": "error", "error": "HeyDot is quitting"] }
        switch request["op"]?.string {
        case "status": break
        case "pause":
            let until = request["until"]?.number.map { Date(timeIntervalSince1970: $0) }
            if let until, until <= Date() { return ["outcome": "error", "error": "that time has already passed"] }
            model.pause(until: until)
        case "resume": model.resume()
        default: return ["outcome": "error", "error": "unknown control request"]
        }
        scheduleExpiry()
        return model.controlState
    }

    /// Wall-clock deadline, so a Mac that slept through it resumes as soon as it wakes.
    func scheduleExpiry() {
        expiry?.cancel()
        guard !stopped else { expiry = nil; return }
        guard model.settings.paused, let until = model.settings.pausedUntil else { expiry = nil; return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.model.resumeIfDue()
                self.scheduleExpiry()
            }
        }
        expiry = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, until.timeIntervalSinceNow), execute: work)
    }

    public func stop() {
        stopped = true
        model.onPauseChange = nil
        expiry?.cancel(); expiry = nil
        server.close()
    }
}
