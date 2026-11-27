import AVFoundation
import AppKit
import Foundation
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@MainActor @Test func wakeUsesTheBuiltInBrowserAndIgnoresWakesDuringACall() async {
    let web = FakeWeb()
    var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: QARender.fakeHooks(), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    await model.call()
    #expect(web.calls == ["https://chatgpt.com/dots/sol"])
    #expect(model.lastResult?.pressed == true)
    web.inCall = true
    #expect(model.status == .calling)
    model.handleWake(WakeEvent(phrase: "hey dot", at: Date()))
    await Task.yield()
    #expect(web.calls.count == 1)
    web.outcome = "signed-out"; web.inCall = false
    await model.call()
    #expect(model.status == .signInNeeded)
    model.handleWake(WakeEvent(phrase: "hey dot", at: Date()))
    for _ in 0..<20 { await Task.yield() }
    let callsAfterWake = web.calls.count
    #expect(callsAfterWake == 3)
    for _ in 0..<8 { model.handleWake(WakeEvent(phrase: "hey dot", at: Date())) }
    for _ in 0..<20 { await Task.yield() }
    #expect(web.calls.count == callsAfterWake)  // cooldown still applies after a fast failure
}

@MainActor private final class PendingCallWeb: WebCalling {
    var inCall = false
    var onCallChange: ((String?) -> Void)?
    var calls = 0
    var pending: CheckedContinuation<CallResult, Never>?
    func call(dotURL: String, wakeAt: Date) async -> CallResult {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func check(dotURL: String) async -> CallResult { CallResult(outcome: "would-press") }
    func endCall() { inCall = false }
    func warm(dotURL: String?) {}
    func pageState() async -> WebPageState { WebPageState(signedIn: nil) }
    func showChatGPT(pickingDot: Bool, onClose: @escaping (DotTab?) -> Void) {}
    func signOut() async {}
}

@MainActor @Test func overlappingCallsAreRejectedAndQuitDropsLateResults() async throws {
    let web = PendingCallWeb()
    var settings = AppSettings(); settings.dotURL = "https://chatgpt.com/dots/test"; settings.onboarded = true
    let model = AppModel(settings: settings, engine: FakeEngine(), enroller: FakeEnroller(),
                         web: web, hooks: QARender.fakeHooks(), store: nil,
                         log: Log(url: URL(fileURLWithPath: "/dev/null")))
    let first = Task { await model.call() }
    while web.pending == nil { await Task.yield() }
    await model.call()
    #expect(web.calls == 1)
    model.stop()
    web.pending?.resume(returning: CallResult(outcome: "pressed")); web.pending = nil
    await first.value
    #expect(!model.calling && model.lastResult == nil)
    await model.call()
    #expect(web.calls == 1)
}

@MainActor @Test func reloadFreesAHungCallAndAFailedCallRechecksSignIn() async {
    let web = HungWeb()
    var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: QARender.fakeHooks(), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    let hung = Task { await model.call() }
    while web.calls == 0 { await Task.yield() }
    #expect(model.calling && !model.canCallNow)
    model.reloadWeb()
    #expect(web.resets == 1 && !model.calling && model.canCallNow)
    web.hang = false
    await model.call()
    #expect(model.lastResult?.pressed == true)
    web.release(); await hung.value
    #expect(model.lastResult?.pressed == true)       // the stale press can't overwrite the newer result
    // A "not found" that is really a lapsed sign-in ends on Sign in, not on a dead Call button.
    web.hang = true; web.signedIn = false
    let failing = Task { await model.call() }
    while web.calls < 3 { await Task.yield() }
    web.release(); await failing.value
    for _ in 0..<20 { await Task.yield() }
    #expect(model.status == .signInNeeded)
}

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
    func showChatGPT(pickingDot: Bool, onClose: @escaping (DotTab?) -> Void) {}
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

@MainActor @Test func theStarCardAsksOnceAfterThreeCallsThatStarted() async {
    let web = FakeWeb()
    var opened: [URL] = []
    var hooks = QARender.fakeHooks()
    hooks.openURL = { opened.append($0) }
    var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
    let model = AppModel(settings: s, engine: FakeEngine(), enroller: FakeEnroller(), web: web,
                         hooks: hooks, store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    web.outcome = "not-found"
    await model.call()                       // a call that didn't start doesn't count
    web.outcome = "pressed"
    for _ in 0..<2 { await model.call() }
    #expect(!model.asksForStar)
    await model.call()
    #expect(model.asksForStar)
    model.answerStarCard(star: true)
    #expect(opened == [AppModel.repository])
    #expect(!model.asksForStar)
    await model.call()
    #expect(model.settings.callsStarted == 3)  // counting stops once it's answered
}
