import Foundation
import CSherpa

/// The keyword model run as a plain streaming recognizer, only while voice tuning (never by the listener).
/// It reports which tokens the model itself hears in a sample. A rare name such as "Luminaropolis" is
/// spelled `▁JE FF HA LO PO U LO S` by the tokenizer, but the model hears `▁LU MI NA ▁RO PO LI S`;
/// the spotter matches exact token paths, so only the heard sequence can ever fire. Calibration stores
/// those sequences as extra keywords (`WakeSettings.learned`), and tuning uses the heard words to tell the
/// user truthfully whether a sample was the phrase.
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

/// What a tuning sample sounded like, judged against the wake phrase from the words the model heard.
public enum Hearing: Equatable, Sendable {
    /// The wake phrase.
    case phrase
    /// The first word, then a different name ("Hey John" for "Hey Luminaropolis"); carries the heard words.
    case otherName(String)
    /// The name, or something else, without the phrase's first word.
    case missingStart(String)
    /// Nothing the model could make words of.
    case nothing

    /// Heard words ("HEY LUMINA ROPOLIS"), letters only ("DON'T" is "DONT").
    static func words(_ pieces: [String]) -> [String] {
        pieces.joined().split(separator: "▁").map { String($0.filter(\.isLetter)) }.filter { !$0.isEmpty }
    }

    /// Spelling-of-sound normalization so vowels can count: "TRAY", "TRAY" and "TRAI" all become "TRA" while
    /// "TROY" becomes "TROI"; doubled letters collapse ("JEFF" is "JEF"); TH is T (accents that stop it: "THREE").
    static func sound(_ word: String) -> String {
        var s = word.uppercased()
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

    /// Compares what was heard with the phrase, using a sound-alike edit distance on the letters after the
    /// first word. The bar is stricter for short names, where one sound changes the name ("Ray" for "Tray"),
    /// and looser for long rare names, which the model spells loosely ("Lumina Ropolis").
    public static func judge(heard pieces: [String], phrase: String) -> Hearing { match(heard: pieces, phrase: phrase).hearing }

    /// Whether calibration may learn this sample's tokens as a keyword. For a short name (bar 0.7) the match must be
    /// clear and start with the same sound: "HEY DONT" (0.75) for "hey dot" would teach a sequence that fires on
    /// "hey don", and "HEY DRAY" for "hey tray" one that fires on "hey dre". Long names are learned at the bar.
    static func learnable(heard pieces: [String], phrase: String) -> Bool {
        let m = match(heard: pieces, phrase: phrase)
        guard m.hearing == .phrase else { return false }
        return m.bar < 0.7 || (m.similarity >= 0.76 && m.name.first == m.target.first)
    }

    private static func match(heard pieces: [String], phrase: String)
        -> (hearing: Hearing, similarity: Double, bar: Double, name: String, target: String) {
        let target = phrase.uppercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let heard = words(pieces)
        guard let first = target.first, !heard.isEmpty else { return (.nothing, 0, 1, "", "") }
        let rest = target.dropFirst().joined()
        let text = heard.joined(separator: " ")
        guard !rest.isEmpty else {
            let score = similarity(sound(heard.joined()), sound(first))
            return (score >= 0.7 ? .phrase : .missingStart(text), score, 0.7, "", "")
        }
        // The start may be its own word ("HEY TRAY") or merged into the name ("HAYDRAY").
        var name: String?
        if heard.count >= 2, similarity(heard[0], first) >= 0.5 { name = heard.dropFirst().joined() }
        else {
            let joined = heard.joined()
            if joined.count > first.count, similarity(String(joined.prefix(first.count)), first) >= 0.5 { name = String(joined.dropFirst(first.count)) }
        }
        guard let name else { return (.missingStart(text), 0, 1, "", "") }
        let want = sound(rest)
        let bar = min(0.7, max(0.5, 0.8 - 0.02 * Double(want.count)))
        let heardName = sound(name), score = similarity(heardName, want)
        return (score >= bar ? .phrase : .otherName(text), score, bar, heardName, want)
    }

    /// 1 minus a weighted edit distance over the longer length. Vowels, and voiced/unvoiced pairs such as
    /// D and T, cost half a substitution (after `sound`, so a different vowel sound still costs).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.uppercased()), y = Array(b.uppercased())
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
