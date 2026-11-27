import Foundation

/// What a press attempt meant, in words for the popover. Mirrors adapters.PRESS_FAILURES.
public struct CallResult: Sendable, Equatable {
    public let outcome: String
    public let message: String
    public let wakeToPressMs: Int?

    public var pressed: Bool { outcome == "pressed" }
    public var wouldPress: Bool { outcome == "would-press" }

    public static func describe(_ outcome: String) -> String {
        switch outcome {
        case "pressed": return "Call started."
        case "would-press": return "Ready. HeyDot found your dot's call button and left it alone."
        case "not-found": return "Couldn't find the call button. Open your dot in ChatGPT once and try again."
        case "ambiguous": return "More than one call button is showing, so HeyDot didn't press anything."
        case "wrong-dot": return "That tab shows a different conversation. Nothing was pressed."
        case "disabled": return "The call button is off, probably because a call is already running."
        case "challenge": return "chatgpt.com is showing a check. Open ChatGPT and finish it."
        case "timeout": return "The page didn't answer in time. Nothing was pressed."
        case "no-dot": return "Pick your dot's conversation first."
        default: return "Something went wrong, so nothing was pressed."
        }
    }

    public init(outcome: String, message: String? = nil, wakeToPressMs: Int? = nil) {
        self.outcome = outcome
        self.message = message ?? Self.describe(outcome)
        self.wakeToPressMs = wakeToPressMs
    }
}
