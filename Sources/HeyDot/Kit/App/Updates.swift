import Combine
import Foundation
import Sparkle

/// Self-updates through Sparkle, from the appcast named by `SUFeedURL` in Info.plist. Automatic checks are on by
/// default (`SUEnableAutomaticChecks`): HeyDot checks at every launch and Sparkle again once a day. Turning them off in
/// Settings stops both; "Check for Updates…" works either way.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var automaticChecksObservation: AnyCancellable?
    private var willInstallOnQuit = false

    /// Only a built app carries a feed URL, so tests, previews and `swift run` never start an updater.
    init(bundle: Bundle = .main) {
        super.init()
        guard Paths().usesSystemData, bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        automaticChecksObservation = controller.updater.publisher(for: \.automaticallyChecksForUpdates, options: .new)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // Sparkle's own schedule waits a day between checks; a launch is when a fix matters most.
        if controller.updater.automaticallyChecksForUpdates { controller.updater.checkForUpdatesInBackground() }
    }

    var canConfigureAutomaticChecks: Bool { controller != nil }

    var automaticChecksEnabled: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func check() { controller?.checkForUpdates(nil) }

    var isUpdating: Bool { willInstallOnQuit || controller?.updater.sessionInProgress == true }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        willInstallOnQuit = true
        return false
    }
}
