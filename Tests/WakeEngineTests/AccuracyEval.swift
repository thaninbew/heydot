import CSherpa
import Foundation
import Testing
@testable import WakeEngine

// Offline, reproducible wake phrase accuracy harness. Gated: it returns at once unless HEYDOT_EVAL=1, so a normal
// `swift test` stays fast and never synthesizes speech.
//
//   HEYDOT_EVAL=1 swift test --filter wakeAccuracyEval 2>&1 | grep 'EVAL|'
//
// Speech comes from macOS `say` (synthetic voices, no personal recordings), cached outside the repository under
// HEYDOT_EVAL_CACHE (default /tmp/heydot-eval-cache), keyed by voice, rate and text, so reruns skip synthesis.
// Noisy copies are mixed deterministically (seeded) at run time. The baseline at 15a3cad was measured by the
// earlier version of this file (preview tick, any phrase-length utterance ticked); this one simulates the current
// tuning screen: a slot ticks only when Hearing.judge hears the phrase, the user repeats until four tick.

private enum AccuracyEval {
    // MARK: Corpus

    /// English voices with varied accents and genders; novelty voices are skipped.
    static let voices = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Tessa", "Eddy (English (US))", "Reed (English (UK))"]
    static let testRates = [140, 175, 210]
    static let enrollRates = [150, 165, 190, 200]
    /// Further attempts when a sample doesn't tick (the user says it again).
    static let retryRates = [155, 180, 195, 205]
    /// Rate for the tuning screen's "other phrases" and for the bug flow's mistaken "hey john" positive.
    static let negativeRate = 165
    static let babbleRate = 175, tvRate = 175

    static let phrases = ["hey luminaropolis", "hey tray", "hey dot", "hey nova", "hey maximilian"]
    /// Similar-sounding names per phrase. Homophone spellings of the phrase itself ("hey tray") are not confusables.
    static let similar: [String: [String]] = [
        "hey luminaropolis": ["hey lumina", "hey lunar", "hey metropolis"],
        "hey tray": ["hey ray", "hey troy", "hey dre"],
        "hey dot": ["hey don", "hey doc", "hey dad"],
        "hey nova": ["hey noah", "hey nora", "hey nolan"],
        "hey maximilian": ["hey max", "hey maxwell", "hey million"],
    ]
    static let sentences = ["i'm making a cup of coffee", "hey what time is it", "let's watch the game tonight"]

    static func name(_ phrase: String) -> String {
        phrase.split(separator: " ").dropFirst().joined(separator: " ")
    }
    /// Everything that must be rejected for `phrase`.
    static func confusables(_ phrase: String) -> [String] {
        var out: [String] = []
        for text in ["hey", "hey john", "hey jeff", "hey there", name(phrase)] + (similar[phrase] ?? []) + sentences
        where text != phrase && !out.contains(text) { out.append(text) }
        return out
    }
    /// What the voice tuning screen collects as "other phrases" (OnboardingModel.otherPrompts: the start with a
    /// different name, the name alone, "Hey there"). Change this one function when the tuning UI changes.
    static func tuningNegatives(_ phrase: String) -> [String] {
        [phrase.contains("john") ? "hey sam" : "hey john", name(phrase), "hey there"]
    }

