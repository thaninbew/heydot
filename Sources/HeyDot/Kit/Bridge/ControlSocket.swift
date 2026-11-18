import Foundation

/// The private control socket for status, pause and resume requests: one JSON line in, one JSON line out.
/// The socket lives in a 0700 directory and is created 0600, so only this user can reach it.
public enum ControlSocket {
    static let maxLine = 64 * 1024

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func withAddress<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func ready(_ fd: Int32, _ events: Int16, until deadline: TimeInterval) -> Bool {
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(left * 1000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            return result > 0 && descriptor.revents & (events | Int16(POLLHUP)) != 0
        }
    }

    static func readLine(_ fd: Int32, deadline: TimeInterval? = nil) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < maxLine {
            if let deadline, !ready(fd, Int16(POLLIN), until: deadline) { return nil }
            let n = Foundation.read(fd, &byte, 1)
            if n == 1 {
                if byte == UInt8(ascii: "\n") { return line }
                line.append(byte)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return line.isEmpty ? nil : line
            }
        }
        return nil
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data, deadline: TimeInterval? = nil) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                if let deadline, !ready(fd, Int16(POLLOUT), until: deadline) { return false }
                let n = Foundation.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    // MARK: Server (app side)

    public final class Server: @unchecked Sendable {
        private let fd: Int32
        public let path: String
        private let state = NSLock()
        private var closed = false
        private var clients: Set<Int32> = []
        private let workers = DispatchSemaphore(value: 8)

        /// Binds the socket, replacing a stale one. `directory` is created or tightened to 0700.
        public init(socket: URL) throws {
            path = socket.path
            // Like Python's default: a peer that hangs up yields EPIPE, never a process-killing signal.
            signal(SIGPIPE, SIG_IGN)
            try Paths.ensureDirectory(socket.deletingLastPathComponent(), mode: 0o700)
            unlink(path)
            guard var addr = ControlSocket.address(path) else { throw POSIXError(.ENAMETOOLONG) }
            let fd = Foundation.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // No umask change: it is process-wide and would race other threads. The 0700 directory already
            // keeps other users out, and the socket is tightened to 0600 right after bind.
            let bound = ControlSocket.withAddress(&addr) { bind(fd, $0, $1) }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                Foundation.close(fd)
                throw POSIXError(code)
            }
            self.fd = fd
        }

        /// Accepts connections forever on the calling thread; each request is answered on its own thread
        /// so one slow peer never blocks another control request.
        public func serve(_ handle: @escaping @Sendable (JSONValue) -> JSONValue) {
            state.lock()
            let listener = closed ? -1 : dup(fd)
            state.unlock()
            guard listener >= 0 else { return }
            defer { Foundation.close(listener) }
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard workers.wait(timeout: .now()) == .success else { Foundation.close(client); continue }
                state.lock()
                if closed {
                    state.unlock(); Foundation.close(client); workers.signal(); return
                }
                clients.insert(client)
                state.unlock()
                let workers = workers
                _ = fcntl(client, F_SETFL, O_NONBLOCK)
                var noSigPipe: Int32 = 1  // a client that hangs up early must not kill the app
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread {
                    defer {
                        self.state.lock()
                        self.clients.remove(client)
                        Foundation.close(client)
                        self.state.unlock()
                        workers.signal()
                    }
                    let deadline = ProcessInfo.processInfo.systemUptime + 40
                    guard let line = ControlSocket.readLine(client, deadline: deadline) else { return }
                    let request = (try? JSONValue.parse(line)) ?? .object([:])
                    var reply = (try? handle(request).data()) ?? Data("{\"outcome\":\"error\"}".utf8)
                    reply.append(UInt8(ascii: "\n"))
                    ControlSocket.writeAll(client, reply, deadline: deadline)
                }
            }
        }

        public func close() {
            state.lock()
            defer { state.unlock() }
            guard !closed else { return }
            closed = true
            clients.forEach { _ = shutdown($0, SHUT_RDWR) }
            shutdown(fd, SHUT_RDWR)
            Foundation.close(fd)
            unlink(path)
        }
    }

    // MARK: Client (CLI side)

    /// Sends one request to the running app. `no-helper` means the app is not running.
    public static func request(_ message: JSONValue, socket: URL = Paths().controlSocket, timeout: TimeInterval = 40) -> JSONValue {
        let noHelper: JSONValue = ["outcome": "no-helper", "error": "HeyDot is not running"]
        guard var addr = address(socket.path) else { return noHelper }
        let fd = Foundation.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return noHelper }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, address: &addr, deadline: deadline) else { return noHelper }
        guard var body = try? message.data() else { return ["outcome": "error", "error": "bad request"] }
        body.append(UInt8(ascii: "\n"))
        guard writeAll(fd, body, deadline: deadline) else { return ["outcome": "no-reply"] }
        guard let line = readLine(fd, deadline: deadline), let reply = try? JSONValue.parse(line) else { return ["outcome": "no-reply"] }
        return reply
    }

    private static func connect(_ fd: Int32, address: inout sockaddr_un, deadline: TimeInterval) -> Bool {
        if withAddress(&address, { Foundation.connect(fd, $0, $1) }) == 0 { return true }
        guard errno == EINPROGRESS, ready(fd, Int16(POLLOUT), until: deadline) else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    /// True when the app is accepting connections. Sends no request.
    public static func isHelperRunning(socket: URL = Paths().controlSocket) -> Bool {
        guard var addr = address(socket.path) else { return false }
        let fd = Foundation.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return connect(fd, address: &addr, deadline: ProcessInfo.processInfo.systemUptime + 0.2)
    }
}
