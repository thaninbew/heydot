import AVFoundation
import WakeEngine

/// Stand-ins for QA renders: no microphone, no login items, no files outside the output folder.
@MainActor
final class FakeEngine: WakeListening {
    var inputLevel: Float = -17
    var isListening = false
    var inputDeviceUID: String?
    func start(_ settings: WakeSettings, onWake: @escaping @MainActor (WakeEvent) -> Void) throws { isListening = true }
    func stop() { isListening = false }
}

@MainActor
final class FakeTuner: VoiceTuner {
    func start(phrase: String, inputUID: String?, onLevel: @escaping @MainActor (Float, Bool) -> Void,
               onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
    func stop() {}
}

struct FakeEnroller: WakeEnrolling {
    func record(seconds: Double) async throws -> Clip { Array(repeating: 0.2, count: 16000) }
    // QA fixtures set the tuning result directly; `Calibration` has no public initializer to fake.
    func calibrate(phrase: String, positives: [Clip], negatives: [Clip]) async throws -> Calibration {
        throw WakeEngineError.engine("QA fake does not calibrate")
    }
}
