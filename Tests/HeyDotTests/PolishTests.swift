import AppKit
import Foundation
import Testing
@testable import WakeEngine
@testable import HeyDotKit

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heydot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: Headphones on eared shapes

@Test func headphonesNeverCoverOrCutTheEars() {
    for shape in [DotShape.circleTwoEars, .roundedHeadTwoEars] {
        let face = DotArt.face(of: shape)
        guard let ears = face.ears else { Issue.record("\(shape) has no ears"); continue }
        let body = DotArt.layers(DotDesign(shape: shape, accessory: .headphones)).first { $0.role == .body }!.path
        // Every bit of ear is still body: nothing covers it and no gutter is cut into it (sampled every half unit).
        let box = ears.boundingBoxOfPath
        var lost = 0
        for x in stride(from: box.minX, through: box.maxX, by: 0.5) {
            for y in stride(from: box.minY, through: box.maxY, by: 0.5) {
                // Points within 0.3 of the ear's outline are boundary noise, not a cut.
                let inside = [(0.0, 0.0), (0.3, 0), (-0.3, 0), (0, 0.3), (0, -0.3)].allSatisfy { ears.contains(CGPoint(x: x + $0.0, y: y + $0.1)) }
                if inside && !body.contains(CGPoint(x: x, y: y)) { lost += 1 }
            }
        }
        #expect(lost == 0, "\(shape): headphones cover or cut \(lost) sampled points of the ears")
    }
}

// MARK: Transient results, Call now, mute

@MainActor final class MuteWeb: WebCalling {
    var inCall = false
    var onCallChange: ((String?) -> Void)?
    var outcome = "pressed"
    var microphoneMuted: Bool?
    var muteWorks = true
    func call(dotURL: String, wakeAt: Date) async -> CallResult { CallResult(outcome: outcome) }
    func check(dotURL: String) async -> CallResult { CallResult(outcome: outcome == "pressed" ? "would-press" : outcome) }
    func setMicrophoneMuted(_ muted: Bool) async -> Bool { if muteWorks { microphoneMuted = muted }; return muteWorks }
    func endCall() { inCall = false }
    func warm(dotURL: String?) {}
    func pageState() async -> WebPageState { WebPageState(signedIn: true) }
    func showSignIn(onClose: @escaping () -> Void) {}
    func signOut() async {}
}

@MainActor private func model(_ web: MuteWeb) -> AppModel {
    var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
    let m = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                     hooks: QARender.fakeHooks(), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    m.successLifetime = .milliseconds(60)
    return m
}

@MainActor @Test func successesClearThemselvesAndProblemsStayUntilReplaced() async throws {
    let web = MuteWeb()
    let m = model(web)
    m.update { $0.paused = true }
    await m.callNow()  // a call you start yourself works while listening is paused
    #expect(m.lastResult?.pressed == true && m.flashing)
    // Other tests share the main actor, so wait for the expiry rather than a fixed time.
    for _ in 0..<150 where m.lastResult != nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(m.lastResult == nil && !m.flashing)
    await m.checkCallButton()
    #expect(m.lastResult?.wouldPress == true)
    #expect(m.status == .paused)  // a passing check is never reported as a failure
    web.outcome = "not-found"
    await m.checkCallButton()
    try await Task.sleep(for: .milliseconds(200))
    #expect(m.lastResult?.outcome == "not-found")  // problems stay
    web.outcome = "pressed"
    await m.callNow()
    #expect(m.lastResult?.pressed == true)  // and a later result replaces them
}

@MainActor @Test func muteIsOfferedOnlyForALiveBuiltInCallAndShowsTheRealState() async {
    let web = MuteWeb()
    let m = model(web)
    #expect(!m.canMute)
    web.inCall = true; web.microphoneMuted = false
    #expect(m.canMute && !m.muted)
    await m.setMuted(true)
    #expect(m.muted)
    web.muteWorks = false
    await m.setMuted(false)
    #expect(m.muted && m.lastResult?.outcome == "mute-failed")  // fails closed: still shows muted
}


// MARK: Custom avatar import

