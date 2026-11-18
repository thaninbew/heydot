import Foundation
import ServiceManagement

/// `HeyDot --uninstall-data [--keep-logs] [--dry-run]`: removes everything HeyDot keeps on this Mac so a
/// reinstall starts at the welcome screen, and prints exactly what it removed.
///
/// Removed: settings and their reset backups, imported avatars and the run directory (all of
/// Application Support/HeyDot), the built-in browser's sign-in store and WebKit caches, the login item, and the log (unless kept).
enum UninstallData {
    struct Hooks {
        var running: (URL) -> Bool = { ControlSocket.isHelperRunning(socket: $0) }
        /// A redirected home (`HEYDOT_HOME`, smoke tests) never touches the real login item.
        var loginItemEnabled: () -> Bool = {
            ProcessInfo.processInfo.environment["HEYDOT_HOME"] == nil && SMAppService.mainApp.status == .enabled
        }
        var removeLoginItem: () throws -> Void = { try SMAppService.mainApp.unregister() }
        var bundleID = Bundle.main.bundleIdentifier ?? "app.heydot.HeyDot"
    }

    static func run(arguments: [String], paths: Paths = Paths(), hooks: Hooks = Hooks(),
                    out: (String) -> Void = { print($0) }, err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        let dry = arguments.contains("--dry-run"), keepLogs = arguments.contains("--keep-logs")
        let leases: [LifecycleLease]
        do { leases = try [LifecycleLease(paths: paths, role: "app")] }
        catch { err("HeyDot: quit HeyDot before removing data."); return 1 }
        defer { withExtendedLifetime(leases) {} }
        if hooks.running(paths.controlSocket) {
            err("HeyDot: quit HeyDot first (menu bar > Quit HeyDot), then run --uninstall-data again.")
            return 1
        }
        let verb = dry ? "Would remove" : "Removed"
        var removed = 0, failures = 0
        let fm = FileManager.default

        if hooks.loginItemEnabled() {
            do { if !dry { try hooks.removeLoginItem() }; out("\(verb) the login item (Open at login)"); removed += 1 }
            catch { err("HeyDot: couldn't remove the login item: \(error.localizedDescription)"); return 1 }
        }

        let library = paths.home.appendingPathComponent("Library", isDirectory: true)
        var targets = [
            paths.support,
            library.appendingPathComponent("WebKit/\(hooks.bundleID)", isDirectory: true),
            library.appendingPathComponent("Caches/\(hooks.bundleID)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(hooks.bundleID)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(hooks.bundleID).binarycookies"),
            library.appendingPathComponent("Saved Application State/\(hooks.bundleID).savedState", isDirectory: true),
            library.appendingPathComponent("Preferences/\(hooks.bundleID).plist"),
        ]
        if !keepLogs { targets.append(contentsOf: [paths.log, URL(fileURLWithPath: paths.log.path + ".1")]) }
        for url in targets where fm.fileExists(atPath: url.path) {
            do { if !dry { try fm.removeItem(at: url) }; out("\(verb) \(url.path)"); removed += 1 }
            catch { err("HeyDot: couldn't remove \(url.path): \(error.localizedDescription)"); failures += 1 }
        }

        if removed == 0 && failures == 0 { out("Nothing to remove: HeyDot has no data on this Mac.") }
        out(keepLogs && fm.fileExists(atPath: paths.log.path) ? "Kept the log at \(paths.log.path) (--keep-logs)." : "Kept nothing.")
        out("macOS still remembers the microphone permission. To reset it too: tccutil reset Microphone \(hooks.bundleID)")
        return failures == 0 ? 0 : 1
    }

}
