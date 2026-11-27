import Foundation
import WakeEngine

/// Name and wake phrase rules: a dot name is 1 to 3 plain words, and the phrase is "hey <name>" unless the user
/// sets one. Any name is allowed, including another assistant's.
enum Phrase {
    static let defaultName = "Dot"

    enum Problem: Error, Equatable, Sendable {
        case empty
        case wordCount
        case characters(String)

        /// One plain sentence for the UI.
        var message: String {
            switch self {
            case .empty: return "Give your dot a name."
            case .wordCount: return "Use one to three words."
            case .characters(let word): return "\u{201C}\(word)\u{201D} can only use letters, apostrophes or hyphens."
            }
        }
    }

    private static func isPlainWord(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "'" || $0 == "-" }
    }

    /// Validates a dot name and returns it in display form ("tray" -> "Tray").
    static func validateName(_ raw: String) -> Result<String, Problem> {
        let words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { return .failure(.empty) }
        guard (1...3).contains(words.count) else { return .failure(.wordCount) }
        if let bad = words.first(where: { !isPlainWord($0) }) { return .failure(.characters(bad)) }
        return .success(words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "))
    }

    /// The wake phrase for a valid name: lowercase "hey <name>".
    static func phrase(forName name: String) -> String {
        "hey " + name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Wake phrase

    enum WakeProblem: Error, Equatable, Sendable {
        case wordCount
        case characters(String)
        case notEncodable

        var message: String {
            switch self {
            case .wordCount: "Use two to six words, such as \u{201C}Hey Tray\u{201D}."
            case .characters(let word): "\u{201C}\(word)\u{201D} can only use the letters a to z."
            case .notEncodable: "HeyDot's speech model can't spell that phrase. Try different words."
            }
        }
    }

    /// The speech model's own tokenizer, loaded once. Nil only when the model files are missing (a broken
    /// install, reported when listening starts); letters-only phrases are then accepted.
    private static let tokenizer: KeywordTokenizer? = try? KeywordTokenizer()

    /// True when the keyword model can encode the phrase as pieces it knows.
    static func encodable(_ phrase: String) -> Bool {
        guard let tokenizer else { return true }
        return (try? tokenizer.pieces(for: phrase)).map { !$0.isEmpty } ?? false
    }

    /// Validates a wake phrase and returns it as lowercase single-spaced words ("Hey  Tray" -> "hey tray"):
    /// two to six words of the letters a to z (all the keyword model reads), encodable by the model.
    static func validateWakePhrase(_ raw: String, encodable: (String) -> Bool = Phrase.encodable) -> Result<String, WakeProblem> {
        let words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard (2...6).contains(words.count) else { return .failure(.wordCount) }
        if let bad = words.first(where: { !$0.unicodeScalars.allSatisfy { ("a"..."z").contains($0) } }) {
            return .failure(.characters(bad))
        }
        let phrase = words.joined(separator: " ")
        guard encodable(phrase) else { return .failure(.notEncodable) }
        return .success(phrase)
    }

    /// A phrase as people read it: "hey tray" -> "Hey Tray".
    static func title(_ phrase: String) -> String {
        phrase.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// A dot's conversation URL must be on https://chatgpt.com/.
    static func validateDotURL(_ raw: String) -> Result<String, URLProblem> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("https://chatgpt.com/"), let url = URL(string: value), url.host == "chatgpt.com",
              url.path.count > 1 else { return .failure(.notChatGPT) }
        return .success(value)
    }

    enum URLProblem: Error, Equatable, Sendable {
        case notChatGPT
        var message: String { "Paste your dot's conversation link. It starts with https://chatgpt.com/." }
    }
}

extension Result {
    /// Whether a validation passed.
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
