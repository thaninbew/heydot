import AppKit
import Testing
@testable import HeyDotKit

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
