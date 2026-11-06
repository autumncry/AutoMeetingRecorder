import Foundation
import Security

public enum KeychainStore {
    private static let service = "local.MeetingScribe.api"
    public static func read(_ id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ value: String, for id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if value.isEmpty { let code = SecItemDelete(query as CFDictionary); guard code == errSecSuccess || code == errSecItemNotFound else { throw MeetingError.message("钥匙串删除失败：\(code)") }; return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let code = SecItemAdd(item as CFDictionary, nil)
            guard code == errSecSuccess else { throw MeetingError.message("钥匙串写入失败：\(code)") }
        } else if status != errSecSuccess { throw MeetingError.message("钥匙串更新失败：\(status)") }
    }
}

public final class LocalStore {
    public let root: URL
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    public init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    public func directory(for session: MeetingSession) throws -> URL {
        guard !session.directory.isEmpty, session.directory == (session.directory as NSString).lastPathComponent, session.directory != ".", session.directory != ".." else { throw MeetingError.message("录音目录无效") }
        let url = root.appendingPathComponent(session.directory).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().standardizedFileURL.path == root.path else { throw MeetingError.message("录音目录不在资料库内") }
        return url
    }
    public func create(title: String, source: String, status: SessionStatus = .ready) throws -> MeetingSession {
        var s = MeetingSession(title: title, source: source, directory: "")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        s.directory = f.string(from: s.createdAt) + "_" + s.id.uuidString.prefix(8)
        s.status = status
        try save(s)
        return s
    }
    public func save(_ session: MeetingSession) throws {
        let d = try directory(for: session)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: d.appendingPathComponent("meeting.json"), options: .atomic)
    }
    public func load() throws -> [MeetingSession] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        return folders.compactMap { folder -> MeetingSession? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")), let s = try? decoder.decode(MeetingSession.self, from: data), (try? directory(for: s).path) == folder.resolvingSymlinksInPath().path else { return nil }
            return s
        }.sorted { $0.createdAt > $1.createdAt }
    }
    /// Only app-owned pending recordings may be purged automatically.
    public func discardPending(_ session: MeetingSession) throws {
        guard session.status == .pending else { throw MeetingError.message("只能自动清理待确认录音") }
        let d = try directory(for: session)
        let stored = try decoder.decode(MeetingSession.self, from: Data(contentsOf: d.appendingPathComponent("meeting.json")))
        guard stored.id == session.id, stored.status == .pending else { throw MeetingError.message("录音已经确认，不能自动丢弃") }
        try FileManager.default.removeItem(at: d)
    }
    public func saveTranscript(_ result: TranscriptResult, profile: ASRProfile, session: inout MeetingSession) throws {
        let suffix = UUID().uuidString
        let version = TranscriptVersion(profileName: profile.name, model: profile.model, markdownFile: "transcript.\(suffix).md", jsonFile: "transcript.\(suffix).json")
        let d = try directory(for: session)
        try encoder.encode(result).write(to: d.appendingPathComponent(version.jsonFile), options: .atomic)
        let lines = result.segments.map { s in "[\(Self.timestamp(s.start))]" + (s.speaker.map { " **\($0)**" } ?? "") + "  \n" + s.text }
        let text = "# \(session.title) · 转写\n\n模型：\(profile.name) / \(profile.model)\n\n" + (lines.isEmpty ? result.text : lines.joined(separator: "\n\n")) + "\n"
        try Data(text.utf8).write(to: d.appendingPathComponent(version.markdownFile), options: .atomic)
        try Data(text.utf8).write(to: d.appendingPathComponent("transcript.md"), options: .atomic)
        session.transcriptVersions.append(version); session.selectedTranscriptID = version.id
        try save(session)
    }
    public func loadTranscript(_ version: TranscriptVersion, session: MeetingSession) throws -> TranscriptResult {
        guard version.jsonFile == (version.jsonFile as NSString).lastPathComponent else { throw MeetingError.message("转写文件路径无效") }
        return try decoder.decode(TranscriptResult.self, from: Data(contentsOf: directory(for: session).appendingPathComponent(version.jsonFile)))
    }
    public static func timestamp(_ seconds: Double) -> String {
        let t = Int(max(0, seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
}
