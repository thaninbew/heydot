import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@Test func settingsRoundTripWithPrivateMode() throws {
    let home = try tempDir()
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
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"dotName": "Tray", "paused": true}"#.utf8).write(to: store.url)
    let s = try store.load()
    #expect(s.dotName == "Tray" && s.paused && s.wake.phrase == "hey tray" && s.design == .default)
    try Data("not json".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
}

@MainActor @Test func legacySettingsKeepLoadingAndFollowTheCurrentDefaults() async throws {
    #expect(DotDesign.default.signature == .mic)
    let old = #"{"backend":"chrome","onboarded":true,"dotURL":"https://chatgpt.com/dots/sol","design":{"shape":"circle","color":"violet","eyes":"oval","glasses":"none","accessory":"none","accessoryColor":"charcoal","nickname":"","fill":"inkBody","signature":"hey"}}"#
    let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    #expect(s.design == .default)
    let previousMic = old.replacingOccurrences(of: "\"signature\":\"hey\"", with: "\"signature\":\"mic\"")
    #expect(try JSONDecoder().decode(AppSettings.self, from: Data(previousMic.utf8)).design == .default)
    #expect(s.onboarded && s.dotURL == "https://chatgpt.com/dots/sol")
    let web = FakeWeb()
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: QARender.fakeHooks(), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    await model.call()
    #expect(web.calls == ["https://chatgpt.com/dots/sol"])
    #expect(model.lastResult?.pressed == true)
}

@Test func rebuildingDamagedSettingsPreservesOriginalAndOtherData() throws {
    let home = try tempDir()
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
    let home = try tempDir()
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
    let home = try tempDir()
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

@Test func renamingResetsTuning() {
    var s = AppSettings()
    s.wake = WakeSettings(phrase: "hey dot", score: 3, threshold: 0.25)
    s.calibrationNote = "Caught 4 of 4"
    s.rename("Sol")
    #expect(s.wake == WakeSettings(phrase: "hey sol"))
    #expect(s.calibrationNote == nil)
}

@Test func resetOnboardingMovesSettingsAsideAndKeepsThem() throws {
    let home = try tempDir()
    let paths = Paths(home: home)
    var settings = AppSettings(); settings.onboarded = true
    try SettingsStore(url: paths.settings).save(settings)
    #expect(HeyDotMain.resetOnboarding(paths: paths, running: { _ in true }) == 1)  // refuses while the app runs
    #expect(FileManager.default.fileExists(atPath: paths.settings.path))
    #expect(HeyDotMain.resetOnboarding(paths: paths, running: { _ in false }) == 0)
    #expect(!FileManager.default.fileExists(atPath: paths.settings.path))
    let backups = try FileManager.default.contentsOfDirectory(atPath: paths.support.path).filter { $0.hasPrefix("settings.json.reset-") }
    #expect(backups.count == 1)
    let kept = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: paths.support.appendingPathComponent(backups[0])))
    #expect(kept.onboarded)
    #expect(try SettingsStore(url: paths.settings).load().onboarded == false)  // next launch starts setup
    #expect(HeyDotMain.resetOnboarding(paths: paths, running: { _ in false }) == 0)  // nothing left to move
}

@Test func privateDirectoriesAndNewParentsAre0700() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("heydot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let run = root.appendingPathComponent("HeyDot/run")
    try Paths.ensureDirectory(run, mode: 0o700)
    for dir in [run, run.deletingLastPathComponent()] {
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o700, "\(dir.lastPathComponent)")
    }
}
