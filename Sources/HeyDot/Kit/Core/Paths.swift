import Foundation

/// Every location HeyDot reads or writes. `root` is the user's home; tests pass a temporary directory.
public struct Paths: Sendable {
    public let home: URL

    /// `HEYDOT_HOME` redirects everything (isolated tests); otherwise the user's home.
    public init(home: URL? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["HEYDOT_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public var support: URL { home.appendingPathComponent("Library/Application Support/HeyDot", isDirectory: true) }
    public var settings: URL { support.appendingPathComponent("settings.json") }
    /// Private (0700) directory holding the app's control socket.
    public var runDirectory: URL { support.appendingPathComponent("run", isDirectory: true) }
    public var log: URL { home.appendingPathComponent("Library/Logs/HeyDot.log") }
    /// Creates a directory (and parents) and forces its mode, so a pre-existing looser directory is tightened.
    /// Parents it creates get the same mode (so a first `run/` or `avatars/` makes a 0700 HeyDot folder too).
    public static func ensureDirectory(_ url: URL, mode: Int16) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: mode)])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }
}
