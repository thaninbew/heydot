import Foundation
import WakeEngine

/// The listener's own cost, not the whole app's: CPU in percent of one core (the thread CPU time spent in
/// the audio tap and keyword spotting, `ListenerMeter`, per wall-second) and its estimated memory (keyword
/// model plus audio buffers). One sample a second, and only while some view shows it.
@MainActor
final class ListenerUsage: ObservableObject {
    static let shared = ListenerUsage()

    struct Sample: Equatable { var cpu: Double; var megabytes: Double }

    @Published private(set) var latest: Sample?
    @Published private(set) var history: [Double] = []   // CPU percent, oldest first
    private var viewers: Set<String> = []
    // Main-actor confined in life; deinit only invalidates the thread-safe Timer.
    nonisolated(unsafe) private var timer: Timer?
    var isSampling: Bool { timer != nil }
    deinit { timer?.invalidate() }
    private var last: (cpu: Double, wall: Double)?
    /// Readers; replaced in tests.
    var cpuSeconds: () -> Double = { ListenerMeter.cpuSeconds }
    var bytes: () -> Int = { ListenerMeter.estimatedBytes }
    var uptime: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Injected in QA renders so screenshots show a stable reading.
    var fixture: (Sample, [Double])? {
        didSet { if let fixture { latest = fixture.0; history = fixture.1 } }
    }

    /// Starts sampling for `viewer` (idempotent). Sampling stops when the last viewer leaves.
    func show(_ viewer: String) {
        guard fixture == nil else { return }
        viewers.insert(viewer)
        guard timer == nil else { return }
        last = nil
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.viewers.isEmpty else { return }
                self.sample()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide(_ viewer: String) {
        viewers.remove(viewer)
        guard viewers.isEmpty else { return }
        timer?.invalidate(); timer = nil
    }

    func sample() {
        let wall = uptime(), cpu = cpuSeconds()
        let mb = Double(bytes()) / 1_048_576
        if let last, wall > last.wall {
            let percent = max(0, (cpu - last.cpu) / (wall - last.wall) * 100)
            latest = Sample(cpu: percent, megabytes: mb)
            history.append(percent)
            if history.count > 40 { history.removeFirst(history.count - 40) }
        } else if latest == nil {
            latest = Sample(cpu: 0, megabytes: mb)
        }
        last = (cpu, wall)
    }

    /// "Listener: 0.4% CPU · ~18 MB" (the memory figure is an estimate, hence the tilde).
    static func describe(_ s: Sample) -> String {
        let cpu = s.cpu < 10 ? String(format: "%.1f", s.cpu) : String(format: "%.0f", s.cpu)
        return "Listener: \(cpu)% CPU \u{00B7} ~\(Int(s.megabytes.rounded())) MB"
    }
}
