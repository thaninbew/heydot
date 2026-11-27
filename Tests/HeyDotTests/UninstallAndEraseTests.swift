import AppKit
import Foundation
import Testing
@testable import HeyDotKit
@testable import WakeEngine

@MainActor @Test func uninstallDataRemovesOnlyHeyDotsOwnData() async throws {
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
    #expect(await UninstallData.run(arguments: ["--keep-logs"], paths: paths, hooks: hooks, out: { lines.append($0) }, err: { _ in }) == 0)
    #expect(!fm.fileExists(atPath: paths.support.path) && !fm.fileExists(atPath: webkit.deletingLastPathComponent().path))
    #expect(fm.fileExists(atPath: paths.log.path))
    #expect(await UninstallData.run(arguments: [], paths: paths, hooks: hooks, out: { _ in }, err: { _ in }) == 0)
    #expect(!fm.fileExists(atPath: paths.log.path))
    hooks.running = { _ in true }
    #expect(await UninstallData.run(arguments: [], paths: paths, hooks: hooks, out: { _ in }, err: { _ in }) == 1)
}

@MainActor @Test func confirmedEraseRemovesProfileAndCanBeRetried() async throws {
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
    let bundleID = paths.bundleID
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

    #expect(try await !pending.eraseIfPending())
    #expect(try store.load() == settings)
    #expect(owned.allSatisfy { fm.fileExists(atPath: $0.path) })
    try pending.request()
    #expect(throws: POSIXError.self) { try pending.request() }

    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    let external = home.appendingPathComponent("another-library", isDirectory: true)
    try fm.moveItem(at: caches, to: external)
    try fm.createSymbolicLink(at: caches, withDestinationURL: external)
    await #expect(throws: UninstallData.RemovalError.self) { try await pending.eraseIfPending() }
    #expect(try pending.isPending())
    #expect(try store.load() == settings)
    #expect(owned.allSatisfy { fm.fileExists(atPath: $0.path) })

    try fm.removeItem(at: caches)
    try fm.moveItem(at: external, to: caches)
    #expect(try await pending.eraseIfPending())
    #expect(try store.load() == AppSettings())
    #expect(owned.allSatisfy { !fm.fileExists(atPath: $0.path) })
    #expect(preserved.allSatisfy { fm.fileExists(atPath: $0.path) })
    #expect(try !pending.isPending())
    #expect(try await !pending.eraseIfPending())
}

@MainActor @Test func erasePreservesTheRunningAppEvenThroughABundleSymlink() async throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    let fm = FileManager.default
    let bundle = paths.support.appendingPathComponent("HeyDot.app", isDirectory: true)
    let executable = bundle.appendingPathComponent("Contents/MacOS/HeyDot")
    let link = home.appendingPathComponent("HeyDot.app")
    try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("app fixture".utf8).write(to: executable)
    try fm.createSymbolicLink(at: link, withDestinationURL: bundle)
    let settings = SettingsStore(url: paths.settings)
    var previous = AppSettings()
    previous.rename("Tray")
    try settings.save(previous)

    let hooks = UninstallData.Hooks(bundleURL: link)
    await #expect(throws: UninstallData.RemovalError.self) { try await UninstallData.erase(paths: paths, hooks: hooks) }
    #expect(fm.fileExists(atPath: executable.path))
    #expect(try settings.load() == previous)
}

@MainActor @Test func noncanonicalLaunchCannotUseTheRealProfileOrConsumeAnotherBundlesPendingErase() async throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path
    let unbundled = Paths(bundleIdentifier: nil, environment: [:])
    let otherBundle = "app.heydot.fixture.second"
    let redirectedToRealHome = Paths(bundleIdentifier: otherBundle, environment: ["HEYDOT_HOME": realHome])
    #expect(!unbundled.allowsProfileAccess)
    #expect(!redirectedToRealHome.allowsProfileAccess)
    #expect(await UninstallData.run(arguments: [], paths: unbundled, err: { _ in }) == 1)

    let launcher = Paths(home: home, bundleIdentifier: "app.heydot.fixture.first", environment: [:])
    let otherLauncher = Paths(home: home, bundleIdentifier: otherBundle, environment: [:])
    try FileManager.default.createDirectory(at: launcher.lifecycleDirectory, withIntermediateDirectories: true)
    let request = PendingErase(paths: launcher)
    try request.request()
    #expect(try await !PendingErase(paths: otherLauncher).eraseIfPending())
    #expect(try request.isPending())
}

@MainActor @Test func lifecycleLeaseExcludesDuplicatesAndMaintenance() async throws {
    let root = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(home: root)
    var lease: LifecycleLease? = try LifecycleLease(paths: paths, role: "app")
    #expect(throws: POSIXError.self) { try LifecycleLease(paths: paths, role: "app") }
    #expect(await UninstallData.run(arguments: ["HeyDot", "--uninstall-data"], paths: paths, out: { _ in }, err: { _ in }) == 1)
    withExtendedLifetime(lease) {}
    lease = nil
    let second = try LifecycleLease(paths: paths, role: "app")
    withExtendedLifetime(second) {}
}
