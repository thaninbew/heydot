import Combine
import Sparkle

/// Self-updates through Sparkle, from the appcast named by `SUFeedURL` in Info.plist. Sparkle asks once, on the
/// second launch, before it checks automatically; "Check for Updates…" in Settings works either way.
@MainActor
final class Updates: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?

    /// Only a built app carries a feed URL, so tests, previews and `swift run` never start an updater.
    init(bundle: Bundle = .main) {
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
    }

    func check() { controller?.checkForUpdates(nil) }
}
