import Foundation
import WakeEngine

@main struct Check {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: heydot-engine-check WAV [phrase] [repeat-count]"); return }
        let clip = try OfflineDetector.readWAV(URL(fileURLWithPath: args[1]))
        let settings = WakeSettings(phrase: args.count > 2 ? args[2] : "hey dot")
        let repeats = args.count > 3 ? max(1, Int(args[3]) ?? 1) : 1
        let start = ContinuousClock.now
        var hits = 0
        for _ in 0..<repeats { hits += try OfflineDetector.detections(in: clip, settings: settings) }
        let elapsed = start.duration(to: .now)
        print("detections=\(hits) audio_seconds=\(Double(clip.count * repeats) / 16000) elapsed=\(elapsed)"
              + " model_mb_estimate=\(String(format: "%.1f", Double(ListenerMeter.modelEstimateBytes ?? 0) / 1_048_576))")
    }
}
