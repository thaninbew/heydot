import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@MainActor @Test func mainMenuQuitsClosesAndEdits() {
    let menu = AppDelegate.mainMenu()
    let items = menu.items.compactMap(\.submenu).flatMap(\.items)
    func item(_ key: String) -> NSMenuItem? { items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command } }
    #expect(item("q")?.action == #selector(NSApplication.terminate(_:)))
    #expect(item("w")?.action == #selector(NSWindow.performClose(_:)))
    for (key, action) in [("x", "cut:"), ("c", "copy:"), ("v", "paste:"), ("a", "selectAll:"), ("z", "undo:")] {
        #expect(item(key)?.action == Selector(action), "Command-\(key.uppercased())")
    }
    #expect(items.contains { $0.keyEquivalent == "Z" && $0.action == Selector(("redo:")) })
}

@MainActor @Test func settingsScrollsAtItsSmallestWindowSize() async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: SettingsView(model: QARender.model(), retune: {}, openDotMaker: {}, eraseAndRestart: {})
        .frame(width: 560, height: SettingsView.minimumHeight))
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: SettingsView.minimumHeight),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
    let scroll = try #require(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    let content = try #require(scroll.documentView).frame.height
    #expect(content > scroll.contentView.bounds.height + 100, "Settings is taller than its smallest window")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: content - scroll.contentView.bounds.height))
    #expect(scroll.contentView.bounds.origin.y > 100, "and scrolls to its last section")
    window.orderOut(nil)
}
