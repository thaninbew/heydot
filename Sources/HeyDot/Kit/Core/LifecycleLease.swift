import Foundation

/// A kernel-owned lease, released even on a crash. Keep its inode outside the data directory so
/// uninstall cannot unlink a held lock and admit a second app halfway through removal.
final class LifecycleLease {
    private let fd: Int32
    init(paths: Paths, role: String) throws {
        let parent = paths.support.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent(".HeyDot-\(role).lock").path
        fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Foundation.close(fd)
            throw POSIXError(.EWOULDBLOCK)
        }
    }
    deinit { Foundation.close(fd) }
}
