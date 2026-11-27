import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@Test func callViewStaysOnChatGPTAndSignInStaysOnHTTPS() {
    func allows(_ s: String, main: Bool = true, call: Bool) -> Bool { WebCallBackend.allowsNavigation(to: URL(string: s), mainFrame: main, callView: call) }
    #expect(allows("https://chatgpt.com/dots/sol", call: true))
    #expect(!allows("https://auth.openai.com/log-in", call: true))
    #expect(!allows("https://evil.example/chatgpt.com", call: true))
    #expect(!allows("http://chatgpt.com/", call: true))
    #expect(allows("https://challenges.cloudflare.com/x", main: false, call: true))  // the page's own frames
    #expect(allows("https://accounts.google.com/o/oauth2", call: false))
    #expect(!allows("http://accounts.google.com/", call: false))
    #expect(WebCallBackend.keepsData(for: "chatgpt.com") && WebCallBackend.keepsData(for: "openai.com"))
    #expect(!WebCallBackend.keepsData(for: "google.com") && !WebCallBackend.keepsData(for: "apple.com"))
}

@Test func microphoneIsGrantedOnlyToChatGPTDuringACall() {
    func allow(_ scheme: String = "https", host: String = "chatgpt.com", port: Int = 0, frame: String = "chatgpt.com",
               type: WKMediaCaptureType = .microphone, call: Bool = true, active: Bool = true) -> Bool {
        WebCallBackend.allowsMicrophone(origin: (scheme, host, port), frameHost: frame, type: type, callView: call, active: active)
    }
    #expect(allow())
    #expect(!allow(active: false))                 // not placing or in a call
    #expect(!allow(call: false))                   // the sign-in window never gets the mic
    #expect(!allow(type: .camera))
    #expect(!allow(type: .cameraAndMicrophone))
    #expect(!allow("http"))
    #expect(!allow(host: "evil.example"))
    #expect(!allow(host: "chatgpt.com.evil.example"))
    #expect(!allow(port: 8443))
    #expect(!allow(frame: "ads.example"))          // an embedded third-party frame
}

@Test func builtInPressScriptFailsClosed() throws {
    let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", NSHomeDirectory() + "/.local/bin/node"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let node else { print("skipped: node not found"); return }
    let dir = try tempDir()
    let harness = """
    const press = async (dotPath, label, click) => { \(PageScripts.press) };
    const cases = [];
    function page({ host = "chatgpt.com", path = "/dots/sol", buttons = [["Start call"]], links = [], title = "ChatGPT", text = "hello", visible = true }) {
      const made = buttons.map(([label, disabled = false, attrs = {}]) => ({ clicked: 0, disabled, textContent: "",
        getAttribute: (k) => (k === "aria-label" ? label : (attrs[k] ?? null)), click() { this.clicked++; } }));
      globalThis.__heyDotProfileOpenedAt = 0;
      globalThis.location = { host, pathname: path, href: "https://" + host + path };
      globalThis.document = { title, body: { innerText: text }, visibilityState: visible ? "visible" : "hidden",
        querySelector: () => null,
        querySelectorAll: (sel) => sel === "button" ? made
          : [...made, ...links.map((label) => ({ textContent: label, getAttribute: () => null }))] };
      return made;
    }
    const run = async (name, spec, click, want, wantClicks = want === "pressed" ? 1 : 0) => {
      const made = page(spec);
      const got = (await press("/dots/sol", "Start call", click)).outcome;
      const clicks = made.reduce((n, b) => n + b.clicked, 0);
      cases.push({ name, got, want, clicks, wantClicks });
    };
    await run("presses", {}, true, "pressed");
    await run("check only", {}, false, "would-press");
    await run("trailing slash", { path: "/dots/sol/" }, true, "pressed");
    await run("hidden page waits", { visible: false }, true, "not-visible");
    await run("other dot", { path: "/dots/tray" }, true, "wrong-dot");
    await run("other host", { host: "example.com" }, true, "wrong-dot");
    await run("login host", { host: "auth.openai.com" }, true, "signed-out");
    await run("login page", { path: "/auth/login" }, true, "signed-out");
    await run("login buttons", { buttons: [["Log in"], ["Start call"]] }, true, "signed-out");
    await run("login link", { buttons: [], links: ["Log in"] }, true, "signed-out");
    await run("two buttons", { buttons: [["Start call"], ["Start call"]] }, true, "ambiguous");
    await run("disabled", { buttons: [["Start call", true]] }, true, "disabled");
    await run("near label", { buttons: [["Start call now"]] }, true, "not-found");
    await run("cloudflare title", { title: "Just a moment..." }, true, "challenge");
    await run("cloudflare text", { text: "Verify you are human" }, true, "challenge");
    await run("opens the profile", { buttons: [["Open sol’s profile"]] }, true, "not-found", 1);
    await run("profile already open", { buttons: [["Open sol’s profile", false, { "aria-expanded": "true" }]] }, true, "not-found", 0);
    await run("two profiles", { buttons: [["Open sol’s profile"], ["Open sol's profile"]] }, true, "not-found", 0);
    await run("call toggle on", { buttons: [["Start call", false, { "aria-pressed": "true" }]] }, true, "disabled");
    console.log(JSON.stringify(cases));
    """
    let file = dir.appendingPathComponent("harness.mjs")
    try harness.write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [file.path]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let cases = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [[String: Any]] ?? []
    #expect(cases.count == 19)
    for c in cases {
        let name = c["name"] as? String ?? "?", got = c["got"] as? String, want = c["want"] as? String
        #expect(got == want, "\(name): \(got ?? "nil") != \(want ?? "nil")")
        #expect((c["clicks"] as? Int ?? -1) == (c["wantClicks"] as? Int ?? -2), "\(name) clicked wrongly")
    }
    try? FileManager.default.removeItem(at: dir)
}

