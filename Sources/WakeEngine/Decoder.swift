import Foundation
import CSherpa

/// The keyword model run as a plain streaming recognizer, only while voice tuning (never by the listener).
/// It reports which tokens the model itself hears in a sample. A rare name such as "Luminaropolis" is
/// spelled `▁JE FF HA LO PO U LO S` by the tokenizer, but the model hears `▁LU MI NA ▁RO PO LI S`;
/// the spotter matches exact token paths, so only the heard sequence can ever fire. Calibration stores
/// those sequences as extra keywords (`WakeSettings.learned`), and tuning compares the heard words of the
/// user's takes with each other (`Takes`).
final class PhraseDecoder {
    let handle: OpaquePointer
    init(directory: URL) throws {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ text: String) -> UnsafePointer<CChar> { let p = strdup(text)!; strings.append(p); return UnsafePointer(p) }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(directory.appendingPathComponent("encoder-\(ModelFiles.stem)").path)
        config.model_config.transducer.decoder = c(directory.appendingPathComponent("decoder-\(ModelFiles.stem)").path)
        config.model_config.transducer.joiner = c(directory.appendingPathComponent("joiner-\(ModelFiles.stem)").path)
        config.model_config.tokens = c(directory.appendingPathComponent("tokens.txt").path)
        config.model_config.provider = c("cpu"); config.model_config.num_threads = 1
        config.decoding_method = c("modified_beam_search"); config.max_active_paths = 4
        guard let handle = SherpaOnnxCreateOnlineRecognizer(&config) else {
            throw WakeEngineError.engine("sherpa-onnx could not load the model for tuning")
        }
        self.handle = handle
    }
    deinit { SherpaOnnxDestroyOnlineRecognizer(handle) }

    /// The model's tokens for one utterance, with word starts as `▁` (the keyword syntax).
    func pieces(_ clip: Clip) -> [String] {
        guard let stream = SherpaOnnxCreateOnlineStream(handle) else { return [] }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        let audio = Clip(repeating: 0, count: 4000) + clip + Clip(repeating: 0, count: 8000)
        audio.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxOnlineStreamInputFinished(stream)
        while SherpaOnnxIsOnlineStreamReady(handle, stream) != 0 { SherpaOnnxDecodeOnlineStream(handle, stream) }
        guard let result = SherpaOnnxGetOnlineStreamResult(handle, stream) else { return [] }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        return (0..<Int(result.pointee.count)).compactMap { i in
            result.pointee.tokens_arr[i].map { String(cString: $0) }
        }.map { $0.hasPrefix(" ") ? "▁" + $0.dropFirst() : $0 }.filter { !$0.isEmpty && $0 != "▁" }
    }
}

/// Voice tuning learns how this user says the wake phrase. A recording counts as a take when it is a plausible
/// wake utterance and sounds like the user's other takes; it is never compared with the spelling, because the
/// user's own way of saying the name is the one the listener has to catch.
public enum Takes {
    /// Why a recording can't be a take, described as the recording (never as a wrong name).
    public enum Problem: Equatable, Sendable {
        /// The model made no words of it, and it was quiet.
        case quiet
        /// The model made no words of it.
        case nothing
        /// Longer than a wake phrase: a sentence, or the phrase with more after it.
        case long
    }

    public static func problem(_ u: Utterance, phrase: String) -> Problem? {
        guard sound(u.heard).count >= 2 else { return u.peak < -30 ? .quiet : .nothing }
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).count
        if u.duration > 4 || Self.words(u.heard) > max(4, words + 2) { return .long }
        return nil
    }

    /// The takes that agree: the largest group similar to one centre take (the earliest on ties), in order.
    /// A stray recording (a cough the model made a word of, "Hey John" in the middle) stays out of it.
    public static func agreeing(_ takes: [[String]]) -> [Int] {
        let sounds = takes.map(sound)
        var best: [Int] = []
        for centre in sounds {
            let group = sounds.indices.filter { similarity(centre, sounds[$0]) >= bar }
            if group.count > best.count { best = group }
        }
        return best
    }

    /// Whether a take's tokens are specific enough to become a keyword whatever else is spotted: a long reading
    /// ("HALUMINAROPOLIS") is; a short one ("HADOT") sits next to other names and is learned only when it repeats
    /// (`repeated`) and the listener would miss the take without it.
    static func specific(_ take: [String]) -> Bool { take.count >= 2 && sound(take).count >= 8 }

    /// Whether another of `takes` (which include `take`) sounds the same, up to one small slip: the user's way of
    /// saying it, not how the model misheard one take. "HEY DRAY" once among "HEY TRAY"s would answer "Hey Dre"
    /// ("HADRA" is 0.9 from "HATRA").
    static func repeated(_ take: [String], among takes: [[String]]) -> Bool {
        let s = sound(take)
        return take.count >= 2 && takes.filter { similarity(s, sound($0)) > 0.9 }.count >= 2
    }

    /// Two takes sound alike at this similarity. Takes of one phrase by one speaker, slow and rushed, score
    /// 0.7 and up ("HATRA", "HADRA", "PATRE"); the name alone ("TRA") scores 0.6, "Hey John" 0.4.
    static let bar = 0.65

    static func words(_ pieces: [String]) -> Int {
        pieces.joined().split(separator: "▁").filter { $0.contains(where: \.isLetter) }.count
    }

    /// The heard letters with spelling-of-sound normalization and the word breaks removed, since the model
    /// moves them when a phrase is rushed: "HEY TRAY" and "HA T RE Y" are both "HATRA", "HEY DRAY" is "HADRA".
    /// Doubled letters collapse and TH is T ("PAY THREE" is "PATRE").
    static func sound(_ pieces: [String]) -> String {
        var s = String(pieces.joined().filter(\.isLetter)).uppercased()
        for (from, to) in [("EIGH", "A"), ("IGH", "I"), ("PH", "F"), ("TH", "T"), ("CK", "K"), ("GH", ""), ("AY", "A"), ("EY", "A"),
                           ("EI", "A"), ("AI", "A"), ("EE", "E"), ("EA", "E"), ("IE", "E"), ("OY", "OI"), ("OO", "U"),
                           ("OU", "U"), ("OW", "O"), ("AU", "O"), ("AW", "O")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        if s.count > 1, s.hasSuffix("Y") { s = String(s.dropLast()) + "E" }
        var out = ""
        for c in s where out.last != c { out.append(c) }
        return out
    }

    /// 1 minus a weighted edit distance over the longer length. Vowels, and voiced/unvoiced pairs such as
    /// D and T, cost half a substitution (after `sound`, so a different vowel sound still costs).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var row = Array(0...y.count).map(Double.init)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var previous = row[0]; row[0] = Double(i)
            for j in stride(from: 1, through: y.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + cost(x[i - 1], y[j - 1]))
                previous = current
            }
        }
        return 1 - row[y.count] / Double(max(x.count, y.count))
    }
    private static let alike: [Set<Character>] = ["AEIOUY", "DT", "BP", "KCGQ", "FV", "SZ", "MN", "LR"].map { Set($0) }
    private static func cost(_ a: Character, _ b: Character) -> Double {
        a == b ? 0 : alike.contains { $0.contains(a) && $0.contains(b) } ? 0.5 : 1
    }
}
