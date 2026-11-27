import CryptoKit
import Foundation
import WakeEngine

/// Everything HeyDot remembers, stored as ~/Library/Application Support/HeyDot/settings.json.
public struct AppSettings: Codable, Equatable, Sendable {
    public var dotName: String = Phrase.defaultName
    /// The wake phrase when the user set one (lowercase words, validated by `Phrase.validateWakePhrase`);
    /// nil follows the name ("hey <name>").
    public var wakePhrase: String?
    /// Detector settings from voice tuning. `wake.phrase` always follows `phrase`.
    public var wake: WakeSettings = WakeSettings()
    public var calibrationNote: String?
    public var dotURL: String?
    public var paused: Bool = false
    /// When a timed pause ends (set through `--control pause --until`); nil for an untimed pause.
    public var pausedUntil: Date?
    /// "Pause until tomorrow morning" resumes at this local time, in minutes after midnight (default 8:00 AM).
    public var morningMinutes: Int = 8 * 60
    public var launchAtLogin: Bool = false
    public var design: DotDesign = .default
    public var onboarded: Bool = false
    /// Monochrome (a template image that matches macOS) is the default; Color draws the dot's own colours.
    public var menuBarIcon: MenuBarIcon = .monochrome
    /// The microphone the user chose (Core Audio UID); nil is the built-in microphone. HeyDot never follows the
    /// macOS default input, and falls back to the built-in microphone while the chosen one is disconnected.
    public var inputDeviceUID: String?
    /// Calls that started, counted only until the one-time GitHub star card has been answered.
    public var callsStarted: Int = 0
    /// The popover's "star on GitHub" card was answered (either button); it never shows again.
    public var starAsked: Bool = false

    public init() {}

    public var phrase: String { wakePhrase ?? Phrase.phrase(forName: dotName) }

    /// Renames the dot. A custom wake phrase stays; a phrase that follows the name changes with it.
    public mutating func rename(_ name: String) {
        guard name != dotName else { return }
        let old = phrase
        dotName = name
        phraseChanged(from: old)
    }

    /// Sets the wake phrase (already validated); nil, or the name's own "hey <name>", follows the name again.
    public mutating func setWakePhrase(_ value: String?) {
        let old = phrase
        wakePhrase = value == Phrase.phrase(forName: dotName) ? nil : value
        phraseChanged(from: old)
    }

    /// Tuning was measured on the old phrase, so a new phrase starts from the defaults until it is re-tuned.
    private mutating func phraseChanged(from old: String) {
        guard phrase != old else { return }
        wake = WakeSettings(phrase: phrase)
        calibrationNote = nil
    }

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys and ignore obsolete keys, including the former backend choice.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = AppSettings()
        dotName = try c.decodeIfPresent(String.self, forKey: .dotName) ?? base.dotName
        wakePhrase = try c.decodeIfPresent(String.self, forKey: .wakePhrase)
        wake = try c.decodeIfPresent(WakeSettings.self, forKey: .wake) ?? WakeSettings(phrase: wakePhrase ?? Phrase.phrase(forName: dotName))
        calibrationNote = try c.decodeIfPresent(String.self, forKey: .calibrationNote)
        dotURL = try c.decodeIfPresent(String.self, forKey: .dotURL)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? base.paused
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        morningMinutes = min(max(try c.decodeIfPresent(Int.self, forKey: .morningMinutes) ?? base.morningMinutes, 0), 24 * 60 - 1)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? base.launchAtLogin
        design = try c.decodeIfPresent(DotDesign.self, forKey: .design) ?? base.design
        // Earlier default logos follow the owner-selected open-cradle violet mic.
        if design == .previousDefault || design == DotDesign(fill: .inkBody, signature: .mic) { design = .default }
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? base.onboarded
        menuBarIcon = try c.decodeIfPresent(MenuBarIcon.self, forKey: .menuBarIcon) ?? base.menuBarIcon
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        callsStarted = try c.decodeIfPresent(Int.self, forKey: .callsStarted) ?? base.callsStarted
        starAsked = try c.decodeIfPresent(Bool.self, forKey: .starAsked) ?? base.starAsked
    }
}

public enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    case monochrome, color
    public var label: String { self == .monochrome ? "Monochrome (matches macOS)" : "Color" }
}

public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL = Paths().settings) { self.url = url }

    /// Missing file means first run (defaults). An unreadable file is reported, never silently replaced.
    public func load() throws -> AppSettings {
        guard let data = try read(url) else { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try write(encode(settings), to: url)
    }

    /// Recheck the file after confirmation. A valid file restored while the alert was open takes precedence.
    func rebuildUnreadable() throws -> AppSettings {
        let defaults = AppSettings()
        if let data = try read(url) {
            do {
                return try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                try backUp(data)
            }
        }
        try save(defaults)
        return defaults
    }

    private func backUp(_ data: Data) throws {
        // A retry can reuse the original backup even after the app has quit.
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let backup = url.appendingPathExtension("damaged-\(hash)")
        if let previous = try read(backup) {
            let type = try FileManager.default.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType
            guard type == .typeRegular, previous == data else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: backup.path])
            }
        } else {
            try write(data, to: backup, replacing: false)
        }
    }

    private func read(_ file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func encode(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    private func write(_ data: Data, to destination: URL, replacing: Bool = true) throws {
        let directory = destination.deletingLastPathComponent()
        try Paths.ensureDirectory(directory, mode: 0o700)
        let temporary = directory.appendingPathComponent(".settings-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: temporary.path)
        // Commit only after the replacement is private. A failed write leaves the destination intact.
        let result = replacing ? rename(temporary.path, destination.path) : link(temporary.path, destination.path)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// `--reset-onboarding`: moves the settings file aside to `settings.json.reset-<UTC timestamp>` (kept, never
    /// deleted) so the next launch starts setup from the beginning. Returns the backup, or nil if there was none.
    public func moveAside(now: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).reset-\(stamp.string(from: now).replacingOccurrences(of: ":", with: ""))")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
}