@Test func browserSelectionRequiresASpecificChatGPTDot() {
    let result = DotTab.conversation(at: URL(string: "https://chatgpt.com/dots/one/?src=test#top"), title: "One")
    #expect(result == DotTab(url: "https://chatgpt.com/dots/one", title: "One"))
    for raw in ["https://chatgpt.com/dots", "https://chatgpt.com/c/other", "https://example.com/dots/one"] {
        #expect(DotTab.conversation(at: URL(string: raw), title: nil) == nil)
    }
}

@MainActor @Test func returnInTheSignInWindowNeverPressesDone() {
    _ = NSApplication.shared
    func pressesOnReturn<V: View>(_ make: (@escaping () -> Void) -> V) -> Bool {
        var fired = false
        let window = KeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: make { fired = true })
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = window.performKeyEquivalent(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.orderOut(nil)
        return fired
    }
    // The harness does see a default button take Return...
    #expect(pressesOnReturn { done in Button("Done", action: done).keyboardShortcut(.defaultAction).padding() })
    // ...and the sign-in window's Done is not one.
    #expect(!pressesOnReturn { done in SignInView(web: nil, state: SignInState(), done: done) })
}

@Test func googlesEmbeddedBrowserRefusalIsDetected() {
    #expect(WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://accounts.google.com/v3/signin/rejected?continue=x")))
    #expect(WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://accounts.google.com/signin/rejected")))
    #expect(!WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://accounts.google.com/v3/signin/identifier")))
    #expect(!WebCallBackend.refusesEmbeddedSignIn(URL(string: "https://chatgpt.com/rejected")))
}

@Test func webCryptoKeyIsMadeOnceAndPrivate() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = Paths(home: home)
    let first = try #require(WebCryptoKey.load(paths: paths))
    #expect(first.count == 16)
    #expect(WebCryptoKey.load(paths: paths) == first)
    let mode = try FileManager.default.attributesOfItem(atPath: WebCryptoKey.url(paths).path)[.posixPermissions] as? NSNumber
    #expect(mode?.int16Value == 0o600)
    try Data([1, 2, 3]).write(to: WebCryptoKey.url(paths))   // a damaged key is replaced, not used
    let second = try #require(WebCryptoKey.load(paths: paths))
    #expect(second.count == 16 && second != first)
}
