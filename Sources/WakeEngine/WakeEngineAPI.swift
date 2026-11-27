import Foundation

// Everything the app uses from WakeEngine: settings, events, errors and the listening and tuning protocols.

/// What to listen for. `phrase` is lowercase words, e.g. "hey tray" (default "hey dot").
/// `spellings` are extra written forms of the same phrase that sound alike ("hey tray"); all map to one wake.
public struct WakeSettings: Codable, Equatable, Sendable {
    public var phrase: String
    public var spellings: [String]
    public var score: Float        // keyword boost; 2.0 measured best on the example voice
    public var threshold: Float    // trigger threshold; 0.08 measured best on the example voice
    /// Token sequences the model heard in the user's own tuning samples ("▁HE Y ▁LU MI NA ▁RO PO LI S"),
    /// spotted alongside the spelled phrase. Set by calibration; empty for standard settings.
    public var learned: [String]
    public init(phrase: String = "hey dot", spellings: [String] = [], score: Float = 2.0, threshold: Float = 0.08,
                learned: [String] = []) {
        self.phrase = phrase; self.spellings = spellings; self.score = score; self.threshold = threshold
        self.learned = learned
    }
    private enum CodingKeys: String, CodingKey { case phrase, spellings, score, threshold, learned }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(phrase: try c.decode(String.self, forKey: .phrase), spellings: try c.decode([String].self, forKey: .spellings),
                  score: try c.decode(Float.self, forKey: .score), threshold: try c.decode(Float.self, forKey: .threshold),
                  learned: try c.decodeIfPresent([String].self, forKey: .learned) ?? [])
    }
}

public struct WakeEvent: Sendable {
    public let phrase: String
    public let at: Date
}

/// 16 kHz mono Float32 samples in [-1, 1].
public typealias Clip = [Float]

public enum WakeEngineError: Error, Sendable {
    case microphoneDenied
    case modelMissing(String)
    case invalidPhrase(String)
    case engine(String)
}

public protocol WakeListening: AnyObject {
    /// Start listening on `inputDeviceUID`, or the built-in microphone (never the macOS default input; see
    /// `AudioInputs`). Calls `onWake` on the main actor, at most once per cooldown (3 s). Throws if the mic is
    /// denied, no allowed input exists, or the phrase cannot be tokenized by the model.
    @MainActor func start(_ settings: WakeSettings, onWake: @escaping @MainActor (WakeEvent) -> Void) throws
    /// The chosen microphone's Core Audio UID (`AudioInput.uid`); nil is the built-in microphone. Takes effect
    /// on the next start.
    @MainActor var inputDeviceUID: String? { get set }
    @MainActor func stop()
    /// Recent input peak in dBFS, for a level meter (updated about 10 times a second while listening).
    @MainActor var inputLevel: Float { get }
    @MainActor var isListening: Bool { get }
}

/// Voice tuning: pick settings that catch this person's own voice from clips of them saying the phrase.
public protocol WakeEnrolling: Sendable {
    /// Given clips of the user saying the phrase (positives) and saying other things (negatives: another
    /// "hey <name>", the name alone, "hey there"), learn the token sequences the model hears for the phrase
    /// and choose a threshold with a margin above every negative and below every positive. Offline, < 2 s.
    func calibrate(phrase: String, positives: [Clip], negatives: [Clip]) async throws -> Calibration
}

public struct Calibration: Sendable {
    public let settings: WakeSettings
    public let caught: Int          // positives detected with `settings`
    public let falseHits: Int       // negatives detected with `settings`
    public let note: String         // one plain sentence for the UI, e.g. "Caught 4 of 4, no false hits."
}
