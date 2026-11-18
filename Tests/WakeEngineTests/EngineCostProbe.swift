import Darwin
import Foundation
import Testing
@testable import WakeEngine

/// Opt-in engine-only resource probe: HEYDOT_ENGINE_PROBE=1 swift test --filter engineCostProbe.
/// Feeds two minutes of audio through the live path (one stream, 683-sample buffers like the capture) and
/// reports decode CPU as percent of one core at real time, plus resident memory added by the model.
/// Uses fixtures only: no microphone, no speech synthesis.
@Test func engineCostProbe() throws {
    guard ProcessInfo.processInfo.environment["HEYDOT_ENGINE_PROBE"] == "1" else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    setenv("HEYDOT_MODEL_DIR", root.appendingPathComponent("Vendor/models").path, 1)
    func fixture(_ name: String) throws -> Clip {
        try OfflineDetector.readWAV(#require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures")))
    }
    func rss() -> Double {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        return Double(info.resident_size) / 1_048_576
    }
    func threadCPU() -> Double {
        var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }
    // Idle: a quiet room (seeded low noise). Active: speech every two seconds.
    var seed: UInt64 = 42
    func noise(_ n: Int, _ level: Float) -> Clip {
        (0..<n).map { _ in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Float(seed >> 40) / Float(1 << 24) - 0.5) * level }
    }
    let speech = try ["hey-tray-Samantha", "hey-there", "hey-dot-Daniel", "hey-jarvis"].map(fixture)
    let idle = noise(120 * 16000, 0.002)
    var active: Clip = []
    while active.count < 120 * 16000 { active += speech[active.count / 32000 % speech.count] + noise(16000, 0.002) }
    active = Array(active.prefix(120 * 16000))
    let configs: [(String, WakeSettings)] = [
        ("standard hey tray", WakeSettings(phrase: "hey tray", spellings: Enroller.spellings("hey tray"))),
        ("tuned hey tray", WakeSettings(phrase: "hey tray", spellings: Enroller.spellings("hey tray"), threshold: 0.12,
                                        learned: ["▁HE Y ▁TRA Y", "▁HE Y ▁DR A Y", "▁HA Y D RA Y"])),
        ("tuned hey luminaropolis", WakeSettings(phrase: "hey luminaropolis", spellings: Enroller.spellings("hey luminaropolis"), threshold: 0.17,
                                                  learned: ["▁HE Y LU M IN AR A PO LI S", "▁HE Y ▁LO OM ▁IN ▁A RA P OL US", "▁HE Y UM ▁IN ▁A RA P OL US"])),
    ]
    // One configuration per process gives a clean memory figure: HEYDOT_ENGINE_CONFIG=0, 1 or 2.
    let only = ProcessInfo.processInfo.environment["HEYDOT_ENGINE_CONFIG"].flatMap(Int.init)
    for (index, (label, settings)) in configs.enumerated() where only == nil || only == index {
        let before = rss()
        let spotter = try Spotter(settings: settings, directory: ModelFiles.locate())
        let loaded = rss()
        for (phase, audio) in [("idle", idle), ("active", active)] {
            let stream = try spotter.stream()
            let start = threadCPU()
            var hits = 0
            for offset in stride(from: 0, to: audio.count, by: 683) {
                hits += spotter.accept(Array(audio[offset..<min(offset + 683, audio.count)]), stream: stream)
            }
            let cpu = threadCPU() - start
            spotterDestroy(stream)
            print(String(format: "ENGINE|%@|%@|cpu %.2f%% of one core|hits %d|model +%.1f MiB|rss %.1f MiB", label, phase,
                         cpu / (Double(audio.count) / 16000) * 100, hits, loaded - before, rss()))
        }
    }
    guard only == nil || only == configs.count else { return }
    let decoderBefore = rss()
    let decoder = try PhraseDecoder(directory: ModelFiles.locate())
    let start = threadCPU()
    for clip in speech { _ = decoder.pieces(clip) }
    print(String(format: "ENGINE|tuning decoder|%.1f ms per utterance|model +%.1f MiB", (threadCPU() - start) / Double(speech.count) * 1000, rss() - decoderBefore))
}

import CSherpa
private func spotterDestroy(_ stream: OpaquePointer) { SherpaOnnxDestroyOnlineStream(stream) }
