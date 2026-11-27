import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@Test func namesBecomeHeyPhrases() throws {
    #expect(try Phrase.validateName("tray").get() == "Tray")
    #expect(try Phrase.validateName("  mr  o'neil ").get() == "Mr O'neil")
    #expect(Phrase.phrase(forName: "Tray") == "hey tray")
    #expect(Phrase.phrase(forName: "Dot") == "hey dot")
}

@Test func anyNameIsAllowedButMalformedOnesAreRejected() throws {
    #expect(try Phrase.validateName("Jarvis").get() == "Jarvis")
    #expect(try Phrase.validateName("siri").get() == "Siri")
    #expect(Phrase.validateName("") == .failure(.empty))
    #expect(Phrase.validateName("a b c d") == .failure(.wordCount))
    #expect(Phrase.validateName("R2D2") == .failure(.characters("r2d2")))
    #expect(Phrase.validateName("-dot") == .failure(.characters("-dot")))
}

@Test func dotURLMustBeChatGPT() {
    #expect(Phrase.validateDotURL(" https://chatgpt.com/dots/tray ").isSuccess)
    #expect(!Phrase.validateDotURL("http://chatgpt.com/dots/tray").isSuccess)
    #expect(!Phrase.validateDotURL("https://chatgpt.com.evil.example/dots").isSuccess)
    #expect(!Phrase.validateDotURL("https://chatgpt.com/").isSuccess)
    #expect(!Phrase.validateDotURL("chatgpt.com/dots/tray").isSuccess)
}

@Test func wakePhraseRules() throws {
    #expect(try Phrase.validateWakePhrase("Okay  Tray").get() == "okay tray")
    #expect(Phrase.validateWakePhrase("tray") == .failure(.wordCount))
    #expect(Phrase.validateWakePhrase("one two three four five six seven") == .failure(.wordCount))
    #expect(Phrase.validateWakePhrase("hey tray2") == .failure(.characters("tray2")))
    #expect(Phrase.validateWakePhrase("hey o'neil") == .failure(.characters("o'neil")))
    #expect(try Phrase.validateWakePhrase("Hey Jarvis", encodable: { _ in true }).get() == "hey jarvis")
    #expect(try Phrase.validateWakePhrase("ok google play", encodable: { _ in true }).get() == "ok google play")
    #expect(Phrase.validateWakePhrase("hey tray", encodable: { _ in false }) == .failure(.notEncodable))
    #expect(Phrase.title("okay tray") == "Okay Tray")
}

@Test func wakePhraseIsEncodedByTheRealKeywordModel() throws {
    guard let dir = try? ModelFiles.locate() else { return }  // the model is fetched by Scripts/fetch-vendor.sh
    let tokenizer = try KeywordTokenizer(modelDirectory: dir)
    #expect(try !tokenizer.pieces(for: "okay tray").isEmpty)
}

@Test func wakePhraseIsIndependentOfTheName() throws {
    var s = AppSettings()
    s.rename("Tray")
    #expect(s.phrase == "hey tray" && s.wakePhrase == nil)
    s.wake.score = 1.5; s.calibrationNote = "Caught 4 of 4"
    s.setWakePhrase("okay tray")
    #expect(s.phrase == "okay tray" && s.wake.phrase == "okay tray" && s.wake.score == WakeSettings().score && s.calibrationNote == nil)
    s.calibrationNote = "tuned"
    s.rename("Sol")  // a custom phrase survives a rename, and so does its tuning
    #expect(s.phrase == "okay tray" && s.calibrationNote == "tuned" && s.dotName == "Sol")
    s.setWakePhrase("hey sol")  // the name's own phrase is stored as "follow the name"
    #expect(s.wakePhrase == nil && s.phrase == "hey sol")
    s.setWakePhrase("okay sol"); s.morningMinutes = 7 * 60 + 30
    let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}
