import AVFoundation
import AppKit
import CoreAudio
import Darwin
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

/// Opt-in foreground probe: HEYDOT_RESOURCE_PROBE=1 swift test --filter resourceProbe.
/// Local HTML only. Never opens ChatGPT, requests a microphone, or installs a service.
@MainActor @Test func resourceProbe() async throws {
    guard ProcessInfo.processInfo.environment["HEYDOT_RESOURCE_PROBE"] == "1" else { return }
    _ = NSApplication.shared
    let backend = WebCallBackend(log: Log(url: URL(fileURLWithPath: "/dev/null")), store: .nonPersistent())
    var lastCPU = 0.0, lastWall = ProcessInfo.processInfo.systemUptime
    func snapshot(_ label: String) {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = ProcessInfo.processInfo.systemUptime
        let percent = (cpu - lastCPU) / max(0.001, wall - lastWall) * 100
        lastCPU = cpu; lastWall = wall
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        var threads: thread_act_array_t?; var n: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threads, &n) == KERN_SUCCESS, let threads {
            for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(n) * MemoryLayout<thread_t>.size))
        }
        FileHandle.standardOutput.write(Data("RESOURCE \(label) pid=\(getpid()) rss=\(info.resident_size) threads=\(n) cpu=\(percent)\n".utf8))
    }
    let html = """
    <body><button>Start call</button><div style='width:500px;height:500px;background:linear-gradient(red,blue);animation:spin 1s linear infinite'></div>
    <style>@keyframes spin{to{transform:rotate(360deg)}}</style>
    <script>window.ticks=0;setInterval(()=>{window.ticks++;document.title='tick '+window.ticks},10);function frame(){requestAnimationFrame(frame)};frame()</script>
    """
    let navigation = FixtureNavigation()
    backend.ensureView().navigationDelegate = navigation
    backend.ensureView().loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com/dots/fixture"))
    try await Task.sleep(for: .seconds(2))
    snapshot("idle-start")
    let idleSamples = Int(ProcessInfo.processInfo.environment["HEYDOT_RESOURCE_IDLE_SAMPLES"] ?? "10") ?? 10
    for i in 0..<idleSamples {
        try await Task.sleep(for: .seconds(30))
        snapshot("idle-\((i + 1) * 30)s")
    }
    var pressed = 0
    for i in 0..<50 {
        navigation.allowHTML = true
        backend.ensureView().navigationDelegate = navigation
        backend.ensureView().loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com/dots/fixture"))
        try await Task.sleep(for: .milliseconds(100))
        let loadedBy = Date().addingTimeInterval(10)
        while backend.ensureView().isLoading && Date() < loadedBy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!backend.ensureView().isLoading)
        // Simulate foreground visibility in the isolated world; this fixture never requests media.
        _ = try await backend.ensureView().callAsyncJavaScript("Object.defineProperty(document, 'visibilityState', {get: () => 'visible', configurable: true}); return true", in: nil, contentWorld: .defaultClient)
        let result = await backend.call(dotURL: "https://chatgpt.com/dots/fixture", wakeAt: Date())
        if result.pressed { pressed += 1 }
        backend.endCall()
        if i % 10 == 9 { snapshot("calls-\(i+1)") }
    }
    #expect(pressed == 50)
    print("RESOURCE fixture-pressed=\(pressed)")
    let model = QARender.model()
    let activity = PopoverActivity(visible: false)
    let popover = NSPopover()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    popover.contentViewController = NSHostingController(rootView: PopoverView(activity: activity, model: model, openDotMaker: {}, openSettings: {}, openOnboarding: {}, quit: {}))
    for _ in 0..<100 {
        activity.visible = true
        if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        ListenerUsage.shared.show("popover")
        try await Task.sleep(for: .milliseconds(20))
        popover.performClose(nil)
        activity.visible = false
        ListenerUsage.shared.hide("popover")
    }
    NSStatusBar.system.removeStatusItem(item)
    snapshot("popover-100")
    for _ in 0..<20 {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
    }
    snapshot("wake-events-20")
    try await Task.sleep(for: .seconds(35))
    snapshot("settled")
}

@MainActor @Test func usageTimerStopsAfterLastViewerAndReleasesOwner() async throws {
    var usage: ListenerUsage? = ListenerUsage()
    weak var weakUsage = usage
    usage?.show("popover"); usage?.show("tuning")
    #expect(usage?.isSampling == true)
    usage?.hide("popover")
    #expect(usage?.isSampling == true)
    usage?.hide("tuning")
    #expect(usage?.isSampling == false)
    let history = usage?.history
    try await Task.sleep(for: .milliseconds(1100))
    #expect(usage?.history == history)
    usage?.show("popover")
    usage = nil
    #expect(weakUsage == nil)
}

