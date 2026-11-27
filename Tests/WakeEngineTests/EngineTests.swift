import Foundation
import Testing
@testable import WakeEngine

private func configureModel() {
    // Tests run without microphone, network, or an app bundle. fetch-vendor.sh provisions this.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    setenv("HEYDOT_MODEL_DIR", root.appendingPathComponent("Vendor/models").path, 1)
}
private func fixture(_ name: String) throws -> Clip {
    try OfflineDetector.readWAV(#require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures")))
}

@Suite(.serialized) struct EngineTests {
    init() { configureModel() }
    @Test func sentencePieceParity() throws {
        let tokenizer = try KeywordTokenizer()
        let cases = [
            "hey dot": ["▁HE", "Y", "▁DO", "T"],
                        "hey tray": ["▁HE", "Y", "▁TRA", "Y"],
            "hey jarvis": ["▁HE", "Y", "▁JA", "R", "VI", "S"],
            "hey nova": ["▁HE", "Y", "▁NO", "V", "A"]
        ]
        for (phrase, pieces) in cases { let actual = try tokenizer.pieces(for: phrase); print("TOKENS \(phrase): \(actual)"); #expect(actual == pieces) }
        for invalid in ["", "   ", "hey 🦊", "hey 123", "hey @wake"] {
            #expect(throws: WakeEngineError.self) { try tokenizer.pieces(for: invalid) }
        }
    }
    @Test func offlineParity() throws {
        for phrase in ["hey dot", "hey tray"] {
            let spotter = try Spotter(settings: WakeSettings(phrase: phrase), directory: ModelFiles.locate())
            for voice in ["Samantha", "Daniel", "Karen"] {
                let name = phrase.replacingOccurrences(of: " ", with: "-") + "-" + voice
                #expect(try spotter.detect(fixture(name)) == 1, "\(name)")
                let other = (phrase == "hey dot" ? "hey-tray-" : "hey-dot-") + voice
                #expect(try spotter.detect(fixture(other)) == 0, "\(other)")
            }
            for name in ["hey-jarvis", "hey-there"] { #expect(try spotter.detect(fixture(name)) == 0, "\(name)") }
        }
    }
    @Test func calibration() async throws {
        var positives = try ["Samantha", "Daniel", "Karen"].map { try fixture("hey-tray-" + $0) }
        positives += [positives[0], positives[1]]
        positives = positives.map { Array($0.prefix(32000)) + Clip(repeating: 0, count: max(0, 32000 - $0.count)) }
        let negatives = try ["hey-jarvis", "hey-there", "hey-dot-Samantha"].map { try fixture($0) }
            .map { Array($0.prefix(32000)) + Clip(repeating: 0, count: max(0, 32000 - $0.count)) }
        let start = ContinuousClock.now
        let result = try await Enroller().calibrate(phrase: "hey tray", positives: positives, negatives: negatives)
        let duration = start.duration(to: .now)
        print("CALIBRATION \(duration) score=\(result.settings.score) threshold=\(result.settings.threshold) caught=\(result.caught) falseHits=\(result.falseHits)")
        #expect(result.caught == 5)
        #expect(result.falseHits == 0)
        #expect(duration < .seconds(2))
    }
    @Test func segmenterSplitsUtterancesForTuning() throws {
        // Live tuning feeds ~43 ms buffers; two utterances separated by a second of silence must come
        // out as two clips, each a plausible take.
        let silence = Clip(repeating: 0, count: 16000)
        let stream = silence + (try fixture("hey-tray-Samantha")) + silence + (try fixture("hey-there")) + silence
        var segmenter = UtteranceSegmenter()
        var clips: [Clip] = []
        for offset in stride(from: 0, to: stream.count, by: 683) {
            clips += segmenter.feed(Array(stream[offset..<min(offset + 683, stream.count)]))
        }
        #expect(clips.count == 2)
        #expect(segmenter.heardSound)
        let decoder = try PhraseDecoder(directory: ModelFiles.locate())
        for clip in clips { #expect(Takes.problem(Utterance(clip: clip, heard: decoder.pieces(clip)), phrase: "hey tray") == nil) }
    }

    @Test func tuningKeepsFastPhraseBeforePrerollFills() throws {
        let phrase = try fixture("hey-dot-Daniel-320")
        let pad = Clip(repeating: 0, count: 16000)
        let decoder = try PhraseDecoder(directory: ModelFiles.locate())
        for audio in [phrase + pad, pad + phrase + pad] {
            var segmenter = UtteranceSegmenter()
            var clips: [Clip] = []
            for offset in stride(from: 0, to: audio.count, by: 683) {
                clips += segmenter.feed(Array(audio[offset..<min(offset + 683, audio.count)]))
            }
            #expect(clips.count == 1)
            for clip in clips {
                #expect(Takes.problem(Utterance(clip: clip, heard: decoder.pieces(clip)), phrase: "hey dot") == nil)
            }
        }
    }

    /// A neutral synthetic rare-name regression: the user's takes agree and "Hey John" stays out of them,
    /// calibration learns the heard tokens, then a held-out wake utterance fires without answering confusables.
    /// The alternate spelling Lumynaropolis deliberately differs from the synthetic spoken name Luminaropolis.
    @Test func heyJohnIsNotHeyLuminaropolis() async throws {
        let phrase = "hey lumynaropolis"
        let decoder = try PhraseDecoder(directory: ModelFiles.locate())
        let john = try ["hey-john-Daniel", "hey-john-Samantha"].map(fixture)
        let confusables = try john + ["hey-jeff-Daniel", "luminaropolis-Daniel", "hey-there", "hey-tray-Daniel"].map(fixture)
        let enrolled = try [150, 165, 195].map { try fixture("hey-luminaropolis-Daniel-\($0)") }
        let takes = [enrolled[0], john[0], enrolled[1], enrolled[2]].map(decoder.pieces)
        #expect(Takes.agreeing(takes) == [0, 2, 3], "Hey John is not one of the user's takes")
        let heldOut = try fixture("hey-luminaropolis-Daniel-170")

        let standard = try Spotter(settings: WakeSettings(phrase: phrase), directory: ModelFiles.locate())
        #expect(try standard.detect(heldOut) == 0, "root cause: the spelled tokens never match what the model hears")

        let result = try await Enroller().calibrate(phrase: phrase, positives: enrolled, negatives: [john[0]])
        print("RARE caught=\(result.caught) false=\(result.falseHits) threshold=\(result.settings.threshold) learned=\(result.settings.learned)")
        #expect(!result.settings.learned.isEmpty && result.caught == 3 && result.falseHits == 0)
        let tuned = try Spotter(settings: result.settings, directory: ModelFiles.locate())

        #expect(try tuned.detect(heldOut) > 0)
        for clip in confusables { #expect(try tuned.detect(clip) == 0) }
    }

    /// Rushed "Hey Trey" (no pause after "hey") must wake on standard settings. The spotter fires only on an exact
    /// token path, and the spelled `▁T RE Y` is not what the model hears for "Trey" (`▁TRA Y`, rushed `▁DR A Y` or
    /// `▁HA T RE Y`); a careful T after a pause can still be pulled onto the spelled path, a rushed one cannot.
    @Test func rushedHeyTreyWakesOnStandardSettings() throws {
        let spotter = try Spotter(settings: WakeSettings(phrase: "hey trey"), directory: ModelFiles.locate())
        for name in ["hey-trey-Karen-340", "hey-trey-Daniel-300"] { #expect(try spotter.detect(fixture(name)) == 1, "\(name)") }
        for name in ["hey-there", "hey-jarvis", "hey-john-Daniel", "hey-jeff-Daniel", "hey-dot-Karen"] {
            #expect(try spotter.detect(fixture(name)) == 0, "\(name)")
        }
    }

    /// Takes are compared with each other by sound, never with the spelling, and word breaks don't matter.
    @Test func takesAgreeByHowTheySound() {
        func heard(_ text: String) -> [String] { text.split(separator: " ").map { "▁" + $0 } }
        // One speaker's "Hey Trey", careful and rushed, as the model hears it.
        let trey = ["HEY TRAY", "HA T RE Y", "HEY DRAY", "HEY TREE"].map(heard)
        #expect(Takes.agreeing(trey) == [0, 1, 2, 3])
        #expect(Takes.agreeing([heard("HEY JOHN")] + trey) == [1, 2, 3, 4], "a stray first take drops out")
        #expect(Takes.agreeing(trey + [heard("HEY JOHN"), heard("TRAY")]) == [0, 1, 2, 3])
        // A speaker the model always hears as "Page Ray" agrees with themselves.
        #expect(Takes.agreeing(["P AGE RA Y", "PA ID RA Y", "P AGE RA Y"].map { $0.split(separator: " ").map(String.init) }).count == 3)
        // Only a reading the user repeats is theirs; one "HEY DRAY" among "HEY TRAY"s is a mishearing.
        #expect(Takes.repeated(heard("HEY TRAY"), among: trey + [heard("HEY TRAY")]) && !Takes.repeated(heard("HEY DRAY"), among: trey))
        func problem(_ text: String, peak: Float = 0.3) -> Takes.Problem? {
            Takes.problem(Utterance(clip: [peak] + Clip(repeating: 0, count: 15999), heard: heard(text)), phrase: "hey trey")
        }
        #expect(problem("HEY TRAY") == nil && problem("HEY A TREE") == nil)
        #expect(problem("") == .nothing && problem("", peak: 0.01) == .quiet)
        #expect(problem("I M MAKING A CUP OF COFFEE") == .long)
    }

    @Test func thresholdKeepsAMarginFromEveryRecordedNegative() {
        #expect(abs(Enroller.threshold(weakest: 0.3, worst: 0) - 0.12) < 0.001)
        #expect(Enroller.threshold(weakest: 0.4, worst: 0.2) >= 0.2 + Enroller.margin)
        // Overlap: a recorded confusable is never answered, even at the cost of a positive.
        #expect(Enroller.threshold(weakest: 0.2, worst: 0.25) > 0.25)
        #expect(Enroller.threshold(weakest: 0.04, worst: 0) <= 0.04)
        #expect(Enroller.threshold(weakest: nil, worst: 0.1) > 0.1)
    }

    @Test func settingsSavedBeforeLearningStillDecode() throws {
        let old = #"{"phrase":"hey tray","spellings":["hey tray"],"score":2,"threshold":0.08}"#
        let settings = try JSONDecoder().decode(WakeSettings.self, from: Data(old.utf8))
        #expect(settings == WakeSettings(phrase: "hey tray", spellings: ["hey tray"]))
        let learned = WakeSettings(phrase: "hey tray", learned: ["▁HE Y ▁TRA Y"])
        #expect(try JSONDecoder().decode(WakeSettings.self, from: JSONEncoder().encode(learned)) == learned)
        // A stored sequence with a piece the model doesn't have is ignored, not fatal.
        let keywords = try Spotter.keywords(WakeSettings(phrase: "hey tray", learned: ["▁HE Y ▁NOT_A_PIECE", "▁HE Y ▁TRA Y"]), tokenizer: KeywordTokenizer())
        #expect(keywords.first == ["▁HE", "Y", "▁TRA", "Y"] && !keywords.contains { $0.contains("▁NOT_A_PIECE") })
    }
}
