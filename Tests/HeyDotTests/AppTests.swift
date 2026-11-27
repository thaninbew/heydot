import AppKit
import Foundation
import SwiftUI
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

@Test func rebuildingDamagedSettingsPreservesOriginalAndOtherData() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    let store = SettingsStore(url: paths.settings)
    let avatar = paths.support.appending(path: "avatars/test.png")
    let webData = home.appending(path: "Library/WebKit/test-session")
    let unrelatedBytes = Data([0xde, 0xad, 0xbe, 0xef])
    for file in [avatar, webData] {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try unrelatedBytes.write(to: file)
    }
    let damaged = Data([0xff, 0x00, 0xbb])
    try damaged.write(to: store.url)
    func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: paths.support, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.damaged-") }
    }

    #expect(throws: DecodingError.self) { try store.load() }
    #expect(try Data(contentsOf: store.url) == damaged)
    #expect(try backups().isEmpty)

    #expect(try store.rebuildUnreadable() == AppSettings())
    #expect(try SettingsStore(url: store.url).load() == AppSettings())
    let backup = try #require(try backups().first)
    #expect(try Data(contentsOf: backup) == damaged)
    #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
    #expect(try Data(contentsOf: avatar) == unrelatedBytes)
    #expect(try Data(contentsOf: webData) == unrelatedBytes)

    #expect(try store.rebuildUnreadable() == AppSettings())
    #expect(try backups() == [backup])
}

@Test func recoveryCanRetryAfterASettingsFileIsRestored() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
    let marker = store.url.appendingPathComponent("keep")
    let bytes = Data("original".utf8)
    try bytes.write(to: marker)

    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: (any Error).self) { try store.rebuildUnreadable() }
    #expect(try Data(contentsOf: marker) == bytes)

    try FileManager.default.removeItem(at: store.url)
    var restored = AppSettings()
    restored.rename("Tray")
    restored.onboarded = true
    try store.save(restored)
    #expect(try store.rebuildUnreadable() == restored)
    #expect(try store.load() == restored)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path) == ["settings.json"])
}

@Test func recoveryReusesBackupWhenReplacingTheOriginalFails() throws {
    let home = try tempHome()
    let store = SettingsStore(url: Paths(home: home).settings)
    let files = FileManager.default
    defer {
        try? files.setAttributes([.immutable: false], ofItemAtPath: store.url.path)
        try? files.removeItem(at: home)
    }
    let folder = store.url.deletingLastPathComponent()
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    let damaged = Data("not json".utf8)
    try damaged.write(to: store.url)
    try files.setAttributes([.immutable: true], ofItemAtPath: store.url.path)

    #expect(throws: (any Error).self) { try store.rebuildUnreadable() }
    #expect(throws: (any Error).self) { try SettingsStore(url: store.url).rebuildUnreadable() }
    #expect(try Data(contentsOf: store.url) == damaged)
    let backups = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("settings.json.damaged-") }
    #expect(backups.count == 1)
    let backup = try #require(backups.first)
    #expect(try Data(contentsOf: backup) == damaged)

    try files.setAttributes([.immutable: false], ofItemAtPath: store.url.path)
    #expect(try store.rebuildUnreadable() == AppSettings())
    #expect(try files.contentsOfDirectory(atPath: folder.path).sorted() == ["settings.json", backup.lastPathComponent])
}

@MainActor @Test func setupStaysOpenUntilSettingsCanBeSaved() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    var settings = AppSettings()
    settings.dotURL = "https://chatgpt.com/dots/tray"
    let engine = FakeEngine()
    var hooks = QARender.fakeHooks()
    var loginChanges: [Bool] = []
    hooks.setLaunchAtLogin = { loginChanges.append($0) }
    let app = AppModel(settings: settings, engine: engine, enroller: FakeEnroller(), hooks: hooks, store: store,
                       log: Log(url: URL(fileURLWithPath: "/dev/null")))
    let flow = OnboardingModel(app: app, tuner: FakeTuner())
    flow.step = .done
    var finished = false
    flow.finish = { finished = true }
    try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

    flow.primary()
    #expect(!finished && !app.settings.onboarded && !engine.isListening)
    #expect(loginChanges.isEmpty)
    #expect(app.settingsError != nil)

    try FileManager.default.removeItem(at: store.url)
    flow.primary()
    #expect(finished && app.settings.onboarded && engine.isListening)
    #expect(loginChanges == [true])
    #expect(app.settingsError == nil)
    #expect(try store.load() == app.settings)
}

