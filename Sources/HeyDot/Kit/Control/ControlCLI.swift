import Foundation

// MARK: The command line

public enum ControlCLI {
    /// Handles `--control …` and `--control-ssh`; nil for any other launch (the menu bar app).
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           paths: Paths = Paths()) -> Int32? {
        if arguments.dropFirst().first == "--control-ssh" {
            switch WakeControl.sshWords(environment["SSH_ORIGINAL_COMMAND"]) {
            case .failure(let failure):
                FileHandle.standardError.write(Data("HeyDot: refused: \(failure)\n".utf8))
                return 2
            case .success(let words):
                return execute(words, paths: paths)
            }
        }
        guard let i = arguments.firstIndex(of: "--control") else { return nil }
        return execute(Array(arguments[(i + 1)...]), paths: paths)
    }

    static func execute(_ words: [String], paths: Paths) -> Int32 {
        let command: WakeControl.Command
        switch WakeControl.parse(words) {
        case .failure(let failure):
            FileHandle.standardError.write(Data("HeyDot: \(failure)\n".utf8))
            return 2
        case .success(let parsed): command = parsed
        }
        if command.verb != .status, !paths.allowsProfileAccess { return HeyDotMain.profileAccessError() }
        let request: JSONValue = switch command.verb {
        case .status: ["op": "status"]
        case .pause(let until): ["op": "pause", "until": until.map { .number($0.timeIntervalSince1970) } ?? .null]
        case .resume: ["op": "resume"]
        }
        var reply = ControlSocket.request(request, socket: paths.controlSocket, timeout: 5)
        let notRunning = reply["outcome"]?.string == "no-helper"
        if notRunning {
            reply = ["outcome": "not-running", "wake": .null, "state": "not_running", "paused": .null, "paused_until": .null,
                     "error": "HeyDot is not running"]
        }
        let ok = reply["outcome"]?.string == "ok" || (notRunning && command.verb == .status)
        if command.json {
            print(String(decoding: (try? reply.data()) ?? Data("{}".utf8), as: UTF8.self))
        } else if ok {
            let until = reply["paused_until"]?.string.map { " until \($0)" } ?? ""
            print("Wake word is \(reply["wake"]?.string ?? "unknown") (\(reply["state"]?.string ?? "?")\(until))")
        } else {
            FileHandle.standardError.write(Data("HeyDot: \(reply["error"]?.string ?? "no reply from the app")\n".utf8))
        }
        return ok ? 0 : 1
    }
}
