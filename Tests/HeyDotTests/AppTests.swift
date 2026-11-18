import Foundation
import Testing
import WakeEngine
@testable import HeyDotKit

private func tempHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heydot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: Phrase rules (config.py parity)

@Test func namesBecomeHeyPhrases() throws {
    #expect(try Phrase.validateName("tray").get() == "Tray")
    #expect(try Phrase.validateName("  mr  o'neil ").get() == "Mr O'neil")
    #expect(Phrase.phrase(forName: "Tray") == "hey tray")
    #expect(Phrase.phrase(forName: "Dot") == "hey dot")
}

@Test func reservedAndMalformedNamesAreRejected() {
    #expect(Phrase.validateName("Jarvis") == .failure(.reserved("jarvis")))
    #expect(Phrase.validateName("little JARVIS") == .failure(.reserved("jarvis")))
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

// MARK: Settings persistence

@Test func settingsRoundTripWithPrivateMode() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    #expect(try store.load() == AppSettings())  // first run
    var s = AppSettings()
    s.rename("Tray")
    s.wake = WakeSettings(phrase: "hey tray", spellings: ["hey tray"], score: 1.5, threshold: 0.1)
    s.dotURL = "https://chatgpt.com/dots/tray"
    s.design = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody)
    s.onboarded = true
    try store.save(s)
    #expect(try store.load() == s)
    let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let dirMode = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)[.posixPermissions] as? Int
    #expect(dirMode == 0o700)
}

@Test func olderSettingsFilesKeepLoading() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"dotName": "Tray", "paused": true}"#.utf8).write(to: store.url)
    let s = try store.load()
    #expect(s.dotName == "Tray" && s.paused && s.wake.phrase == "hey tray" && s.design == .default)
    try Data("not json".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
}

@Test func renamingResetsTuning() {
    var s = AppSettings()
    s.wake = WakeSettings(phrase: "hey dot", score: 3, threshold: 0.25)
    s.calibrationNote = "Caught 4 of 4"
    s.rename("Sol")
    #expect(s.wake == WakeSettings(phrase: "hey sol"))
    #expect(s.calibrationNote == nil)
}

// MARK: Dot artwork

@Test func everyOptionDrawsInsideTheGrid() {
    var designs: [DotDesign] = DotShape.allCases.flatMap { shape in
        DotAccessory.allCases.map { DotDesign(shape: shape, accessory: $0) } +
        DotGlasses.allCases.map { DotDesign(shape: shape, glasses: $0) } +
        DotEyes.allCases.map { DotDesign(shape: shape, eyes: $0) }
    }
    let mic = DotArt.face(.default)
    #expect(mic.body.boundingBoxOfPath == CGRect(x: 28, y: 4, width: 40, height: 58))
    #expect(mic.eyeY == 34 && mic.eyeGap == 9.5 && mic.eyeW == 11 && mic.eyeH == 16)
    let glyph = DotArt.layers(.default, gutter: 4).first { $0.role == .body }!.path
    #expect(!glyph.contains(CGPoint(x: 37.5, y: 34)) && !glyph.contains(CGPoint(x: 58.5, y: 34)))
    #expect(glyph.contains(CGPoint(x: 48, y: 34)), "the bridge keeps two separate eye holes")
    #expect(!glyph.contains(CGPoint(x: 48, y: 64)) && glyph.contains(CGPoint(x: 48, y: 69)))
    designs += DotSignature.allCases.map { DotDesign(signature: $0) }
    for design in designs {
        let layers = DotArt.layers(design)
        let bounds = layers.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        #expect(!bounds.isNull && bounds.minX >= 2.9 && bounds.minY >= 2.9 && bounds.maxX <= 93.1 && bounds.maxY <= 93.1,
                "\(design) is out of bounds: \(bounds)")
        // Sunglasses deliberately cover the eyes; their glint carries the colour instead.
        let shaded = design.glasses == .classicSunglasses || design.glasses == .roundSunglasses
        #expect(shaded || layers.contains { $0.role == .eye && !$0.path.isEmpty }, "\(design) lost its eyes")
        #expect(!shaded || layers.contains { $0.role == .glint && !$0.path.isEmpty }, "\(design) lost its glint")
    }
}

@Test func designsPersistAsJSON() throws {
    let d = DotDesign(shape: .heart, color: .coral, eyes: .sleepyLids, glasses: .monocle, accessory: .crown, accessoryColor: .brown,
                      nickname: "Pip", fill: .colorBody)
    #expect(try JSONDecoder().decode(DotDesign.self, from: JSONEncoder().encode(d)) == d)
}
