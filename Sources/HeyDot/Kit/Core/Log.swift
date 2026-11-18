import Foundation
import Darwin

/// Bounded text log (1 MiB current plus one 1 MiB archive) at ~/Library/Logs/HeyDot.log.
public final class Log: @unchecked Sendable {
    public static let shared = Log(url: Paths().log)

    private let url: URL
    private let lock = NSLock()
    static let maximumBytes = 1_048_576
    static let maximumMessageBytes = 16_384
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(url: URL) { self.url = url }

    public var location: URL { url }

    public func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let message = String(decoding: message.utf8.prefix(Self.maximumMessageBytes), as: UTF8.self)
        let line = "\(stamp.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        // Owner-only, including logs created 0644 by earlier builds.
        fchmod(handle.fileDescriptor, 0o600)
        // App and native-host instances share this inode. Keep rotation under the same advisory lock.
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        do {
            let size = try handle.seekToEnd()
            if size + UInt64(data.count) > Self.maximumBytes {
                try handle.seek(toOffset: size > Self.maximumBytes ? size - UInt64(Self.maximumBytes) : 0)
                let tail = try handle.read(upToCount: Self.maximumBytes) ?? Data()
                let archive = url.path + ".1"
                try tail.write(to: URL(fileURLWithPath: archive), options: .atomic)
                chmod(archive, 0o600)
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
            }
            try handle.write(contentsOf: data)
        } catch { /* Logging must never interrupt the call or native protocol. */ }
    }
}
