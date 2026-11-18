import Foundation
import WakeEngine

/// Name and wake phrase rules, matching dots_voice_wake/config.py: a dot name is 1 to 3 plain words,
/// the phrase is "hey <name>", and no word may collide with another assistant's wake word.
public enum Phrase {
    public static let defaultName = "Dot"
    public static let reservedWords: Set<String> = ["jarvis"]

    public enum Problem: Error, Equatable, Sendable {
        case empty
        case wordCount
        case characters(String)
        case reserved(String)

        /// One plain sentence for the UI.
        public var message: String {
            switch self {
            case .empty: return "Give your dot a name."
            case .wordCount: return "Use one to three words."
            case .characters(let word): return "\u{201C}\(word)\u{201D} can only use letters, apostrophes or hyphens."
            case .reserved(let word):
                return "\u{201C}\(word.capitalized)\u{201D} is another assistant's wake word on this Mac. Pick a different name."
            }
        }
    }

    private static func isPlainWord(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "'" || $0 == "-" }
    }

    /// Validates a dot name and returns it in display form ("tray" -> "Tray").
    public static func validateName(_ raw: String) -> Result<String, Problem> {
        let words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { return .failure(.empty) }
        guard (1...3).contains(words.count) else { return .failure(.wordCount) }
        if let bad = words.first(where: { !isPlainWord($0) }) { return .failure(.characters(bad)) }
        if let clash = words.first(where: reservedWords.contains) { return .failure(.reserved(clash)) }
        return .success(words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "))
    }

    /// The wake phrase for a valid name: lowercase "hey <name>".
    public static func phrase(forName name: String) -> String {
        "hey " + name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Wake phrase

    /// Words and phrases that belong to other assistants on a Mac or nearby devices. A wake phrase containing
    /// any of them could fire HeyDot and the other assistant together.
    public static let reservedWakeWords: Set<String> = ["jarvis", "siri", "alexa", "cortana"]
    public static let reservedWakePhrases = ["hey google", "ok google", "okay google"]

    public enum WakeProblem: Error, Equatable, Sendable {
        case wordCount
        case characters(String)
        case reserved(String)
        case notEncodable

        public var message: String {
            switch self {
            case .wordCount: "Use two to six words, such as \u{201C}Hey Tray\u{201D}."
            case .characters(let word): "\u{201C}\(word)\u{201D} can only use the letters a to z."
            case .reserved(let phrase): "\u{201C}\(title(phrase))\u{201D} wakes another assistant. Pick a different wake phrase."
            case .notEncodable: "HeyDot's speech model can't spell that phrase. Try different words."
            }
        }
    }

    /// The speech model's own tokenizer, loaded once. Nil only when the model files are missing (a broken
    /// install, reported when listening starts); letters-only phrases are then accepted.
    private static let tokenizer: KeywordTokenizer? = try? KeywordTokenizer()

    /// True when the keyword model can encode the phrase as pieces it knows.
    public static func encodable(_ phrase: String) -> Bool {
        guard let tokenizer else { return true }
        return (try? tokenizer.pieces(for: phrase)).map { !$0.isEmpty } ?? false
    }

    /// Validates a wake phrase and returns it as lowercase single-spaced words ("Hey  Tray" -> "hey tray"):
    /// two to six words of the letters a to z (all the keyword model reads), none of them another assistant's
    /// wake word, and encodable by the model.
    public static func validateWakePhrase(_ raw: String, encodable: (String) -> Bool = Phrase.encodable) -> Result<String, WakeProblem> {
        let words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard (2...6).contains(words.count) else { return .failure(.wordCount) }
        if let bad = words.first(where: { !$0.unicodeScalars.allSatisfy { ("a"..."z").contains($0) } }) {
            return .failure(.characters(bad))
        }
        let phrase = words.joined(separator: " ")
        if let word = words.first(where: reservedWakeWords.contains) { return .failure(.reserved(word)) }
        if let clash = reservedWakePhrases.first(where: { (" " + phrase + " ").contains(" " + $0 + " ") }) {
            return .failure(.reserved(clash))
        }
        guard encodable(phrase) else { return .failure(.notEncodable) }
        return .success(phrase)
    }

    /// A phrase as people read it: "hey tray" -> "Hey Tray".
    public static func title(_ phrase: String) -> String {
        phrase.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// A dot's conversation URL must be on https://chatgpt.com/ (config.py rule).
    public static func validateDotURL(_ raw: String) -> Result<String, URLProblem> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("https://chatgpt.com/"), let url = URL(string: value), url.host == "chatgpt.com",
              url.path.count > 1 else { return .failure(.notChatGPT) }
        return .success(value)
    }

    public enum URLProblem: Error, Equatable, Sendable {
        case notChatGPT
        public var message: String { "Paste your dot's conversation link. It starts with https://chatgpt.com/." }
    }
}