@MainActor @Test func listenerUsageIsListenerCPUPerWallSecond() {
    let usage = ListenerUsage()
    var cpu = 10.0, wall = 100.0
    usage.cpuSeconds = { cpu }; usage.uptime = { wall }; usage.bytes = { 18 * 1_048_576 }
    usage.sample()
    cpu = 10.008; wall = 102
    usage.sample()
    #expect(abs((usage.latest?.cpu ?? 0) - 0.4) < 0.0001)
    #expect(usage.latest?.megabytes == 18)
    #expect(ListenerUsage.describe(usage.latest!) == "Listener: 0.4% CPU \u{00B7} ~18 MB")
}

@Test func listenerMeterCountsOnlyMeasuredWork() {
    let before = ListenerMeter.cpuSeconds
    var x = 0.0
    for i in 0..<2_000_000 { x += sqrt(Double(i)) }  // outside the meter
    #expect(ListenerMeter.cpuSeconds == before)
    #expect(x > 0)
}

@Test func logsAreBoundedIncludingOversizedMessages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("log")
    try Data(repeating: 65, count: Log.maximumBytes * 3).write(to: url)
    let log = Log(url: url)
    for _ in 0..<400 { log.write(String(repeating: "x", count: 10_000)) }
    for path in [url.path, url.path + ".1"] {
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int
        #expect(size <= Log.maximumBytes)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
}

@MainActor @Test func hiddenWebViewExpiresAndCanBeReleasedRepeatedly() async throws {
    _ = NSApplication.shared
    let backend = WebCallBackend(log: Log(url: URL(fileURLWithPath: "/dev/null")), store: .nonPersistent())
    backend.idleLifetime = .milliseconds(20)
    weak var old: WKWebView?
    do { let view = backend.ensureView(); old = view }
    let deadline = Date().addingTimeInterval(5)
    while old?.superview != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(old?.superview == nil)
    for _ in 0..<50 {
        let view = backend.ensureView()
        backend.discardIdleView()
        #expect(view.superview == nil)
        #expect(view.navigationDelegate == nil && view.uiDelegate == nil)
    }
}

private final class ResourceCapture: AudioCapturing, @unchecked Sendable {
    let object = NSObject()
    var configurationObject: AnyObject? { object }
    var receive: (@Sendable (Clip) -> Void)?
    func start(receive: @escaping @Sendable (Clip) -> Void) throws { self.receive = receive; receive([0, 0]) }
    func stop() { receive = nil }
}

@MainActor @Test func twentyWakeDeviceCyclesKeepOneCaptureAndRemoveObservers() async throws {
    let center = NotificationCenter(), workspace = NotificationCenter()
    var inputChanged: (@MainActor () -> Void)?
    var captures: [ResourceCapture] = []
    // The device list changes every cycle, and the resolved device alternates, so each change restarts.
    var device = "BuiltInMicrophoneDevice"
    let supervisor = ListenerSupervisor(timing: .init(debounce: 0.001, maxBackoff: 0.005, stallAfter: 60, checkEvery: 60, healthyAfter: 60),
        resolveInput: { device }, makeCapture: { _ in let c = ResourceCapture(); captures.append(c); return c },
        center: center, workspace: workspace, distributed: NotificationCenter(),
        watchDevices: { changed in inputChanged = changed; return { inputChanged = nil } }, initialHolds: [])
    try supervisor.start { _ in }
    for cycle in 1...20 {
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: .AVAudioEngineConfigurationChange, object: captures.last!.object)
        device = device == "BuiltInMicrophoneDevice" ? "USB" : "BuiltInMicrophoneDevice"
        inputChanged?()
        let deadline = Date().addingTimeInterval(5)
        while supervisor.restarts < cycle && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(supervisor.restarts == cycle)
        #expect(captures.filter { $0.receive != nil }.count == 1)
    }
    #expect(supervisor.restarts == 20)
    supervisor.stop()
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(inputChanged == nil && captures.allSatisfy { $0.receive == nil })
    #expect(supervisor.restarts == 20)
}

/// Substitute HTML gets one local navigation. Reject backend reloads so the baseline's hang-up and
/// wake handlers cannot fetch the public site. This delegate exists only in the opt-in fixture.
@MainActor private final class FixtureNavigation: NSObject, WKNavigationDelegate {
    var allowHTML = true
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let allow = allowHTML; allowHTML = false
        decisionHandler(allow ? .allow : .cancel)
    }
}
