import Foundation

/// Energy voice-activity segmentation for one-screen voice tuning. Pure and deterministic (no clock,
/// no microphone) so it runs the same on fixtures in tests as on live audio.
public struct UtteranceSegmenter: Sendable {
    public static let rate = 16000
    static let frame = 320            // 20 ms
    static let startFrames = 3        // 60 ms above the gate opens a segment
    static let endFrames = 25         // 500 ms below the gate closes it
    static let prerollFrames = 15     // keep 300 ms before the opening
    static let maxSamples = 5 * 16000 // a segment never runs past 5 s

    private var noise: Float = 0.003
    private var pending: Clip = []
    private var preroll: [Clip] = []
    private var current: Clip = []
    private var openingSamples = 0
    private var inSpeech = false
    private var streak = 0
    private var silent = 0
    /// True once any frame has crossed the speech gate (the "did the mic hear anything" signal).
    public private(set) var heardSound = false
    /// True while a segment is open.
    public var speaking: Bool { inSpeech }

    public init() {}

    /// Feeds samples and returns any utterances that ended inside them.
    public mutating func feed(_ samples: Clip) -> [Clip] {
        pending.append(contentsOf: samples)
        var out: [Clip] = []
        var start = 0
        while pending.count - start >= Self.frame {
            let frame = Array(pending[start..<start + Self.frame])
            start += Self.frame
            if let clip = step(frame) { out.append(clip) }
        }
        pending.removeFirst(start)
        return out
    }

    private mutating func step(_ frame: Clip) -> Clip? {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        let gate = max(0.008, noise * 3.5)
        let voiced = rms > gate
        if voiced { heardSound = true }
        if !inSpeech {
            // The floor follows quiet frames only, so speech never raises its own gate.
            if !voiced { noise = max(0.001, noise * 0.95 + rms * 0.05) }
            preroll.append(frame)
            if preroll.count > Self.prerollFrames { preroll.removeFirst() }
            streak = voiced ? streak + 1 : 0
            if streak >= Self.startFrames {
                inSpeech = true; silent = 0
                current = preroll.flatMap { $0 }
                openingSamples = current.count
                preroll.removeAll()
            }
            return nil
        }
        current.append(contentsOf: frame)
        silent = voiced ? 0 : silent + 1
        if silent >= Self.endFrames || current.count >= Self.maxSamples { return close() }
        return nil
    }

    private mutating func close() -> Clip? {
        inSpeech = false; streak = 0
        // Keep 200 ms of the trailing silence, like a person's natural release.
        let trailing = max(0, silent - 10) * Self.frame
        var clip = current
        clip.removeLast(min(trailing, clip.count))
        current = []; silent = 0
        // The first utterance may start before the pre-roll fills.
        return clip.count - openingSamples >= Self.rate / 4 ? clip : nil
    }
}

public struct Utterance: Sendable {
    public let clip: Clip
    /// What the model heard in this utterance, judged against the wake phrase (`Hearing.judge`).
    public let hearing: Hearing
    public init(clip: Clip, hearing: Hearing) { self.clip = clip; self.hearing = hearing }
    /// The wake phrase was heard.
    public var matched: Bool { hearing == .phrase }
    public var duration: Double { Double(clip.count) / Double(UtteranceSegmenter.rate) }
}

private final class TuningSession: @unchecked Sendable {
    // Used only on Capture's serial queue.
    var segmenter = UtteranceSegmenter()
    let decoder: PhraseDecoder
    var elapsed = 0.0, lastMeter = -Double.infinity
    init() throws { decoder = try PhraseDecoder(directory: ModelFiles.locate()) }
}

/// Continuous listening for voice tuning: a level for the waveform about 20 times a second, and each
/// utterance (segmented by `UtteranceSegmenter`) with what the model heard in it, judged against the phrase.
/// Clips stay in memory for calibration; nothing is written or sent anywhere.
@MainActor public final class TuningListener {
    public private(set) var isListening = false
    private var capture: Capture?
    private var generation = UUID()
    public init() {}

    /// `onLevel(dBFS, soundHeard)`; `onUtterance` per segment. Records from `inputUID` (nil: the built-in
    /// microphone), like the listener. Throws when the mic is denied or the phrase can't be spelled by the model.
    public func start(phrase: String, inputUID: String?, onLevel: @escaping @MainActor (Float, Bool) -> Void,
                      onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
        stop()
        _ = try KeywordTokenizer().pieces(for: phrase)  // a phrase the model can't spell fails here, as before
        let session = try TuningSession()
        let capture = Capture(input: AudioInputs.current(preferredUID: inputUID)), generation = UUID()
        self.generation = generation
        try capture.start { [weak self, session] samples in
            session.elapsed += Double(samples.count) / 16000
            let clips = session.segmenter.feed(samples)
            let utterances = clips.map { Utterance(clip: $0, hearing: Hearing.judge(heard: session.decoder.pieces($0), phrase: phrase)) }
            let meter = session.elapsed - session.lastMeter >= 0.05
            if meter { session.lastMeter = session.elapsed }
            let level = 20 * log10(max(samples.map { abs($0) }.max() ?? 0, 0.00000001))
            let heard = session.segmenter.heardSound
            guard meter || !utterances.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.isListening else { return }
                if meter { onLevel(level, heard) }
                for u in utterances { onUtterance(u) }
            }
        }
        self.capture = capture; isListening = true
    }

    public func stop() {
        generation = UUID(); capture?.stop(); capture = nil; isListening = false
    }
}
