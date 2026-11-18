import Foundation
import CSherpa
import AVFoundation

/// Queue-confined native spotter. Owns all native handles; stream resets match the Python detector.
final class Spotter {
    let handle: OpaquePointer
    /// The token sequences spotted: the spelled phrase and spellings, then the learned sequences the model
    /// knows. Duplicates and sequences that are a prefix of another are dropped (a prefix would fire first).
    static func keywords(_ settings: WakeSettings, tokenizer: KeywordTokenizer) throws -> [[String]] {
        var all = try ([settings.phrase] + settings.spellings).map { try tokenizer.pieces(for: $0) }
        all += settings.learned.map { $0.split(separator: " ").map(String.init) }
            .filter { $0.count >= 2 && $0.allSatisfy(tokenizer.knows) }
        var unique: [[String]] = []
        for k in all where !unique.contains(k) { unique.append(k) }
        return unique.filter { k in !unique.contains { $0.count > k.count && Array($0.prefix(k.count)) == k } }
    }
    convenience init(settings: WakeSettings, directory: URL) throws {
        let tokenizer = try KeywordTokenizer(modelDirectory: directory)
        try self.init(keywords: Self.keywords(settings, tokenizer: tokenizer), score: settings.score,
                      threshold: settings.threshold, directory: directory)
    }
    init(keywords: [[String]], score: Float, threshold: Float, directory: URL) throws {
        let lines = keywords.map { $0.joined(separator: " ") + " @wake\n" }.joined()
        guard !keywords.isEmpty, score.isFinite, score > 0, threshold.isFinite,
              threshold > 0, threshold <= 1 else { throw WakeEngineError.engine("Invalid score or threshold") }
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxKeywordSpotterConfig()
        func c(_ text: String) -> UnsafePointer<CChar> {
            let ptr = strdup(text)!; strings.append(ptr); return UnsafePointer(ptr)
        }
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(directory.appendingPathComponent("encoder-\(ModelFiles.stem)").path)
        config.model_config.transducer.decoder = c(directory.appendingPathComponent("decoder-\(ModelFiles.stem)").path)
        config.model_config.transducer.joiner = c(directory.appendingPathComponent("joiner-\(ModelFiles.stem)").path)
        config.model_config.tokens = c(directory.appendingPathComponent("tokens.txt").path)
        config.model_config.provider = c("cpu"); config.model_config.num_threads = 1
        config.max_active_paths = 4; config.num_trailing_blanks = 1
        config.keywords_score = score; config.keywords_threshold = threshold
        config.keywords_buf = c(lines); config.keywords_buf_size = Int32(lines.utf8.count)
        let onDisk = ["encoder", "decoder", "joiner"].reduce(0) { sum, part in
            let path = directory.appendingPathComponent("\(part)-\(ModelFiles.stem)").path
            return sum + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        }
        guard let handle = ListenerMeter.loadingModel(filesOnDisk: onDisk, { SherpaOnnxCreateKeywordSpotter(&config) }) else {
            ListenerMeter.unloadedModel()
            throw WakeEngineError.engine("sherpa-onnx could not load keyword model")
        }
        self.handle = handle
    }
    deinit { SherpaOnnxDestroyKeywordSpotter(handle); ListenerMeter.unloadedModel() }
    func stream() throws -> OpaquePointer {
        guard let s = SherpaOnnxCreateKeywordStream(handle) else { throw WakeEngineError.engine("Cannot create keyword stream") }
        return s
    }
    func accept(_ samples: Clip, stream: OpaquePointer) -> Int {
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
        var hits = 0
        while SherpaOnnxIsKeywordStreamReady(handle, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(handle, stream)
            if let result = SherpaOnnxGetKeywordResult(handle, stream) {
                if let keyword = result.pointee.keyword, keyword.pointee != 0 {
                    hits += 1; SherpaOnnxResetKeywordStream(handle, stream)
                }
                SherpaOnnxDestroyKeywordResult(result)
            }
        }
        return hits
    }
    /// Whether `keywords` fire in `clip` at `threshold`, on a throwaway stream that shares this model.
    /// The spotter's own keywords are appended to every stream by sherpa-onnx, so only hits on these count.
    func fires(_ clip: Clip, keywords: [[String]], score: Float, threshold: Float) -> Bool {
        let text = keywords.map { $0.joined(separator: " ") + " :\(score) #\(threshold) @probe" }.joined(separator: "\n")
        guard let s = SherpaOnnxCreateKeywordStreamWithKeywords(handle, text) else { return false }
        defer { SherpaOnnxDestroyOnlineStream(s) }
        let audio = Clip(repeating: 0, count: 8000) + clip + Clip(repeating: 0, count: 8000)
        audio.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(s, 16000, $0.baseAddress, Int32($0.count)) }
        while SherpaOnnxIsKeywordStreamReady(handle, s) != 0 {
            SherpaOnnxDecodeKeywordStream(handle, s)
            guard let result = SherpaOnnxGetKeywordResult(handle, s) else { continue }
            defer { SherpaOnnxDestroyKeywordResult(result) }
            if let keyword = result.pointee.keyword, String(cString: keyword) == "probe" { return true }
        }
        return false
    }
    /// The highest threshold at which `keywords` still fire in `clip`, searched between `low` (known to
    /// fire) and `high`. Firing is monotonic in the threshold (the search does not depend on it), so a
    /// bisection finds it; five steps over 0.01 to 0.75 resolve about 0.023, under `Enroller.margin`.
    func confidence(_ clip: Clip, keywords: [[String]], score: Float, low: Float = 0.01, high: Float = 0.75) -> Float {
        var low = low, high = high
        while high - low > 0.025 {
            let mid = (low + high) / 2
            if fires(clip, keywords: keywords, score: score, threshold: mid) { low = mid } else { high = mid }
        }
        return low
    }
    /// The lowest confidence among the clips that fire at all (nil if none do), and how many fire. Each clip
    /// after the first costs one decode unless it is weaker than the weakest so far.
    func weakest(_ clips: [Clip], keywords: [[String]], score: Float) -> (Float?, Int) {
        var weakest: Float?, firing = 0
        for clip in clips where fires(clip, keywords: keywords, score: score, threshold: 0.01) {
            firing += 1
            if let w = weakest, fires(clip, keywords: keywords, score: score, threshold: w) { continue }
            weakest = confidence(clip, keywords: keywords, score: score, high: weakest ?? 0.75)
        }
        return (weakest, firing)
    }
    /// The highest confidence among the clips (0 if none fire); each costs one decode unless it is stronger.
    func strongest(_ clips: [Clip], keywords: [[String]], score: Float) -> Float {
        var strongest: Float = 0
        for clip in clips where fires(clip, keywords: keywords, score: score, threshold: max(0.01, strongest + 0.025)) {
            strongest = confidence(clip, keywords: keywords, score: score, low: max(0.01, strongest + 0.025))
        }
        return strongest
    }
    func detect(_ clip: Clip, padding: Bool = true) throws -> Int {
        let s = try stream(); defer { SherpaOnnxDestroyOnlineStream(s) }
        var hits = 0
        if padding { hits += accept(Clip(repeating: 0, count: 16000), stream: s) }
        for offset in stride(from: 0, to: clip.count, by: 1280) {
            hits += accept(Array(clip[offset..<min(offset + 1280, clip.count)]), stream: s)
        }
        if padding { hits += accept(Clip(repeating: 0, count: 16000), stream: s) }
        return hits
    }
}

/// Offline path shared by the CLI and deterministic tests. No microphone or cooldown.
public enum OfflineDetector {
    public static func detections(in clip: Clip, settings: WakeSettings = WakeSettings()) throws -> Int {
        try Spotter(settings: settings, directory: ModelFiles.locate()).detect(clip)
    }
    public static func readWAV(_ url: URL) throws -> Clip {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw WakeEngineError.engine("Expected 16 kHz mono WAV")
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw WakeEngineError.engine("Cannot decode WAV") }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