@MainActor @Test func rejectedLoginItemKeepsSetupOpenAndCanBeSkipped() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    var hooks = QARender.fakeHooks()
    hooks.launchAtLoginEnabled = { false }
    hooks.setLaunchAtLogin = { requested in
        if requested { throw POSIXError(.EPERM) }
    }
    let app = AppModel(settings: AppSettings(), engine: FakeEngine(), enroller: FakeEnroller(),
                       hooks: hooks, store: store, log: Log(url: home.appendingPathComponent("test.log")))
    let flow = OnboardingModel(app: app, tuner: FakeTuner())
    flow.step = .done
    var finished = false
    flow.finish = { finished = true }

    flow.primary()
    #expect(!finished && flow.loginError != nil)
    #expect(!app.settings.onboarded)
    #expect(try !store.load().onboarded)

    flow.launchAtLogin = false
    flow.primary()
    #expect(finished && flow.loginError == nil)
    let saved = try store.load()
    #expect(saved.onboarded && !saved.launchAtLogin)
}

@MainActor @Test func standaloneVoiceTuningDoesNotCompleteSetup() {
    let app = QARender.model { $0.onboarded = false; $0.dotURL = nil }
    let flow = OnboardingModel(app: app, tuner: FakeTuner())
    flow.step = .voice
    flow.returnAfterTuning = true
    var finished = false
    flow.finish = { finished = true }

    flow.skipTuning()
    #expect(finished)
    #expect(!app.settings.onboarded)
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

// MARK: HeyDot logo

@MainActor private func pixels(_ view: some View, side: CGFloat = 64) -> Data? {
    let renderer = ImageRenderer(content: view.frame(width: side, height: side))
    renderer.scale = 1
    return renderer.cgImage?.dataProvider?.data as Data?
}

private func hue(_ color: Color) -> Double {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    let hex = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
    return OKLCH(hex: hex).h
}

@MainActor @Test func theLogoStaysTheLogoWithANickname() {
    var named = DotDesign.default
    named.nickname = "Pip"
    #expect(pixels(DotTile(named, size: 64)) == pixels(DotTile(.default, size: 64)), "a nickname swapped the logo for a drawn mic")
    #expect(Theme.forDesign(named) == Theme.forDesign(.default))
    #expect(Accent.hex(for: named) == Accent.hex(for: .default))
}

@MainActor @Test func theLogoAndDotsMadeFromItStayCoral() {
    let brand = OKLCH(hex: Accent.defaultHex).h
    var edits: [DotDesign] = [.default]
    for edit in [{ (d: inout DotDesign) in d.eyes = .dots }, { $0.glasses = .monocle }, { $0.accessory = .crown }, { $0.fill = .inkBody }] {
        var d = DotDesign.default; edit(&d); edits.append(d)
    }
    for design in edits {
        let paint = DotView.palette(design, .standard)
        let body = design.fill == .colorBody ? paint(.body)! : paint(.eye)!
        #expect(OKLCH.hueDistance(hue(body), brand) < 30, "\(design) is drawn purple, not in the logo's coral")
    }
}

@Test func theShapeRowOffersTheLogoBack() {
    let tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, nickname: "Tray")
    #expect(ShapeChoice.all.first == .heyDot)
    #expect(ShapeChoice(.default) == .heyDot && ShapeChoice(tray) == .shape(.roundedTriangle))
    let back = ShapeChoice.heyDot.applied(to: tray)
    #expect(back.isLogo && back.nickname == "Tray")
    var avatar = tray
    avatar.custom = CustomArt(id: "x", silhouette: true)
    #expect(ShapeChoice(avatar) == nil && ShapeChoice.heyDot.applied(to: avatar).isLogo)
}

@Test func savedLogosLoadAsTheLogoKeepingTheirNickname() throws {
    // HeyDot 0.2.0 saved the logo with the violet of the earlier flat mic, in a file without a version.
    let saved = DotDesign(color: .violet, nickname: "Pip", fill: .colorBody, signature: .mic)
    let json = try JSONSerialization.data(withJSONObject: ["design": JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))])
    let loaded = try JSONDecoder().decode(AppSettings.self, from: json).design
    #expect(loaded.nickname == "Pip")
    #expect(Theme.forDesign(loaded) == Theme.forDesign(.default) && Accent.hex(for: loaded) == Accent.hex(for: .default))
}

@Test func aVioletMicChosenNowStaysVioletAfterRelaunch() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    var settings = AppSettings()
    settings.design = DotDesign.default.withNickname("Pip")
    settings.design.color = .violet  // the Violet swatch, picked on the logo
    try store.save(settings)
    let loaded = try store.load()
    #expect(loaded.design == settings.design && !loaded.design.isLogo)
}