    /// Ordinary "TV" sentences mixed under noisy test clips (spoken by a different voice).
    static let babble = [
        "the weather tomorrow looks cloudy with a chance of rain in the afternoon",
        "and now back to our top story of the evening",
        "he passes the ball down the left side and shoots",
        "stay tuned for more right after the break",
    ]
    /// About two minutes of ordinary speech, including "hey" followed by other names, for the stream check.
    static let tv: [(voice: String, text: String)] = [
        ("Samantha", "Good evening and welcome back. Tonight we have a full program for you, starting with the latest on the city budget, followed by a look at the weekend weather, and later an interview with the coach of the local football team about their surprising winning streak."),
        ("Daniel", "Hey Mike, could you pass me the remote? I think the other channel has the match. Honestly, I have no idea why they keep showing replays of the same goal. Hey John, come and look at this, it is the third time they have shown it."),
        ("Karen", "In the kitchen today we are making a simple tomato soup. Start by chopping two onions and a clove of garlic, then let them soften in a little olive oil over a medium heat for about five minutes, stirring now and then."),
        ("Moira", "Hey Jeff, did you remember to call your mother back? She rang twice this afternoon. Oh, and hey Ray, the dog needs a walk before it gets dark, so please do not leave it until the last minute again."),
        ("Rishi", "The stock market closed slightly higher today, led by technology shares, while oil prices fell for the second day in a row. Analysts say investors are waiting for next week's report on inflation before making any big moves."),
        ("Tessa", "Hey everyone, thanks for tuning in to the show. Today we are talking about how to get a better night's sleep, why your phone might be keeping you awake, and three small habits that can make a real difference."),
        ("Eddy (English (US))", "Hey Tony, hey Don, are you two coming to the game on Saturday? We have got an extra ticket if Troy wants to come along. Let me know by Thursday so I can sort out the parking."),
        ("Reed (English (UK))", "And that brings us to the end of tonight's episode. Thank you for watching, have a good night, and we will see you again next week at the same time for another hour of news, sport and conversation."),
    ]

    // MARK: Synthesis and cache

    struct Utt: Hashable, Sendable {
        let voice: String, rate: Int, text: String
        var key: String { "\(voice)|\(rate)|\(text)" }
    }

