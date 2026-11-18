import Foundation

/// The `--control` command line: pure parsing, shared by the local CLI and the SSH forced command.
///
///     HeyDot --control status|pause [--until ISO8601]|resume [--json]
///     HeyDot --control-ssh      (SSH forced command: runs only an allowed verb from $SSH_ORIGINAL_COMMAND)
public enum WakeControl {
    public enum Verb: Equatable, Sendable {
        case status
        case pause(until: Date?)
        case resume
    }

    public struct Command: Equatable, Sendable {
        public var verb: Verb
        public var json: Bool
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case usage(String)
        case refused(String)
        public var description: String {
            switch self { case .usage(let m), .refused(let m): m }
        }
    }

    public static let usage = "usage: HeyDot --control status|pause [--until ISO8601]|resume [--json]"

    /// Parses the words after `--control`.
    public static func parse(_ words: [String], now: Date = Date()) -> Result<Command, Failure> {
        var words = words
        var json = false
        if words.last == "--json" { json = true; words.removeLast() }
        switch words.first {
        case "status" where words.count == 1: return .success(Command(verb: .status, json: json))
        case "resume" where words.count == 1: return .success(Command(verb: .resume, json: json))
        case "pause" where words.count == 1: return .success(Command(verb: .pause(until: nil), json: json))
        case "pause" where words.count == 3 && words[1] == "--until":
            guard let until = parseTime(words[2]) else {
                return .failure(.usage("--until takes an ISO 8601 time such as 2026-11-15T07:00"))
            }
            guard until > now else { return .failure(.usage("--until \(words[2]) is not in the future")) }
            return .success(Command(verb: .pause(until: until), json: json))
        default: return .failure(.usage(usage))
        }
    }

    /// The allowlist for an SSH forced command. Allows only `status`, `pause`, `pause --until ISO8601` and
    /// `resume`, each with an optional `--json`, after an optional `<path>/HeyDot --control` prefix (the
    /// client's configured command, never executed). Any shell syntax, other verb or no command at all
    /// (an interactive login) is refused.
    public static func sshWords(_ original: String?) -> Result<[String], Failure> {
        let refused = Failure.refused("only `status`, `pause [--until ISO8601]` and `resume` (optionally `--json`) are allowed")
        guard let original, !original.isEmpty,
              original.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }) else { return .failure(refused) }
        var words = original.split(separator: " ").map(String.init)
        if words.count >= 2, (words[0] as NSString).lastPathComponent == "HeyDot", words[1] == "--control" {
            words.removeFirst(2)
        }
        let verbs = words.last == "--json" ? Array(words.dropLast()) : words
        let allowed = verbs == ["status"] || verbs == ["pause"] || verbs == ["resume"]
            || (verbs.count == 3 && verbs[0] == "pause" && verbs[1] == "--until" && parseTime(verbs[2]) != nil)
        return allowed ? .success(words) : .failure(refused)
    }

    private static let allowedScalars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ./:+-_")

    private static let timePattern =
        #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,6})?)?(Z|[+-]\d{2}:\d{2})?$"#

    /// ISO 8601 date and time, to the minute or second; local time when it has no offset.
    public static func parseTime(_ text: String, timeZone: TimeZone = .current) -> Date? {
        guard let match = try? Regex(timePattern).wholeMatch(in: text) else { return nil }
        func int(_ i: Int) -> Int? { (match.output[i].substring).flatMap { Int($0) } }
        var zone = timeZone
        if let offset = match.output[7].substring {
            if offset == "Z" { zone = TimeZone(secondsFromGMT: 0)! } else {
                let sign = offset.hasPrefix("-") ? -1 : 1
                let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, parts[0] < 24, parts[1] < 60,
                      let z = TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60)) else { return nil }
                zone = z
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: int(1), month: int(2), day: int(3), hour: int(4), minute: int(5), second: int(6) ?? 0)
        guard let date = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            == DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: parts.hour, minute: parts.minute)
        else { return nil }  // rejects 2026-02-30 and 25:00 instead of rolling them over
        return date
    }

    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
