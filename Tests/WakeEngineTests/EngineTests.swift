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
        // out as two clips, and the lenient preview must hear the phrase only in the first.
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
        #expect(Hearing.judge(heard: decoder.pieces(clips[0]), phrase: "hey tray") == .phrase)
        #expect(Hearing.judge(heard: decoder.pieces(clips[1]), phrase: "hey tray") != .phrase)
    }

    /// A neutral synthetic rare-name regression: reject a different name, learn heard tokens,
    /// then catch a held-out wake utterance without answering confusables. The alternate spelling
    /// Lumynaropolis deliberately differs from the synthetic spoken name Luminaropolis.
    @Test func heyJohnIsNotHeyLuminaropolis() async throws {
        let phrase = "hey lumynaropolis"
        let decoder = try PhraseDecoder(directory: ModelFiles.locate())
        let john = try ["hey-john-Daniel", "hey-john-Samantha"].map(fixture)
        let confusables = try john + ["hey-jeff-Daniel", "luminaropolis-Daniel", "hey-there", "hey-tray-Daniel"].map(fixture)
        for clip in john {
            guard case .otherName = Hearing.judge(heard: decoder.pieces(clip), phrase: phrase) else { Issue.record("Hey John heard as \(Hearing.judge(heard: decoder.pieces(clip), phrase: phrase))"); continue }
        }
        #expect(Hearing.judge(heard: decoder.pieces(try fixture("hey-jeff-Daniel")), phrase: phrase) != .phrase)
        #expect(Hearing.judge(heard: decoder.pieces(try fixture("luminaropolis-Daniel")), phrase: phrase) != .phrase)
        let enrolled = try [150, 165, 195].map { try fixture("hey-luminaropolis-Daniel-\($0)") }
        for clip in enrolled { #expect(Hearing.judge(heard: decoder.pieces(clip), phrase: phrase) == .phrase) }
        let heldOut = try fixture("hey-luminaropolis-Daniel-170")

        let standard = try Spotter(settings: WakeSettings(phrase: phrase, spellings: Enroller.spellings(phrase)), directory: ModelFiles.locate())
        #expect(try standard.detect(heldOut) == 0, "root cause: the spelled tokens never match what the model hears")

        let result = try await Enroller().calibrate(phrase: phrase, positives: enrolled, negatives: [john[0]])
        print("RARE caught=\(result.caught) false=\(result.falseHits) threshold=\(result.settings.threshold) learned=\(result.settings.learned)")
        #expect(!result.settings.learned.isEmpty && result.caught == 3 && result.falseHits == 0)
        let tuned = try Spotter(settings: result.settings, directory: ModelFiles.locate())

        #expect(try tuned.detect(heldOut) > 0)
        for clip in confusables { #expect(try tuned.detect(clip) == 0) }
    }

    /// Tuning's tick, including deterministic sound-alike examples.
    @Test func judgeTellsTheNameApartBySound() {
        func heard(_ text: String) -> [String] { text.split(separator: " ").map { "▁" + $0 } }
        #expect(Hearing.judge(heard: heard("HEY TRAY"), phrase: "hey tray") == .phrase)
        #expect(Hearing.judge(heard: heard("HAYDRAY"), phrase: "hey tray") == .phrase)
        #expect(Hearing.judge(heard: heard("PAY THREE"), phrase: "hey tray") == .phrase)
        #expect(Hearing.judge(heard: heard("HEY TROY"), phrase: "hey tray") == .otherName("HEY TROY"))
        #expect(Hearing.judge(heard: heard("HEY RAY"), phrase: "hey tray") == .otherName("HEY RAY"))
        #expect(Hearing.judge(heard: heard("HEY JOHN"), phrase: "hey tray") == .otherName("HEY JOHN"))
        #expect(Hearing.judge(heard: heard("TRAY"), phrase: "hey tray") == .missingStart("TRAY"))
        #expect(Hearing.judge(heard: [], phrase: "hey tray") == .nothing)
        #expect(Hearing.judge(heard: heard("HEY DON'T"), phrase: "hey dot") == .phrase)
        #expect(Hearing.judge(heard: heard("HEY DON"), phrase: "hey dot") != .phrase)
        #expect(Hearing.judge(heard: heard("HEY LUMINA ROPOLIS"), phrase: "hey luminaropolis") == .phrase)
        #expect(Hearing.judge(heard: heard("HEY JEFF"), phrase: "hey luminaropolis") != .phrase)
        #expect(Hearing.judge(heard: heard("HEY PAPA TO PALACE"), phrase: "hey luminaropolis") != .phrase)
        // Ticks, but too loose to learn: these sequences would fire on "hey don" and "hey dre".
        #expect(!Hearing.learnable(heard: heard("HEY DON'T"), phrase: "hey dot"))
        #expect(!Hearing.learnable(heard: heard("HEY DRAY"), phrase: "hey tray"))
        #expect(Hearing.learnable(heard: heard("HEY TRAY"), phrase: "hey tray"))
        #expect(Hearing.learnable(heard: heard("HEY LUMINA ROPOLIS"), phrase: "hey luminaropolis"))
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
        #expect(keywords == [["▁HE", "Y", "▁TRA", "Y"]])
    }
}
