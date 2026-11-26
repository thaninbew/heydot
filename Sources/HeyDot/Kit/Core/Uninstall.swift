import CoreFoundation
import Foundation
import Security
import ServiceManagement

/// Clears the same local profile for a clean uninstall and for Erase and Start Over.
enum UninstallData {
    struct Hooks {
        var running: (URL) -> Bool = { ControlSocket.isHelperRunning(socket: $0) }
        var loginItemEnabled: () -> Bool = {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        var removeLoginItem: () throws -> Void = { try SMAppService.mainApp.unregister() }
        var bundleID = Bundle.main.bundleIdentifier ?? "app.heydot.HeyDot"
    }

    struct RemovalError: LocalizedError {
        let item: String
        let cause: Error

        var errorDescription: String? { "Couldn't remove \(item): \(cause.localizedDescription)" }
    }

    /// Call only while holding the app lease and before starting any profile writers.
    static func erase(paths: Paths, hooks: Hooks = Hooks(), dryRun: Bool = false, keepLogs: Bool = false,
                      out: (String) -> Void = { _ in }) throws {
        let bundleID = hooks.bundleID
        guard bundleID.range(of: "^[a-zA-Z0-9][a-zA-Z0-9.-]*$", options: .regularExpression) != nil else {
            throw POSIXError(.EINVAL)
        }
        let library = paths.home.appendingPathComponent("Library", isDirectory: true)
        let prefs = library.appendingPathComponent("Preferences", isDirectory: true)
        let byHost = prefs.appendingPathComponent("ByHost", isDirectory: true)
        var targets = [
            paths.support,
            library.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true),
            library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true),
            prefs.appendingPathComponent("\(bundleID).plist"),
        ]
        if !keepLogs { targets.append(contentsOf: [paths.log, URL(fileURLWithPath: paths.log.path + ".1")]) }
        let fm = FileManager.default
        let hasByHost = try removal("HeyDot preferences") {
            try paths.validateRemovalParents(of: byHost.appendingPathComponent(bundleID))
        }
        if hasByHost {
            targets += try removal("HeyDot preferences") {
                let prefix = bundleID + ".", suffix = ".plist"
                return try fm.contentsOfDirectory(atPath: byHost.path).filter { name in
                    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
                    return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
                }.map { byHost.appendingPathComponent($0) }
            }
        }
        var existing: [URL] = []
        for url in targets {
            if try removal(url.path, {
                guard try paths.validateRemovalParents(of: url), let type = try Paths.itemType(at: url) else { return false }
                // cfprefsd can access these files by name; stop before calling it on a redirected plist.
                if url.path.hasPrefix(prefs.path + "/"), type != S_IFREG { throw POSIXError(.EINVAL) }
                return true
            }) { existing.append(url) }
        }

        let verb = dryRun ? "Would remove" : "Removed"
        var removed = 0
        if paths.usesSystemData, hooks.loginItemEnabled() {
            if !dryRun { try removal("the login item", hooks.removeLoginItem) }
            out("\(verb) the login item (Open at login)")
            removed += 1
        }
        if paths.usesSystemData && !dryRun {
            if try removal("HeyDot's WebCrypto keychain item", { try removeLegacyWebCryptoKey(bundleID: bundleID) }) {
                out("\(verb) HeyDot's WebCrypto keychain item")
                removed += 1
            }
            if try removal("HeyDot preferences", { try clearPreferences(bundleID: bundleID) }) {
                out("\(verb) HeyDot's preferences")
                removed += 1
            }
        }
        for url in existing {
            try removal(url.path) {
                if !dryRun {
                    // The native preferences API may already have removed the plist.
                    if try Paths.itemType(at: url) == nil { return }
                    try fm.removeItem(at: url)
                }
                out("\(verb) \(url.path)")
                removed += 1
            }
        }
        if removed == 0 { out("Nothing to remove: HeyDot has no data on this Mac.") }
    }

    /// WebKit uses a local generic password keyed by this exact app-specific account.
    /// https://github.com/WebKit/WebKit/blob/main/Source/WebCore/crypto/cocoa/SerializedCryptoKeyWrapCocoa.mm
    private static func removeLegacyWebCryptoKey(bundleID: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "com.apple.WebKit.WebCrypto.master+\(bundleID)",
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Clear through cfprefsd so either host domain can't restore Sparkle's stored settings.
    private static func clearPreferences(bundleID: String) throws -> Bool {
        let app = bundleID as CFString
        let user = kCFPreferencesCurrentUser
        var removed = false
        for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
            guard CFPreferencesSynchronize(app, user, host) else { throw POSIXError(.EIO) }
            let keys = CFPreferencesCopyKeyList(app, user, host)
            guard let keys, CFArrayGetCount(keys) > 0 else { continue }
            CFPreferencesSetMultiple(nil, keys, app, user, host)
            guard CFPreferencesSynchronize(app, user, host) else { throw POSIXError(.EIO) }
            removed = true
        }
        return removed
    }

    private static func removal<T>(_ item: String, _ work: () throws -> T) throws -> T {
        do { return try work() } catch { throw RemovalError(item: item, cause: error) }
    }

    static func run(arguments: [String], paths: Paths = Paths(), hooks: Hooks = Hooks(),
                    out: (String) -> Void = { print($0) }, err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        let dry = arguments.contains("--dry-run"), keepLogs = arguments.contains("--keep-logs")
        let lease: LifecycleLease
        do { lease = try LifecycleLease(paths: paths, role: "app") }
        catch { err("HeyDot: quit HeyDot before removing data."); return 1 }
        defer { withExtendedLifetime(lease) {} }
        if hooks.running(paths.controlSocket) {
            err("HeyDot: quit HeyDot first (menu bar > Quit HeyDot), then run --uninstall-data again.")
            return 1
        }
        do {
            try erase(paths: paths, hooks: hooks, dryRun: dry, keepLogs: keepLogs, out: out)
            if !dry { try PendingErase(paths: paths).finishIfPending() }
        } catch {
            err("HeyDot: \(error.localizedDescription)")
            return 1
        }
        out(keepLogs && FileManager.default.fileExists(atPath: paths.log.path) ? "Kept the log at \(paths.log.path) (--keep-logs)." : "Kept nothing.")
        out("macOS still remembers the microphone permission. To reset it too: tccutil reset Microphone \(hooks.bundleID)")
        return 0
    }
}

extension Paths {
    /// Check from home outward so cleanup never follows a symlink in a shared Library directory.
    /// A link at the target itself is safe to unlink.
    func validateRemovalParents(of url: URL) throws -> Bool {
        let base = home.pathComponents
        let target = url.pathComponents
        guard target.count > base.count, target.starts(with: base) else { throw POSIXError(.EINVAL) }
        var parent = home
        for component in target.dropFirst(base.count).dropLast() {
            guard component != ".", component != ".." else { throw POSIXError(.EINVAL) }
            parent.appendPathComponent(component, isDirectory: true)
            guard let type = try Self.itemType(at: parent) else { return false }
            guard type == S_IFDIR else { throw POSIXError(type == S_IFLNK ? .ELOOP : .ENOTDIR) }
        }
        return true
    }

    static func itemType(at url: URL) throws -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.st_mode & S_IFMT
    }
}