    static var cache: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HEYDOT_EVAL_CACHE"] ?? "/tmp/heydot-eval-cache", isDirectory: true)
    }
    static func file(_ u: Utt) -> URL {
        let slug = { (s: String) in String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(32)) }
        return cache.appendingPathComponent("\(slug(u.voice))-\(u.rate)-\(slug(u.text))-\(String(fnv(u.key), radix: 16)).wav")
    }

    final class Failures: @unchecked Sendable {
        let lock = NSLock(); var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    }

    /// Synthesizes every missing utterance with /usr/bin/say, 8 at a time. Returns how many were new.
    static func synthesize(_ all: Set<Utt>) throws -> Int {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let missing = all.filter { !FileManager.default.fileExists(atPath: file($0).path) }.sorted { $0.key < $1.key }
        let failures = Failures(), width = 8
        DispatchQueue.concurrentPerform(iterations: width) { lane in
            for i in stride(from: lane, to: missing.count, by: width) {
                let u = missing[i], target = file(u)
                let temp = cache.appendingPathComponent(".tmp-\(UUID().uuidString).wav")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                p.arguments = ["-v", u.voice, "-r", String(u.rate), "-o", temp.path, "--file-format=WAVE", "--data-format=LEI16@16000", u.text]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit() } catch { failures.add("\(u.key): \(error)"); continue }
                guard p.terminationStatus == 0 else { failures.add("\(u.key): say exited \(p.terminationStatus)"); try? FileManager.default.removeItem(at: temp); continue }
                if (try? FileManager.default.moveItem(at: temp, to: target)) == nil { try? FileManager.default.removeItem(at: temp) }
            }
        }
        if !failures.items.isEmpty { throw WakeEngineError.engine("say failed: " + failures.items.prefix(3).joined(separator: "; ")) }
        return missing.count
    }

    static func cacheBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: Deterministic noise

    static func fnv(_ s: String) -> UInt64 {
        s.utf8.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9; z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
        mutating func gaussian() -> Float {
            let u1 = max(Double(next() >> 11) / Double(1 << 53), 1e-12), u2 = Double(next() >> 11) / Double(1 << 53)
            return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
    }
    /// RMS over the 20 ms frames within 20 dB of the loudest frame (the speech, not the silence around it).
    static func activeRMS(_ clip: Clip) -> Float {
        let frames = stride(from: 0, to: clip.count, by: 320).map { o -> Float in
            let f = clip[o..<min(o + 320, clip.count)]
            return (f.reduce(0) { $0 + $1 * $1 } / Float(f.count)).squareRoot()
        }
        let top = frames.max() ?? 0, active = frames.filter { $0 >= top * 0.1 }
        return active.isEmpty ? 0 : (active.reduce(0) { $0 + $1 * $1 } / Float(active.count)).squareRoot()
    }
    /// Speech plus white noise at 25 dB SNR plus another voice's sentence 12 dB under the speech.
    static func noisy(_ speech: Clip, babble: Clip, seed: UInt64) -> Clip {
        var rng = SplitMix(state: seed)
        let level = activeRMS(speech)
        let gain = babble.isEmpty ? 0 : level * pow(10, -12 / 20) / max(activeRMS(babble), 1e-6)
        let sigma = level * pow(10, -25 / 20)
        let offset = babble.isEmpty ? 0 : Int(rng.next() % UInt64(babble.count))
        return speech.indices.map { i in
            let b = babble.isEmpty ? 0 : babble[(offset + i) % babble.count] * gain
            return min(1, max(-1, speech[i] + b + rng.gaussian() * sigma))
        }
    }

    // MARK: Measurement

    struct Tally: Sendable {
        var hit = 0, total = 0
        mutating func add(_ detected: Bool) { total += 1; if detected { hit += 1 } }
        static func + (a: Tally, b: Tally) -> Tally { Tally(hit: a.hit + b.hit, total: a.total + b.total) }
        var text: String { total == 0 ? "n/a" : "\(hit)/\(total) (\(String(format: "%.1f", 100 * Double(hit) / Double(total)))%)" }
    }

    enum Scenario: String, Sendable, CaseIterable {
        case standard = "Standard", preview = "Tuning tick (Hearing.judge)", honest = "Tuned (honest user)", bug = "Tuned (owner bug flow)"
    }

    struct Outcome: Sendable {
        let scenario: Scenario, phrase: String
        var voice: String? = nil
        var taClean = Tally(), taNoisy = Tally()
        var fa: [String: Tally] = [:]
        var settings: WakeSettings? = nil
        var caught = 0, falseHits = 0, enrolled = 0
        /// Tuning flow: attempts spoken, slots ticked, whether the user's "hey john" ticked, voices that could not
        /// reach the three ticks Continue needs (they fall back to standard settings, like Later).
        var attempts = 0, ticks = 0, johnTicked = 0, stuck = 0
        var ta: Tally { taClean + taNoisy }
        var faAll: Tally { fa.values.reduce(Tally(), +) }
        static func + (a: Outcome, b: Outcome) -> Outcome {
            var o = a; o.voice = nil; o.taClean = a.taClean + b.taClean; o.taNoisy = a.taNoisy + b.taNoisy
            o.fa = a.fa.merging(b.fa, uniquingKeysWith: +); o.caught += b.caught; o.falseHits += b.falseHits; o.enrolled += b.enrolled
            o.attempts += b.attempts; o.ticks += b.ticks; o.johnTicked += b.johnTicked; o.stuck += b.stuck
            return o
        }
    }

    struct Corpus: Sendable {
        let clean: [Utt: Clip], dirty: [Utt: Clip]
        /// Test clips of `text` by `voice`: every test rate, clean and noisy.
        func test(_ text: String, _ voice: String) -> [(clip: Clip, noisy: Bool)] {
            testRates.flatMap { r -> [(clip: Clip, noisy: Bool)] in
                let u = Utt(voice: voice, rate: r, text: text)
                return [(clean[u]!, false), (dirty[u]!, true)]
            }
        }
        func clip(_ voice: String, _ rate: Int, _ text: String) -> Clip { clean[Utt(voice: voice, rate: rate, text: text)]! }
    }

    static func measure(_ spotter: Spotter, _ o: inout Outcome, voices: [String], corpus: Corpus) throws {
        for voice in voices {
            for t in corpus.test(o.phrase, voice) {
                let hit = try spotter.detect(t.clip) > 0
                if t.noisy { o.taNoisy.add(hit) } else { o.taClean.add(hit) }
            }
            for text in confusables(o.phrase) {
                for t in corpus.test(text, voice) { o.fa[text, default: Tally()].add(try spotter.detect(t.clip) > 0) }
            }
        }
    }

    static func fixed(_ scenario: Scenario, _ phrase: String, corpus: Corpus) throws -> Outcome {
        let settings = WakeSettings(phrase: phrase)
        var o = Outcome(scenario: scenario, phrase: phrase, settings: settings)
        try measure(try Spotter(settings: settings, directory: ModelFiles.locate()), &o, voices: voices, corpus: corpus)
        return o
    }

    /// The tuning screen's tick on every test clip: TA = the phrase ticks a slot, FA = a confusable ticks one.
    static func tick(_ phrase: String, corpus: Corpus) throws -> Outcome {
        let decoder = try PhraseDecoder(directory: ModelFiles.locate())
        var o = Outcome(scenario: .preview, phrase: phrase)
        for voice in voices {
            for t in corpus.test(phrase, voice) {
                let hit = Hearing.judge(heard: decoder.pieces(t.clip), phrase: phrase) == .phrase
                if t.noisy { o.taNoisy.add(hit) } else { o.taClean.add(hit) }
            }
            for text in confusables(phrase) {
                for t in corpus.test(text, voice) { o.fa[text, default: Tally()].add(Hearing.judge(heard: decoder.pieces(t.clip), phrase: phrase) == .phrase) }
            }
        }
        return o
    }

    /// Simulates the tuning screen for one speaker: attempts in order (the bug flow says "hey john" second), a slot
    /// ticks only when Hearing.judge hears the phrase, until four tick or the attempts run out; then the other
    /// phrases, and Continue (Enroller.calibrate) once at least three ticked. Otherwise the user takes Later.
    static func tuned(_ scenario: Scenario, _ phrase: String, voice: String, corpus: Corpus) async throws -> Outcome {
        let decoder = try PhraseDecoder(directory: ModelFiles.locate())
        var attempts = (enrollRates + retryRates).map { (clip: corpus.clip(voice, $0, phrase), john: false) }
        if scenario == .bug { attempts.insert((corpus.clip(voice, negativeRate, "hey john"), true), at: 1) }
        var positives: [Clip] = [], spoken = 0, johnTicked = 0
        for a in attempts where positives.count < 4 {
            spoken += 1
            guard Hearing.judge(heard: decoder.pieces(a.clip), phrase: phrase) == .phrase else { continue }
            if a.john { johnTicked += 1 }
            positives.append(a.clip)
        }
        let negatives = tuningNegatives(phrase).map { corpus.clip(voice, negativeRate, $0) }
        var o = Outcome(scenario: scenario, phrase: phrase, voice: voice, enrolled: positives.count)
        o.attempts = spoken; o.ticks = positives.count; o.johnTicked = johnTicked
        if positives.count >= 3 {
            let cal = try await Enroller().calibrate(phrase: phrase, positives: positives, negatives: negatives)
            o.settings = cal.settings; o.caught = cal.caught; o.falseHits = cal.falseHits
        } else {
            o.settings = WakeSettings(phrase: phrase); o.stuck = 1
        }
        try measure(try Spotter(settings: o.settings!, directory: ModelFiles.locate()), &o, voices: [voice], corpus: corpus)
        return o
    }

    /// One continuous stream through one keyword stream, in 1280-sample chunks like the live listener.
    static func tvHits(_ phrase: String, stream audio: Clip) throws -> Int {
        let spotter = try Spotter(settings: WakeSettings(phrase: phrase), directory: ModelFiles.locate())
        let s = try spotter.stream(); defer { SherpaOnnxDestroyOnlineStream(s) }
        var hits = 0
        for o in stride(from: 0, to: audio.count, by: 1280) { hits += spotter.accept(Array(audio[o..<min(o + 1280, audio.count)]), stream: s) }
        return hits
    }
}

