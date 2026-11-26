import Foundation
import Testing
@testable import HeyDotKit

// MARK: Control socket

private func shortTempDir() throws -> URL {
    // sun_path is 104 bytes, so keep test sockets under /tmp.
    let dir = URL(fileURLWithPath: "/tmp/hd-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func missingAppReportsNoHelper() throws {
    let root = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("control.sock")
    #expect(!ControlSocket.isHelperRunning(socket: socket))
    #expect(ControlSocket.request(["op": "status"], socket: socket)["outcome"] == "no-helper")
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    @discardableResult func mutate<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&stored) }
}

@Test func socketDeadlineBoundsAnUnresponsivePeer() throws {
    let root = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("hang.sock")
    let server = try ControlSocket.Server(socket: socket)
    defer { server.close() }
    Thread.detachNewThread { server.serve { _ in Thread.sleep(forTimeInterval: 0.3); return ["outcome": "ok"] } }
    let start = ProcessInfo.processInfo.systemUptime
    #expect(ControlSocket.request(["op": "status"], socket: socket, timeout: 0.05)["outcome"] == "no-reply")
    #expect(ProcessInfo.processInfo.systemUptime - start < 0.25)
    server.close()  // repeated shutdown must not close a reused descriptor
    #expect(!FileManager.default.fileExists(atPath: socket.path))
}

@Test func socketReadDeadlineDoesNotResetForEachByte() throws {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    let input = fds[0], output = fds[1]
    defer { close(input); close(output) }
    // Data is already buffered but lacks a newline. A total deadline must still expire.
    _ = ControlSocket.writeAll(output, Data("{\"outcome\":".utf8))
    let start = ProcessInfo.processInfo.systemUptime
    #expect(ControlSocket.readLine(input, deadline: start + 0.04) == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 0.25)
}

@MainActor @Test func lifecycleLeaseExcludesDuplicatesAndMaintenance() async throws {
    let root = try shortTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(home: root)
    var lease: LifecycleLease? = try LifecycleLease(paths: paths, role: "app")
    #expect(throws: POSIXError.self) { try LifecycleLease(paths: paths, role: "app") }
    #expect(await UninstallData.run(arguments: ["HeyDot", "--uninstall-data"], paths: paths, out: { _ in }, err: { _ in }) == 1)
    withExtendedLifetime(lease) {}
    lease = nil
    let second = try LifecycleLease(paths: paths, role: "app")
    withExtendedLifetime(second) {}
}
