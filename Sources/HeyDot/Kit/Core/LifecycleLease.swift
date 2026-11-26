import Foundation

/// A kernel-owned lease, released even on a crash. Keep its inode outside the data directory so
/// uninstall cannot unlink a held lock and admit a second app halfway through removal.
final class LifecycleLease {
    private let fd: Int32
    init(paths: Paths, role: String, waitForQuit: Bool = false) throws {
        let parent = paths.lifecycleDirectory
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent(".HeyDot-\(role).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let operation = LOCK_EX | (waitForQuit ? 0 : LOCK_NB)
        while flock(descriptor, operation) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            if code == .EINTR { continue }
            Foundation.close(descriptor)
            throw POSIXError(code)
        }
        fd = descriptor
    }
    deinit { Foundation.close(fd) }
}