@Test func wakeAccuracyEval() async throws {
    guard ProcessInfo.processInfo.environment["HEYDOT_EVAL"] == "1" else { return }
    typealias E = AccuracyEval
    let started = ContinuousClock.now
    if ProcessInfo.processInfo.environment["HEYDOT_MODEL_DIR"] == nil {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("HEYDOT_MODEL_DIR", root.appendingPathComponent("Vendor/models").path, 1)
    }
    _ = try ModelFiles.locate()

    // Everything to synthesize.
    var needed = Set<E.Utt>()
    var testTexts = Set<String>()
    for phrase in E.phrases { testTexts.insert(phrase); testTexts.formUnion(E.confusables(phrase)) }
    for voice in E.voices {
        for text in testTexts { for r in E.testRates { needed.insert(.init(voice: voice, rate: r, text: text)) } }
        for phrase in E.phrases {
            for r in E.enrollRates + E.retryRates { needed.insert(.init(voice: voice, rate: r, text: phrase)) }
            for text in E.tuningNegatives(phrase) + ["hey john"] { needed.insert(.init(voice: voice, rate: E.negativeRate, text: text)) }
        }
        for text in E.babble { needed.insert(.init(voice: voice, rate: E.babbleRate, text: text)) }
    }
    for p in E.tv { needed.insert(.init(voice: p.voice, rate: E.tvRate, text: p.text)) }
    let fresh = try E.synthesize(needed)
    let synthesized = ContinuousClock.now

    var clean: [E.Utt: Clip] = [:]
    for u in needed { clean[u] = try OfflineDetector.readWAV(E.file(u)) }
    var dirty: [E.Utt: Clip] = [:]
    for u in needed where E.testRates.contains(u.rate) && testTexts.contains(u.text) {
        let h = E.fnv(u.key), others = E.voices.filter { $0 != u.voice }
        let babble = clean[.init(voice: others[Int(h % UInt64(others.count))], rate: E.babbleRate, text: E.babble[Int((h >> 8) % UInt64(E.babble.count))])]!
        dirty[u] = E.noisy(clean[u]!, babble: babble, seed: h)
    }
    let corpus = E.Corpus(clean: clean, dirty: dirty)
    let silence = Clip(repeating: 0, count: 8000)
    let tvAudio = E.tv.flatMap { silence + clean[.init(voice: $0.voice, rate: E.tvRate, text: $0.text)]! } + silence

    // Measure everything concurrently; every job owns its own Spotter (reused across that job's clips).
    var outcomes: [E.Outcome] = []
    var tv: [String: Int] = [:]
    try await withThrowingTaskGroup(of: (E.Outcome?, (String, Int)?).self) { group in
        for phrase in E.phrases {
            group.addTask { (try E.fixed(.standard, phrase, corpus: corpus), nil) }
            group.addTask { (try E.tick(phrase, corpus: corpus), nil) }
            group.addTask { (nil, (phrase, try E.tvHits(phrase, stream: tvAudio))) }
            for voice in E.voices {
                group.addTask { (try await E.tuned(.honest, phrase, voice: voice, corpus: corpus), nil) }
                group.addTask { (try await E.tuned(.bug, phrase, voice: voice, corpus: corpus), nil) }
            }
        }
        for try await (o, t) in group {
            if let o { outcomes.append(o) }
            if let t { tv[t.0] = t.1 }
        }
    }
    let measured = ContinuousClock.now

    func out(_ line: String = "") { print("EVAL| " + line) }
    func f(_ x: Float) -> String { String(format: "%g", x) }
    func aggregate(_ s: E.Scenario, _ phrase: String) -> E.Outcome {
        let parts = outcomes.filter { $0.scenario == s && $0.phrase == phrase }
        return parts.dropFirst().reduce(parts[0], +)
    }
    let count = { (s: Duration) in String(format: "%.1f s", Double(s.components.seconds) + Double(s.components.attoseconds) / 1e18) }

    out("# HeyDot wake accuracy (offline, macOS say)")
    out("Voices: \(E.voices.joined(separator: ", ")). Test rates \(E.testRates), enrollment rates \(E.enrollRates), tuning negatives and bug-flow \"hey john\" at \(E.negativeRate).")
    out("Each test utterance is counted clean and noisy (white noise 25 dB SNR + another voice's sentence 12 dB under). Detected = detect(clip) > 0.")
    out("Standard = WakeSettings(phrase:) as the live listener gets it after Later or a phrase change; Tuning tick = whether the tuning screen ticks a slot (Hearing.judge on what PhraseDecoder heard).")
    out("Tuning negatives (honest user): \(E.tuningNegatives("hey <name>"))")
    out()
    for phrase in E.phrases {
        let std = WakeSettings(phrase: phrase)
        out("Phrase \"\(phrase)\": standard score \(f(std.score)) threshold \(f(std.threshold)) spellings \(std.spellings); Enroller.spellings \(Enroller.spellings(phrase)); confusables \(E.confusables(phrase))")
    }
    out()
    out("## Summary (TA = true accept on positives, FA = false accept on confusables)")
    out()
    out("| Phrase | Scenario | TA | TA clean | TA noisy | FA | FA \"hey john\" |")
    out("|---|---|---|---|---|---|---|")
    for phrase in E.phrases {
        for s in E.Scenario.allCases {
            let o = aggregate(s, phrase)
            out("| \(phrase) | \(s.rawValue) | \(o.ta.text) | \(o.taClean.text) | \(o.taNoisy.text) | \(o.faAll.text) | \(o.fa["hey john"]!.text) |")
        }
    }
    for s in [E.Scenario.honest, .bug] {
        out()
        out("## \(s.rawValue): per enrollment voice (judge-ticked positives\(s == .bug ? ", user said \"hey john\" as attempt 2" : "") + \(E.tuningNegatives("x").count) negatives)")
        out()
        let flow = outcomes.filter { $0.scenario == s }.reduce(E.Outcome(scenario: s, phrase: ""), +)
        out("Attempts \(flow.attempts), ticks \(flow.ticks), \"hey john\" ticked \(flow.johnTicked) times, voices stuck below three ticks \(flow.stuck).")
        out()
        out("| Phrase | Voice | attempts | ticks | threshold | learned | caught/enrolled | false hits | TA | FA | FA \"hey john\" |")
        out("|---|---|---|---|---|---|---|---|---|---|---|")
        for phrase in E.phrases {
            for voice in E.voices {
                guard let o = outcomes.first(where: { $0.scenario == s && $0.phrase == phrase && $0.voice == voice }), let st = o.settings else { continue }
                out("| \(phrase) | \(voice) | \(o.attempts) | \(o.ticks) | \(f(st.threshold))\(o.stuck > 0 ? " (standard)" : "") | \(st.learned.count) | \(o.caught)/\(o.enrolled) | \(o.falseHits) | \(o.ta.text) | \(o.faAll.text) | \(o.fa["hey john"]!.text) |")
            }
        }
    }
    for phrase in ["hey luminaropolis", "hey tray"] {
        out()
        out("## Per-confusable false accepts: \"\(phrase)\"")
        out()
        out("| Confusable | " + E.Scenario.allCases.map(\.rawValue).joined(separator: " | ") + " |")
        out("|---|" + String(repeating: "---|", count: E.Scenario.allCases.count))
        for text in E.confusables(phrase) {
            out("| \(text) | " + E.Scenario.allCases.map { aggregate($0, phrase).fa[text]!.text }.joined(separator: " | ") + " |")
        }
    }
    out()
    out("## TV stream false accepts (standard settings, one stream, 1280-sample chunks)")
    out()
    let tvSeconds = Double(tvAudio.count) / 16000
    out("Stream: \(String(format: "%.1f", tvSeconds)) s of ordinary speech from \(Set(E.tv.map(\.voice)).count) voices (includes hey Mike/John/Jeff/Ray/Tony/Don, Troy).")
    out()
    out("| Phrase | Hits | Hits per hour |")
    out("|---|---|---|")
    for phrase in E.phrases { out("| \(phrase) | \(tv[phrase]!) | \(String(format: "%.0f", Double(tv[phrase]!) * 3600 / tvSeconds)) |") }
    out()
    out("Utterances: \(needed.count) (\(fresh) newly synthesized). Cache: \(E.cache.path), \(E.cacheBytes() / 1024) KB.")
    out("Elapsed: synthesis \(count(synthesized - started)), measurement \(count(measured - synthesized)), total \(count(ContinuousClock.now - started)).")
}
