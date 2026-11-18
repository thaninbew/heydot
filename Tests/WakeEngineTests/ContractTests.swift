import Testing
@testable import WakeEngine

@Test func defaultsMatchMeasuredOwnerSettings() {
    let settings = WakeSettings()
    #expect(settings.phrase == "hey dot" && settings.score == 2.0 && settings.threshold == 0.08)
}
