import AVFoundation
import AppKit
import Foundation
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

/// "Not working?" walks the call path in order and stops at the first failure; it never places a call, and it
/// hands wakes and listening back when it ends.
@MainActor @Test func troubleshooterStopsAtTheFirstBrokenStepAndNeverCalls() async {
    func run(mic: AVAuthorizationStatus = .authorized, level: Float, wake: Bool, outcome: String = "would-press",
             signedIn: Bool? = true) async -> (Troubleshooter, HungWeb, FakeEngine, AppModel) {
        let web = HungWeb(); web.hang = false; web.signedIn = signedIn; web.checkOutcome = outcome
        let engine = FakeEngine(); engine.inputLevel = level
        var s = AppSettings(); s.onboarded = true; s.dotURL = "https://chatgpt.com/dots/sol"
        let model = AppModel(settings: s, engine: engine, enroller: FakeEnroller(), web: web,
                             hooks: QARender.fakeHooks(mic: mic), store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
        let doctor = Troubleshooter(app: model)
        doctor.hearTimeout = .milliseconds(300); doctor.phraseTimeout = .milliseconds(300)
        doctor.start()
        if wake {
            while doctor.state(.phrase) != .running { await Task.yield() }
            model.handleWake(WakeEvent(phrase: "hey sol", at: Date()))
        }
        while doctor.running { try? await Task.sleep(for: .milliseconds(20)) }
        return (doctor, web, engine, model)
    }
    let denied = await run(mic: .denied, level: -20, wake: false)
    #expect(denied.0.failed == .microphoneAccess && denied.0.state(.listening) == .waiting)
    let silent = await run(level: -160, wake: false)
    #expect(silent.0.failed == .hearing)
    let missed = await run(level: -20, wake: false)
    #expect(missed.0.failed == .phrase)
    let button = await run(level: -20, wake: true, outcome: "not-found")
    #expect(button.0.failed == .callButton)
    let fine = await run(level: -20, wake: true)
    #expect(fine.0.done && fine.0.failed == nil)
    #expect(fine.1.calls == 0)                                  // saying the phrase during the check placed no call
    #expect(fine.3.wakeOverride == nil)                         // wakes go back to calls afterwards
}

@MainActor @Test func troubleshootingReportCopiesOnlyVersionAndAllowlistedCodes() throws {
    let dotName = "PrivateDot"
    let dotURL = "https://chatgpt.com/dots/private-conversation"
    let device = "PrivateAudioDevice"
    let email = "private-person@example.com"
    let path = "/Users/private-person/Library/Logs/HeyDot.log"
    let auth = "private-auth-token"
    let audio = "private-speech"
    let privateValues = [dotName, dotURL, device, email, path, auth, audio]
    let privateDetail = privateValues.joined(separator: "\n")
    let app = QARender.model {
        $0.dotName = dotName
        $0.dotURL = dotURL
        $0.inputDeviceUID = device
    }
    let doctor = Troubleshooter(app: app)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let failures: [(Troubleshooter.Step, Troubleshooter.Problem, String, String)] = [
        (.listening, .engine, "listening", "listener-failed"),
        (.callButton, .callButton, "call-button", "call-button-unavailable"),
    ]
    for (step, problem, stepCode, reasonCode) in failures {
        doctor.setFixture([step: .problem(problem, privateDetail)])
        #expect(doctor.copyReport(to: pasteboard))
        let report = try #require(pasteboard.string(forType: .string))
        let fields = report.split(separator: "\n")
        try #require(fields.count == 3)
        #expect(fields[0].hasSuffix(version))
        #expect(fields[1].hasSuffix(stepCode))
        #expect(fields[2].hasSuffix(reasonCode))
        #expect(privateValues.allSatisfy { !report.contains($0) })
        #expect(pasteboard.pasteboardItems?.map(\.types) == [[.string]])
    }
}

@MainActor @Test func troubleshootingReportLeavesClipboardAloneUntilACompletedFailure() {
    let doctor = Troubleshooter(app: QARender.model())
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    #expect(pasteboard.setString("existing clipboard text", forType: .string))
    let changeCount = pasteboard.changeCount

    #expect(!doctor.copyReport(to: pasteboard))
    doctor.setFixture([.microphoneAccess: .problem(.micDenied, "Permission not granted")], running: true)
    #expect(!doctor.copyReport(to: pasteboard))
    doctor.setFixture(Dictionary(uniqueKeysWithValues: Troubleshooter.Step.allCases.map { ($0, .ok("Passed")) }))
    #expect(!doctor.copyReport(to: pasteboard))
    #expect(pasteboard.changeCount == changeCount)
}
