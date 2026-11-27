import AVFoundation
import Foundation
import Testing
import WakeEngine
@testable import HeyDotKit

@MainActor
private final class MicrophoneFixture {
    var status: AVAuthorizationStatus
    var requests = 0
    var response: (@Sendable (Bool) -> Void)?
    var promptShown: CheckedContinuation<Void, Never>?
    var openedURLs: [URL] = []
    let engine = FakeEngine()

    init(_ status: AVAuthorizationStatus) { self.status = status }

    func model(onboarded: Bool = true) -> AppModel {
        var settings = AppSettings()
        settings.dotURL = "https://chatgpt.com/dots/tray"
        settings.onboarded = onboarded
        let hooks = SystemHooks(setLaunchAtLogin: { _ in }, launchAtLoginEnabled: { false },
                                microphoneStatus: { self.status }, requestMicrophone: { completion in
                                    self.requests += 1
                                    self.response = completion
                                    self.promptShown?.resume()
                                    self.promptShown = nil
                                }, openURL: { self.openedURLs.append($0) })
        return AppModel(settings: settings, engine: engine, enroller: Enroller(), hooks: hooks,
                        store: nil, log: Log(url: URL(fileURLWithPath: "/dev/null")))
    }

    func waitForPrompt() async {
        guard response == nil else { return }
        await withCheckedContinuation { promptShown = $0 }
    }
}

@MainActor @Test(arguments: [AVAuthorizationStatus.notDetermined, .denied, .restricted])
private func launchAndSetupCompletionNeverAskWithoutMicrophoneAuthorization(authorization: AVAuthorizationStatus) {
    let existing = MicrophoneFixture(authorization)
    let launched = existing.model()
    launched.refreshListening()
    #expect(existing.engine.startedOn.isEmpty)
    #expect(existing.requests == 0)
    #expect(launched.status == (authorization == .notDetermined ? .micAccessNeeded : .micDenied))
    let state = authorization == .notDetermined ? "mic_permission_needed" : "mic_denied"
    #expect(launched.controlState["state"] == .string(state))
    #expect(launched.controlState["wake"] == .null)
    #expect(launched.canCallNow)

    let fresh = MicrophoneFixture(authorization)
    let setup = fresh.model(onboarded: false)
    setup.refreshListening()
    #expect(setup.saveSetup { $0.onboarded = true })
    #expect(fresh.engine.startedOn.isEmpty)
    #expect(fresh.requests == 0)
    #expect(setup.status == launched.status)
}

@MainActor @Test(arguments: [true, false])
private func microphonePromptWaitsWithoutBlockingAndRespectsPause(paused: Bool) async throws {
    let microphone = MicrophoneFixture(.notDetermined)
    let model = microphone.model()
    model.refreshListening()
    let request = Task { await model.requestMicrophoneAccess() }
    await microphone.waitForPrompt()
    #expect(model.requestingMicrophoneAccess)
    #expect(model.status == .micAccessNeeded)
    #expect(microphone.engine.startedOn.isEmpty)
    let repeatedRequest = Task { await model.requestMicrophoneAccess() }
    if paused { model.pause(until: nil) }
    microphone.status = .authorized
    let respond = try #require(microphone.response)
    respond(true)
    await request.value
    await repeatedRequest.value

    #expect(microphone.requests == 1)
    #expect(!model.requestingMicrophoneAccess)
    #expect(model.status == (paused ? .paused : .listening))
    #expect(microphone.engine.startedOn.count == (paused ? 0 : 1))
}

@MainActor @Test
private func microphonePermissionChangesInSystemSettingsAreAppliedOnReturn() {
    let microphone = MicrophoneFixture(.denied)
    let model = microphone.model()
    model.refreshListening()
    model.openMicrophoneSettings()
    #expect(microphone.openedURLs.first?.query == "Privacy_Microphone")
    #expect(microphone.requests == 0)

    microphone.status = .authorized
    model.refreshMicrophoneAccess()
    #expect(model.status == .listening)
    #expect(microphone.engine.isListening)
    model.refreshMicrophoneAccess()
    #expect(microphone.engine.startedOn.count == 1)

    microphone.status = .denied
    model.refreshMicrophoneAccess()
    #expect(model.status == .micDenied)
    #expect(!microphone.engine.isListening)
}

@MainActor @Test
private func previouslyAuthorizedProfileListensAtLaunch() {
    let microphone = MicrophoneFixture(.authorized)
    let model = microphone.model()
    model.refreshListening()
    #expect(model.status == .listening)
    #expect(microphone.engine.isListening)
    #expect(microphone.requests == 0)
}

@MainActor @Test func microphoneChoiceReachesTheListenerAndPersists() throws {
    let home = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let (model, engine) = readyModel(home: home)
    #expect(engine.startedOn == [nil])  // built-in by default
    model.update { $0.inputDeviceUID = "AppleUSBAudioEngine:Mic" }
    #expect(engine.startedOn == [nil, "AppleUSBAudioEngine:Mic"])  // takes effect at once
    #expect(try SettingsStore(url: Paths(home: home).settings).load().inputDeviceUID == "AppleUSBAudioEngine:Mic")
    model.update { $0.inputDeviceUID = nil }
    #expect(engine.startedOn.last == .some(nil))
}
