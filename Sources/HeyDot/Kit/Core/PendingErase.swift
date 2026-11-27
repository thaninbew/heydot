import Foundation

/// A confirmed erase survives a crash and prevents a partially erased profile from opening.
struct PendingErase {
    static let relaunchArgument = "--finish-erase"
    let paths: Paths

    // Outside Application Support/HeyDot, beside the app lease held by both processes.
    private var marker: URL { paths.lifecycleDirectory.appendingPathComponent(".HeyDot-erase-pending-\(paths.profileIdentity)") }

    func isPending() throws -> Bool {
        guard let type = try Paths.itemType(at: marker) else { return false }
        guard try paths.validateRemovalParents(of: marker), type == S_IFREG else { throw POSIXError(.EINVAL) }
        return true
    }

    func request() throws {
        guard paths.allowsProfileAccess else { throw UninstallData.ProfileAccessError() }
        try UninstallData.validateErase(paths: paths)
        guard try paths.validateRemovalParents(of: marker) else { throw POSIXError(.ENOENT) }
        let fd = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
    }

    func finishIfPending() throws {
        if try isPending() { try FileManager.default.removeItem(at: marker) }
    }

    @MainActor func eraseIfPending() async throws -> Bool {
        guard try isPending() else { return false }
        try await UninstallData.erase(paths: paths)
        try FileManager.default.removeItem(at: marker)
        return true
    }
}
