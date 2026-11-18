import AppKit
import Foundation

public enum HeyDotMain {
    /// App entry. Developer flags render fixtures and icons without touching settings or login items:
    /// `--qa-render DIR` (screenshots), `--render-icon DIR` (1024 master and iconset), `--qa-boards DIR` (DIR/fit accessory and glasses grids, DIR/logos-v2 logo board).
    /// `--reset-onboarding` moves settings.json aside (kept as a timestamped backup) so setup starts over.
    /// `--uninstall-data [--keep-logs] [--dry-run]` removes everything HeyDot stores, for a clean reinstall.
    /// `--qa-signin DIR` renders the sign-in window over the live, logged-out chatgpt.com (throwaway store).
    @MainActor
    public static func run(arguments: [String]) -> Int32 {
        if let code = ControlCLI.run(arguments: arguments) { return code }
        if let i = arguments.firstIndex(of: "--qa-render"), i + 1 < arguments.count {
            let dir = URL(fileURLWithPath: arguments[i + 1])
            return arguments.contains("--logo-only") ? QARender.renderLogo(into: dir) : QARender.run(into: dir)
        }
        if let i = arguments.firstIndex(of: "--qa-boards"), i + 1 < arguments.count {
            _ = NSApplication.shared
            let root = URL(fileURLWithPath: arguments[i + 1])
            do {
                try DotBoards.renderFit(into: root.appendingPathComponent("fit"))
                try DotBoards.renderLogosV2(into: root.appendingPathComponent("logos-v2"))
                return 0
            } catch {
                FileHandle.standardError.write(Data("qa-boards failed: \(error)\n".utf8)); return 1
            }
        }
        if arguments.contains("--reset-onboarding") { return resetOnboarding() }
        if arguments.contains("--uninstall-data") { return UninstallData.run(arguments: arguments) }
        if let i = arguments.firstIndex(of: "--qa-signin"), i + 1 < arguments.count {
            return QARender.renderSignIn(into: URL(fileURLWithPath: arguments[i + 1]))
        }
        if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
            return QARender.renderIcon(into: URL(fileURLWithPath: arguments[i + 1]))
        }
        let lease: LifecycleLease
        do { lease = try LifecycleLease(paths: Paths(), role: "app") }
        catch { return 1 }
        defer { withExtendedLifetime(lease) {} }
        // LaunchServices normally coalesces launches, but direct executable launches need the lease too.
        if ProcessInfo.processInfo.environment["HEYDOT_HOME"] == nil,
           NSRunningApplication.runningApplications(withBundleIdentifier: "app.heydot.HeyDot")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { return 1 }
        guard !ControlSocket.isHelperRunning(socket: Paths().controlSocket) else { return 1 }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        return 0
    }

    /// Refuses while the app runs (it would write the file straight back). Login item,
    /// microphone permission and the built-in browser's sign-in are left as they are.
    static func resetOnboarding(paths: Paths = Paths(), running: (URL) -> Bool = { ControlSocket.isHelperRunning(socket: $0) }) -> Int32 {
        let leases: [LifecycleLease]
        do { leases = try [LifecycleLease(paths: paths, role: "app")] }
        catch {
            FileHandle.standardError.write(Data("HeyDot: quit HeyDot before resetting onboarding.\n".utf8))
            return 1
        }
        defer { withExtendedLifetime(leases) {} }
        if running(paths.controlSocket) {
            FileHandle.standardError.write(Data("HeyDot: quit HeyDot first (menu bar > Quit HeyDot), then run --reset-onboarding again.\n".utf8))
            return 1
        }
        do {
            guard let backup = try SettingsStore(url: paths.settings).moveAside() else {
                print("No settings at \(paths.settings.path); the next launch already starts setup.")
                return 0
            }
            print("Moved settings to \(backup.path) (kept). The next launch starts setup from the beginning.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("HeyDot: couldn't move the settings aside: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
