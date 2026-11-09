import Foundation

public enum SettingsMigration {
    /// Keep the system identity and keychain namespace stable across the public rename.
    public static let bundleIdentifier = "local.MeetingScribe"
    public static let keychainService = "local.MeetingScribe.api"
    public static func currentURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/AutoMeetingRecorder/settings.json")
    }
    public static func legacyURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/MeetingScribe/settings.json")
    }
    /// Copies validated settings once, preserving profile IDs and the existing audio library path.
    /// Existing/corrupt destination files are never overwritten by a legacy copy.
    public static func load(current: URL, legacy: URL?) throws -> AppSettings {
        let decoder = JSONDecoder()
        if FileManager.default.fileExists(atPath: current.path) {
            return try decoder.decode(AppSettings.self, from: Data(contentsOf: current))
        }
        guard let legacy, FileManager.default.fileExists(atPath: legacy.path) else { return AppSettings() }
        let data = try Data(contentsOf: legacy)
        let settings = try decoder.decode(AppSettings.self, from: data)
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = current.deletingLastPathComponent().appendingPathComponent(".settings-migration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: current)
        return settings
    }
}
