import Foundation

/// SentencePiece unigram encoding for the pinned English model (despite its bpe.model filename).
/// Viterbi search maximizes the sum of piece scores from ModelProto, matching SentencePiece.
/// English letters and whitespace only: no approximate Unicode normalization or unknown pieces.
public struct KeywordTokenizer: Sendable {
    private let scores: [String: Float]
    public init(modelDirectory: URL? = nil) throws {
        let directory = try modelDirectory ?? ModelFiles.locate()
        var proto = Proto(try Data(contentsOf: directory.appendingPathComponent("bpe.model")))
        var scores: [String: Float] = [:]
        while let field = try proto.next() {
            guard field.number == 1, let bytes = field.bytes else { continue }
            var piece = Proto(bytes), text = "", score: Float = 0, type: UInt64 = 1
            while let f = try piece.next() {
                if f.number == 1, let b = f.bytes { text = String(decoding: b, as: UTF8.self) }
                if f.number == 2 { score = Float(bitPattern: UInt32(f.value)) }
                if f.number == 3 { type = f.value }
            }
            if type == 1 { scores[text] = score }
        }
        guard !scores.isEmpty else { throw WakeEngineError.engine("Empty BPE model") }
        self.scores = scores
    }
    /// Whether the model has this piece (validates stored learned sequences before they reach the spotter).
    func knows(_ piece: String) -> Bool { scores[piece] != nil }
    /// The unigram log probability of a piece sequence: how commonly the model writes it.
    func likelihood(_ pieces: [String]) -> Float { pieces.reduce(0) { $0 + (scores[$1] ?? -.infinity) } }
    public func pieces(for phrase: String) throws -> [String] {
        guard phrase.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || (65...90).contains($0.value) || (97...122).contains($0.value) }) else {
            throw WakeEngineError.invalidPhrase(phrase)
        }
        let words = phrase.uppercased().split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { throw WakeEngineError.invalidPhrase(phrase) }
        let symbols = Array(("▁" + words.joined(separator: "▁")).map(String.init))
        var best = [Float](repeating: -.infinity, count: symbols.count + 1)
        var previous = [Int](repeating: -1, count: symbols.count + 1)
        best[0] = 0
        for end in 1...symbols.count {
            for start in 0..<end where best[start].isFinite {
                let piece = symbols[start..<end].joined()
                if let score = scores[piece], best[start] + score > best[end] {
                    best[end] = best[start] + score; previous[end] = start
                }
            }
        }
        guard best[symbols.count].isFinite else { throw WakeEngineError.invalidPhrase(phrase) }
        var pieces: [String] = [], end = symbols.count
        while end > 0 {
            let start = previous[end]
            pieces.append(symbols[start..<end].joined()); end = start
        }
        return pieces.reversed()
    }
}

// Minimal bounds-checked protobuf wire reader. No generated schema or runtime dependency.
private struct Proto {
    struct Field { let number: Int; let value: UInt64; let bytes: Data? }
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw WakeEngineError.engine("Truncated BPE protobuf") }
            let b = data[offset]; offset += 1
            value |= UInt64(b & 127) << shift
            if b < 128 { return value }
        }
        throw WakeEngineError.engine("Invalid BPE protobuf")
    }
    mutating func next() throws -> Field? {
        if offset == data.count { return nil }
        let key = try varint(), number = Int(key >> 3)
        switch key & 7 {
        case 0: return Field(number: number, value: try varint(), bytes: nil)
        case 1, 5:
            let size = key & 7 == 1 ? 8 : 4
            guard offset + size <= data.count else { throw WakeEngineError.engine("Truncated BPE field") }
            var value: UInt64 = 0
            for i in 0..<size { value |= UInt64(data[offset + i]) << (i * 8) }
            offset += size
            return Field(number: number, value: value, bytes: nil)
        case 2:
            let n = try varint()
            guard n <= UInt64(data.count - offset) else { throw WakeEngineError.engine("Truncated BPE message") }
            let bytes = data.subdata(in: offset..<(offset + Int(n))); offset += Int(n)
            return Field(number: number, value: 0, bytes: bytes)
        default: throw WakeEngineError.engine("Unsupported BPE protobuf field")
        }
    }
}

public enum ModelFiles {
    public static let name = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
    static let stem = "epoch-12-avg-2-chunk-16-left-64.int8.onnx"
    public static func locate() throws -> URL {
        let env = ProcessInfo.processInfo.environment["HEYDOT_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let roots = env.map { [$0] } ?? [Bundle.main.resourceURL, Bundle.main.resourceURL?.appendingPathComponent("models")].compactMap { $0 }
        for root in roots {
            for dir in [root, root.appendingPathComponent(name)] {
                let files = ["tokens.txt", "bpe.model"] + ["encoder", "decoder", "joiner"].map { "\($0)-\(stem)" }
                if files.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) { return dir }
            }
        }
        throw WakeEngineError.modelMissing("Place \(name) in app Resources or set HEYDOT_MODEL_DIR.")
    }
}
