import Foundation

/// What a press or check attempt meant (`outcome`, from `PageScripts.press` or the backend), in words for the UI.
struct CallResult: Sendable, Equatable {
    let outcome: String
    let message: String
    let wakeToPressMs: Int?

    var pressed: Bool { outcome == "pressed" }
    var wouldPress: Bool { outcome == "would-press" }

    /// The one message table for call outcomes, plus the backend's own reasons a call ended (`in-call`,
    /// `no-mic`, `crashed`).
    static func describe(_ outcome: String) -> String {
        switch outcome {
        case "pressed": "Call started."
        case "would-press": "Ready. HeyDot found your dot's call button and left it alone."
        case "signed-out": "HeyDot isn't signed in to ChatGPT. Sign in again from Settings."
        case "challenge": "chatgpt.com wants to check it's you. Open the sign-in window from Settings and finish it there."
        case "not-found": "Couldn't find the call button on your dot's page. Nothing was pressed."
        case "wrong-dot": "Your dot's page didn't open (it went somewhere else). Check the dot link in Settings."
        case "ambiguous": "More than one call button is showing, so HeyDot didn't press anything."
        case "disabled": "The call button is off, probably because a call is already running."
        case "in-call": "A call is already running."
        case "hidden": "macOS didn't let HeyDot's call window become active in time. Nothing was pressed."
        case "load-failed": "Couldn't load your dot's page. Check the internet connection."
        case "timeout": "Your dot's page didn't finish loading in time. Nothing was pressed."
        case "no-mic": "The call started but the microphone never opened, so HeyDot ended it."
        case "crashed": "The ChatGPT page stopped, so the call ended."
        case "no-dot": "Pick your dot's conversation first."
        default: "Something went wrong, so nothing was pressed."
        }
    }

    init(outcome: String, message: String? = nil, wakeToPressMs: Int? = nil) {
        self.outcome = outcome
        self.message = message ?? Self.describe(outcome)
        self.wakeToPressMs = wakeToPressMs
    }
}
