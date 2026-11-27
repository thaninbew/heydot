import AppKit
import Combine
import SwiftUI
import WakeEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let paths: Paths
    private let finishingErase: Bool
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let popoverActivity = PopoverActivity(visible: false)
    private var windows: [String: NSWindow] = [:]
    private var onboarding: OnboardingModel?
    private var watch: AnyCancellable?
    private var appearanceWatch: NSKeyValueObservation?
    private var control: ControlService?
    private var updates: Updates!

    init(paths: Paths, finishingErase: Bool) {
        self.paths = paths
        self.finishingErase = finishingErase
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            guard await finishPendingErase() else { NSApp.terminate(nil); return }
            installEditMenu()
            let store = SettingsStore(url: paths.settings)
            guard let settings = loadSettings(from: store) else { NSApp.terminate(nil); return }
            startProfile(settings: settings, store: store)
        }
    }

    private func loadSettings(from store: SettingsStore) -> AppSettings? {
        do { return try store.load() } catch {
            Log.shared.write("settings: \(error)")
        }

        var rebuildError: String?
        while true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            if let rebuildError {
                alert.messageText = "HeyDot couldn't rebuild its settings"
                alert.informativeText = rebuildError
                alert.addButton(withTitle: "Try Again")
            } else {
                alert.messageText = "HeyDot couldn't read its settings"
                alert.informativeText = "Rebuilding keeps a copy of the original file in HeyDot's Application Support folder and opens setup with fresh settings. Your ChatGPT sign-in is kept."
                alert.addButton(withTitle: "Rebuild Settings")
            }
            alert.addButton(withTitle: "Quit HeyDot").keyEquivalent = "\u{1b}"
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            do {
                return try store.rebuildUnreadable()
            } catch {
                rebuildError = error.localizedDescription
                Log.shared.write("settings: rebuild failed: \(error)")
            }
        }
    }

    private func startProfile(settings: AppSettings, store: SettingsStore) {
        model = AppModel(settings: settings, engine: WakeEngine(log: { Log.shared.write($0) }), enroller: Enroller(),
                         web: WebCallBackend(paths: paths), hooks: .live(paths: paths), store: store)
        updates = Updates()
        Log.shared.write("app: started, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            activity: popoverActivity, model: model,
            openDotMaker: { [weak self] in self?.showDotMaker() },
            openSettings: { [weak self] in self?.showSettings() },
            openOnboarding: { [weak self] in self?.showOnboarding() },
            signIn: { [weak self] in self?.popover.performClose(nil); self?.model.showSignIn() },
            troubleshoot: { [weak self] in self?.showTroubleshooter() },
            quit: { NSApp.terminate(nil) }).fontDesign(.rounded))

        watch = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.updateGlyph() }
        }
        // A colour icon is drawn for the bar's own appearance, which follows the wallpaper and Dark Mode.
        appearanceWatch = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateGlyph() }
        }
        updateGlyph()
        model.refreshListening()
        if paths.usesSystemData { model.warmWeb() }
        model.startKeepAlive()
        do { control = try ControlService(model: model, paths: paths) } catch { Log.shared.write("control: \(error)") }
        if !model.settings.onboarded { showOnboarding() }
    }

    /// Quitting (Command-Q included) mid-setup stops voice tuning and its microphone first. Settings are saved only
    /// as each step commits, and setup isn't marked done, so the next launch opens setup again.
    func applicationWillTerminate(_ notification: Notification) {
        onboarding?.shutDown()
        control?.stop(); model?.stop()
    }

    /// The new process holds the same lease. Finish the erase before starting any profile writers.
    private func finishPendingErase() async -> Bool {
        let pending = PendingErase(paths: paths)
        while true {
            do {
                return try await pending.eraseIfPending() || !finishingErase
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "HeyDot couldn't finish erasing its data"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Quit HeyDot")
                alert.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverActivity.visible = false
        ListenerUsage.shared.hide("popover")
    }

    private var lastGlyph: (DotDesign, GlyphState, MenuBarIcon, Bool)?
    func updateGlyph() {
        // A fresh success shows a check for a few seconds instead of a notification that has to be closed.
        let state = model.flashing && model.status.glyph == .listening ? GlyphState.ok : model.status.glyph
        let style = model.settings.menuBarIcon
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let last = lastGlyph, last.0 == model.settings.design, last.1 == state, last.2 == style, last.3 == dark { return }
        lastGlyph = (model.settings.design, state, style, dark)
        statusItem.button?.image = DotGlyph.image(model.settings.design, state: state, color: style == .color, darkBar: dark)
        statusItem.button?.toolTip = "HeyDot: \(model.statusLine)"
    }

    /// An accessory app shows no menu bar, but its main menu's key equivalents still work whenever one of its
    /// windows is key: Quit HeyDot (Command-Q), Close Window (Command-W) and the standard Edit commands.
    private func installEditMenu() { NSApp.mainMenu = Self.mainMenu() }

    static func mainMenu() -> NSMenu {
        func submenu(_ title: String, _ items: [(String, Selector, String)]) -> NSMenuItem {
            let item = NSMenuItem(), menu = NSMenu(title: title)
            for (title, action, key) in items { menu.addItem(withTitle: title, action: action, keyEquivalent: key) }
            item.submenu = menu
            return item
        }
        let main = NSMenu()
        main.addItem(submenu("HeyDot", [("Quit HeyDot", #selector(NSApplication.terminate(_:)), "q")]))
        main.addItem(submenu("File", [("Close Window", #selector(NSWindow.performClose(_:)), "w")]))
        main.addItem(submenu("Edit", [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                                      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                      ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")]))
        return main
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        // The usage readout samples only while the popover is open (also driven by the view's onAppear).
        popoverActivity.visible = true
        ListenerUsage.shared.show("popover")
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Windows

    /// `frosted`: Frost's see-through window (setup), with the content running to the top edge under the
    /// traffic lights.
    private func present<V: View>(_ key: String, title: String, view: V, resizable: Bool = false, frosted: Bool = false) {
        popover.performClose(nil)
        if let window = windows[key] {
            window.contentViewController = NSHostingController(rootView: view.fontDesign(.rounded))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.fontDesign(.rounded)))
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .resizable, .miniaturizable] : [.titled, .closable]
        if frosted {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[key] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A closed window keeps nothing running: its SwiftUI content (float and drift layers, the tuning rings, the
    /// listener readout) is released, and closing setup mid-way stops voice tuning and its microphone.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key else { return }
        if key == "onboarding", let flow = onboarding {
            flow.leave(flow.step)
            onboarding = nil
        }
        if key == "troubleshoot" { troubleshooter?.stop(); troubleshooter = nil }
        DispatchQueue.main.async { if !window.isVisible { window.contentViewController = nil } }
    }

    private func close(_ key: String) { windows[key]?.close() }

    func showOnboarding(startAt step: OnboardingStep = .welcome) {
        let flow = OnboardingModel(app: model)
        flow.step = step
        flow.returnAfterTuning = step == .voice
        flow.openDotMaker = { [weak self] in self?.showDotMaker() }
        flow.finish = { [weak self] in self?.onboarding = nil; self?.close("onboarding") }
        onboarding = flow
        present("onboarding", title: "Welcome to HeyDot", view: OnboardingView(flow: flow), frosted: true)
        flow.enter(step)
    }

    func showDotMaker() {
        present("dotmaker", title: "Design your dot", view: DotMakerView(
            draft: model.settings.design, menuBarIcon: model.settings.menuBarIcon,
            onSave: { [weak self] design, icon in
                self?.model.update { $0.design = design; $0.menuBarIcon = icon }
                self?.close("dotmaker")
            },
            onCancel: { [weak self] in self?.close("dotmaker") }), resizable: true, frosted: true)
    }

    private var troubleshooter: Troubleshooter?

    /// "Not working?": checks each step a call takes and offers the fix for the first one that fails.
    func showTroubleshooter() {
        troubleshooter?.stop()
        let doctor = Troubleshooter(app: model)
        troubleshooter = doctor
        present("troubleshoot", title: "Not working?", view: TroubleshootView(
            doctor: doctor, model: model,
            retune: { [weak self] in self?.close("troubleshoot"); self?.showOnboarding(startAt: .voice) },
            signIn: { [weak self] in self?.model.showSignIn() },
            close: { [weak self] in self?.close("troubleshoot") }), frosted: true)
        doctor.start()
    }

    func showSettings() {
        present("settings", title: "HeyDot Settings", view: SettingsView(
            model: model, updates: updates,
            retune: { [weak self] in self?.showOnboarding(startAt: .voice) },
            openDotMaker: { [weak self] in self?.showDotMaker() },
            eraseAndRestart: { [weak self] in try self?.eraseAndRestart() }), resizable: true, frosted: true)
    }

    private func eraseAndRestart() throws {
        guard !updates.isUpdating else { throw RestartError.updateInProgress }
        try UninstallData.validateWebKitStore(paths: paths)
        guard let executable = Bundle.main.executableURL else { throw RestartError.executableMissing }
        let successor = Process()
        successor.executableURL = executable
        successor.arguments = [PendingErase.relaunchArgument]
        try successor.run()
        do { try PendingErase(paths: paths).request() } catch {
            successor.terminate()
            throw error
        }
        onboarding?.shutDown()
        troubleshooter?.stop()
        control?.stop()
        model.stop()
        statusItem.button?.isEnabled = false
        popover.performClose(nil)
        windows.values.forEach { $0.orderOut(nil) }
        Task {
            await model.web.prepareForErase()
            NSApp.terminate(nil)
        }
    }

    private enum RestartError: LocalizedError {
        case executableMissing, updateInProgress

        var errorDescription: String? {
            switch self {
            case .executableMissing: "HeyDot couldn't find its executable to reopen setup."
            case .updateInProgress: "Finish updating HeyDot, then try again. If an update is waiting to install, quit and reopen HeyDot first."
            }
        }
    }

}
