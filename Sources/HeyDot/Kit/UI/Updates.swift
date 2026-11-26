import Combine
import Foundation
import Sparkle

/// Self-updates through Sparkle, from the appcast named by `SUFeedURL` in Info.plist. Sparkle asks once, on the
/// second launch, before it checks automatically; "Check for Updates…" in Settings works either way.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var willInstallOnQuit = false

    /// Only a built app carries a feed URL, so tests, previews and `swift run` never start an updater.
    init(bundle: Bundle = .main) {
        super.init()
        guard Paths().usesSystemData, bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
    }

    func check() { controller?.checkForUpdates(nil) }

    var isUpdating: Bool { willInstallOnQuit || controller?.updater.sessionInProgress == true }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        willInstallOnQuit = true
        return false
    }
}