@MainActor @Test func avatarImportValidatesAndMakesAMenuBarSilhouette() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let saved = Avatars.directory
    Avatars.directory = dir.appendingPathComponent("avatars")
    defer { Avatars.directory = saved }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name); try text.write(to: url, atomically: true, encoding: .utf8); return url
    }
    let good = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
      <path fill="#0A0A0B" fill-rule="evenodd" d="M16 52a32 32 0 1 0 64 0a32 32 0 1 0 -64 0Z M35 46h10v18h-10Z M51 46h10v18h-10Z"/>
      <g id="eyes"><rect x="35" y="46" width="10" height="18" rx="5" fill="#C6E82B"/><rect x="51" y="46" width="10" height="18" rx="5" fill="#C6E82B"/></g>
    </svg>
    """
    let imported = try Avatars.importFile(try file("good.svg", good))
    #expect(imported.art.silhouette)
    // The eyes are drawn in colour but are holes in the monochrome mask.
    let color = try #require(Avatars.image(imported.art.id)), mask = try #require(Avatars.image(imported.art.id, .template))
    func alpha(_ image: NSImage, _ x: Int, _ y: Int) -> CGFloat {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.colorAt(x: x * rep.pixelsWide / 96, y: y * rep.pixelsHigh / 96)?.alphaComponent ?? 0
    }
    // Import trims the margins and fits the art to 90 of 96 units: the circle (16...80) grows by 90/64.
    #expect(alpha(color, 37, 52) > 0.9 && alpha(mask, 37, 52) < 0.1)  // eye centre (40, 55) before fitting
    #expect(alpha(mask, 48, 17) > 0.9)  // the body, (48, 30) before fitting, is solid in both
    for bad in [good.replacingOccurrences(of: "<g id=\"eyes\">", with: "<script>alert(1)</script><g id=\"eyes\">"),
                good.replacingOccurrences(of: "fill=\"#0A0A0B\"", with: "fill=\"url(https://example.com/x)\""),
                good.replacingOccurrences(of: "<path", with: "<image href=\"file:///etc/passwd\"/><path"),
                "<?xml version=\"1.0\"?><!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" + good,
                "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 50\"><rect width=\"300\" height=\"50\"/></svg>"] {
        #expect(throws: Avatars.Rejected.self) { try Avatars.importFile(try file("bad.svg", bad)) }
    }
    // An opaque PNG has no silhouette: the monochrome menu bar falls back to the logo.
    let square = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        NSColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 1).setFill(); rect.fill(); return true
    }
    let rep = NSBitmapImageRep(data: square.tiffRepresentation!)!
    let png = dir.appendingPathComponent("square.png")
    try rep.representation(using: .png, properties: [:])!.write(to: png)
    #expect(try !Avatars.importFile(png).art.silhouette)
}

// MARK: Clean uninstall

@Test func uninstallDataRemovesOnlyHeyDotsOwnData() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    let fm = FileManager.default
    let webkit = home.appendingPathComponent("Library/WebKit/app.heydot.HeyDot/WebsiteDataStore", isDirectory: true)
    for dir in [paths.support, webkit, paths.log.deletingLastPathComponent()] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try Data("{}".utf8).write(to: paths.settings)
    try Data("log".utf8).write(to: paths.log)
    var lines: [String] = []
    var hooks = UninstallData.Hooks(running: { _ in false }, loginItemEnabled: { false }, removeLoginItem: {}, bundleID: "app.heydot.HeyDot")
    #expect(UninstallData.run(arguments: ["--keep-logs"], paths: paths, hooks: hooks, out: { lines.append($0) }, err: { _ in }) == 0)
    #expect(!fm.fileExists(atPath: paths.support.path) && !fm.fileExists(atPath: webkit.deletingLastPathComponent().path))
    #expect(fm.fileExists(atPath: paths.log.path))
    #expect(UninstallData.run(arguments: [], paths: paths, hooks: hooks, out: { _ in }, err: { _ in }) == 0)
    #expect(!fm.fileExists(atPath: paths.log.path))
    hooks.running = { _ in true }
    #expect(UninstallData.run(arguments: [], paths: paths, hooks: hooks, out: { _ in }, err: { _ in }) == 1)
}

@Test func confirmedEraseRemovesProfileAndCanBeRetried() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    let pending = PendingErase(paths: paths)
    let store = SettingsStore(url: paths.settings)
    var settings = AppSettings()
    settings.rename("Tray")
    settings.onboarded = true
    try store.save(settings)
    let fm = FileManager.default
    let bundleID = Bundle.main.bundleIdentifier ?? "app.heydot.HeyDot"
    let owned = [
        paths.support.appendingPathComponent("settings.json.reset-20260101"),
        paths.support.appendingPathComponent("avatars/avatar.png"),
        paths.support.appendingPathComponent("run/old.sock"),
        WebCryptoKey.url(paths),
        paths.log,
        URL(fileURLWithPath: paths.log.path + ".1"),
        home.appendingPathComponent("Library/WebKit/\(bundleID)/WebsiteDataStore/session"),
        home.appendingPathComponent("Library/Caches/\(bundleID)/org.sparkle-project.Sparkle/update"),
        home.appendingPathComponent("Library/HTTPStorages/\(bundleID).binarycookies"),
        home.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
        home.appendingPathComponent("Library/Preferences/ByHost/\(bundleID).\(UUID().uuidString).plist"),
        home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState/window"),
    ]
    let preserved = [
        home.appendingPathComponent("Applications/HeyDot.app/Contents/MacOS/HeyDot"),
        home.appendingPathComponent("Library/WebKit/OtherApp/session"),
        home.appendingPathComponent("Library/Preferences/\(bundleID).other.plist"),
        home.appendingPathComponent("Library/Logs/OtherApp.log"),
    ]
    for url in owned + preserved {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }
    let link = paths.support.appendingPathComponent("external")
    try fm.createSymbolicLink(at: link, withDestinationURL: preserved[0])

    #expect(try !pending.eraseIfPending())
    #expect(try store.load() == settings)
    #expect(owned.allSatisfy { fm.fileExists(atPath: $0.path) })
    try pending.request()
    #expect(throws: POSIXError.self) { try pending.request() }

    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    let external = home.appendingPathComponent("another-library", isDirectory: true)
    try fm.moveItem(at: caches, to: external)
    try fm.createSymbolicLink(at: caches, withDestinationURL: external)
    #expect(throws: UninstallData.RemovalError.self) { try pending.eraseIfPending() }
    #expect(try pending.isPending())
    #expect(try store.load() == settings)
    #expect(owned.allSatisfy { fm.fileExists(atPath: $0.path) })

    try fm.removeItem(at: caches)
    try fm.moveItem(at: external, to: caches)
    #expect(try pending.eraseIfPending())
    #expect(try store.load() == AppSettings())
    #expect(owned.allSatisfy { !fm.fileExists(atPath: $0.path) })
    #expect(preserved.allSatisfy { fm.fileExists(atPath: $0.path) })
    #expect(try !pending.isPending())
    #expect(try !pending.eraseIfPending())
}
