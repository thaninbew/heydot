import Foundation

/// Every location HeyDot reads or writes. `root` is the user's home; tests pass a temporary directory.
public struct Paths: Sendable {
    static let appBundleID = "app.heydot.HeyDot"
    private static let appWebStoreID = UUID(uuidString: "6E8F2C4A-3B1D-4F5E-9A7C-2D1E0B4C8F61")!
    public let home: URL
    let bundleID: String
    let allowsProfileAccess: Bool
    let usesSystemData: Bool
    let webStoreID: UUID?
    private let bundleIdentifier: String?

    /// `HEYDOT_HOME` redirects everything (isolated tests); otherwise the user's home.
    public init(home: URL? = nil) {
        self.init(home: home, bundleIdentifier: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment)
    }

    init(home: URL? = nil, bundleIdentifier: String?, environment: [String: String]) {
        let override = home ?? environment["HEYDOT_HOME"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        let root = (override ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        self.home = root
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        let validBundle = bundleIdentifier.flatMap { id in
            id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9.-]*$", options: .regularExpression) == nil ? nil : id
        }
        self.bundleIdentifier = validBundle
        bundleID = validBundle ?? "HeyDot"
        usesSystemData = override == nil && validBundle == Self.appBundleID
            && environment["HEYDOT_HOME"] == nil && rootComponents == Self.loginHome
        allowsProfileAccess = usesSystemData || (override != nil && Self.loginHome?.starts(with: rootComponents) == false)
        if usesSystemData {
            webStoreID = Self.appWebStoreID
        } else if allowsProfileAccess, let validBundle, validBundle != Self.appBundleID,
                  let fixtureID = environment["HEYDOT_WEBKIT_STORE_ID"].flatMap(UUID.init(uuidString:)),
                  fixtureID != Self.appWebStoreID,
                  [environment["HOME"], environment["CFFIXED_USER_HOME"]].allSatisfy({ path in
                      path.map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().pathComponents }
                          == rootComponents
                  }) {
            webStoreID = fixtureID
        } else {
            webStoreID = nil
        }
    }

    static let accessError = "Open the installed HeyDot app or set HEYDOT_HOME to an absolute path for an isolated profile."

    var profileIdentity: String {
        let bundle = bundleIdentifier ?? "unbundled"
        if let webStoreID { return "\(bundle)+\(webStoreID.uuidString)" }
        return "\(bundle)+transient"
    }

    /// Foundation's home APIs honor CFFIXED_USER_HOME. The account record identifies the real profile.
    private static let loginHome: [String]? = {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var storage = [CChar](repeating: 0, count: 16_384)
        return storage.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(getuid(), &entry, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, let directory = entry.pw_dir else { return nil }
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
                .resolvingSymlinksInPath().pathComponents
        }
    }()

    public var support: URL { home.appendingPathComponent("Library/Application Support/HeyDot", isDirectory: true) }
    public var settings: URL { support.appendingPathComponent("settings.json") }
    /// Private (0700) directory holding the app's control socket.
    public var runDirectory: URL { support.appendingPathComponent("run", isDirectory: true) }
    public var log: URL { home.appendingPathComponent("Library/Logs/HeyDot.log") }
    var lifecycleDirectory: URL { support.deletingLastPathComponent() }
    /// Creates a directory (and parents) and forces its mode, so a pre-existing looser directory is tightened.
    /// Parents it creates get the same mode (so a first `run/` or `avatars/` makes a 0700 HeyDot folder too).
    public static func ensureDirectory(_ url: URL, mode: Int16) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: mode)])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }
}
