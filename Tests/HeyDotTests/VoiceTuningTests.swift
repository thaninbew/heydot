import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@MainActor private func tuningFlow(mic: AVAuthorizationStatus = .authorized) -> (OnboardingModel, RecordingTuner, () -> Void) {
    let m = QARender.model({ $0.onboarded = false }, mic: mic)
    let tuner = RecordingTuner()
    let f = OnboardingModel(app: m, tuner: tuner)
    var clock = Date(timeIntervalSince1970: 1_000)
    f.now = { clock }
    f.step = .voice
    f.enter(.voice)
    return (f, tuner, { clock.addTimeInterval(1) })
}

@MainActor @Test func tuningWaitsForStartAndNeverStartsWithoutPermission() {
    let (f, tuner, _) = tuningFlow()
    #expect(tuner.starts.isEmpty && !f.listening, "entering the step must not open the microphone")
    f.startListening()
    #expect(tuner.starts.count == 1 && f.listening && f.tuningStarted)
    for status in [AVAuthorizationStatus.notDetermined, .denied] {
        let (g, t, _) = tuningFlow(mic: status)
        #expect(g.stage == .permission)
        g.startListening()
        #expect(t.starts.isEmpty && !g.listening)
    }
}

@MainActor @Test func noBuffersOrDigitalSilenceStopWithNoAudioButAQuietRoomOnlyHints() {
    // No buffer at all within 3 s (the round-1 capture bound to a dead I/O unit): stop and offer Try again.
    var (f, tuner, tick) = tuningFlow()
    f.startListening()
    tick(); tick(); f.checkSilence()
    #expect(f.problem == nil, "2 s is not yet a dead microphone")
    tick(); f.checkSilence()
    #expect(f.problem == .noAudio && !f.listening && tuner.stopped > 0)
    f.startListening()
    #expect(f.problem == nil && f.listening && tuner.starts.count == 2, "Try again reopens it")

    // Buffers that are pure digital silence, as without a working microphone: the same.
    (f, tuner, tick) = tuningFlow()
    f.startListening()
    for _ in 0..<3 { tuner.onLevel?(-160, false); tick() }
    f.checkSilence()
    #expect(f.problem == .noAudio)

    // A real but quiet room (noise floor, no speech): keep listening, with a hint after 10 s.
    (f, tuner, tick) = tuningFlow()
    f.startListening()
    for _ in 0..<10 { tuner.onLevel?(-62, false); tick(); f.checkSilence() }
    #expect(f.problem == .quiet && f.listening)
    tuner.onLevel?(-20, true)
    #expect(f.problem == nil, "speech clears the hint")
}

@MainActor @Test func tuningCountsTheUsersOwnWayOfSayingThePhrase() {
    let (f, _, _) = tuningFlow()
    f.startListening()
    // The model hears this speaker's "Hey Dot" as "Hey Daughter": their way, so it counts.
    f.heard(take("HEY DAUGHTER"))
    #expect(f.positives.count == 1 && f.hint == "Got it.")
    f.heard(take("HEY JOHN"))
    #expect(f.positives.count == 1, "a take unlike the others is not counted")
    #expect(f.hint?.contains("different from your others") == true && f.hint?.contains("name") == false)
    f.heard(take("", level: 0.001))
    #expect(f.hint?.contains("quiet") == true)
    f.heard(take(""))
    #expect(f.hint?.contains("catch anything") == true)
    f.heard(take("I M MAKING A CUP OF COFFEE"))
    #expect(f.hint?.contains("longer") == true && f.positives.count == 1)
    for words in ["HEY DAUGHTER", "HAY DOTTER", "HEY DOT"] { f.heard(take(words)) }
    #expect(f.positives.count == 4 && f.stage == .ready && !f.listening, "four agreeing takes are everything tuning needs")
}

@MainActor @Test func eachSampleCanBeRetriedAndStartOverClearsEverything() {
    let (f, tuner, _) = tuningFlow()
    f.startListening()
    for i in 0..<4 { f.heard(take("HEY DOT", level: 0.1 * Float(i + 1))) }
    f.heard(take("HEY JOHN"))
    f.retry(phrase: 1)
    #expect(f.positives.count == 3 && f.positives[1].first == 0.3 && f.stage == .phrase, "only that sample is cleared")
    f.heard(take("HEY DOT"))
    f.calibration = Tuning(settings: WakeSettings(), caught: 4, falseHits: 0, note: "")
    f.retry(phrase: 0)
    #expect(f.calibration == nil, "a retry invalidates the old result")
    #expect(f.canStartOver)
    let starts = tuner.starts.count
    f.startOver()
    #expect(f.positives.isEmpty && f.calibration == nil && f.hint == nil)
    #expect(tuner.starts.count == starts + 1 && f.listening, "listening restarts from the first wake phrase")
    #expect(!f.canStartOver)
}
