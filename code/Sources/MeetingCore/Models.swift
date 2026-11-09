import Foundation

public enum ASRInterface: String, Codable, CaseIterable, Identifiable {
    case transcription, chatAudio
    public var id: String { rawValue }
    public var label: String { self == .transcription ? "文件转写接口" : "聊天接口 + 音频" }
}
public struct ASRProfile: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name = "内网 ASR"
    public var baseURL = ""
    public var model = ""
    public var interface: ASRInterface = .transcription
    public var chatAudioFormat = "audio_url"
    public var language = ""
    public var prompt = "请忠实转写中英混合语音，保留英文术语，不要翻译。"
    public var chunkSeconds: Double = 300
    public var maxUploadMB: Double = 24
    public var concurrency = 2
    public var timeoutSeconds: Double = 300
    public var responseFormat = "json"
    public init() {}
}
public struct LLMProfile: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name = "会议总结"
    public var baseURL = ""
    public var model = ""
    public var prompt = "用简体中文输出 Markdown 会议纪要，保留英文术语。包含概览、讨论要点、明确决策、待办（负责人和截止时间）、未决问题。只使用转写中有依据的信息；姓名、数字、归属不明确时标注待确认。不要臆造说话人姓名。"
    public var timeoutSeconds: Double = 180
    public init() {}
}
public enum MicrophoneMode: String, Codable, CaseIterable, Identifiable {
    case followFeishu, remoteOnly, independent
    public var id: String { rawValue }
    public var label: String {
        switch self { case .followFeishu: return "跟随飞书静音"; case .remoteOnly: return "只录远端"; case .independent: return "独立录制麦克风" }
    }
}
public enum MuteState: String, Codable { case muted, unmuted, unknown }
public struct AppSettings: Codable, Equatable {
    public var libraryPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/AutoMeetingRecorder").path
    public var automaticDetection = false
    public var autoTranscribe = true
    public var autoSummarize = true
    public var microphoneMode: MicrophoneMode = .followFeishu
    public var microphoneUID = ""
    public var confirmUncertain = true
    public var asrProfiles: [ASRProfile] = [ASRProfile()]
    public var selectedASRID: UUID?
    public var llmProfile = LLMProfile()
    public init() {}
    public var activeASR: ASRProfile? { asrProfiles.first(where: { $0.id == selectedASRID }) ?? asrProfiles.first }
}
public struct TranscriptSegment: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var start: Double
    public var end: Double?
    public var text: String
    public var speaker: String?
    public init(start: Double, end: Double? = nil, text: String, speaker: String? = nil) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker
    }
}
public struct TranscriptResult: Codable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var language: String?
    public var rawResponse: String?
    public init(text: String, segments: [TranscriptSegment] = [], language: String? = nil, rawResponse: String? = nil) {
        self.text = text; self.segments = segments; self.language = language; self.rawResponse = rawResponse
    }
}
public struct TranscriptVersion: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var createdAt = Date()
    public var profileName: String
    public var model: String
    public var markdownFile: String
    public var jsonFile: String
    public init(profileName: String, model: String, markdownFile: String, jsonFile: String) {
        self.profileName = profileName; self.model = model; self.markdownFile = markdownFile; self.jsonFile = jsonFile
    }
}
public enum SessionStatus: String, Codable { case pending, recording, ready, processing, completed, failed, interrupted }
public struct MeetingSession: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var createdAt = Date()
    public var title: String
    public var source: String
    public var directory: String
    public var status: SessionStatus = .ready
    public var duration: Double = 0
    public var audioFile: String?
    public var transcriptVersions: [TranscriptVersion] = []
    public var selectedTranscriptID: UUID?
    public var summaryFile: String?
    public var summaryTranscriptID: UUID?
    public var lastError: String?
    public var notes: [String] = []
    public init(title: String, source: String, directory: String) { self.title = title; self.source = source; self.directory = directory }
}
public struct CaptureResult {
    public let audioURL: URL
    public let microphoneURL: URL?
    public let systemURL: URL?
    public let duration: Double
    public init(audioURL: URL, microphoneURL: URL?, systemURL: URL?, duration: Double) {
        self.audioURL = audioURL; self.microphoneURL = microphoneURL; self.systemURL = systemURL; self.duration = duration
    }
}
public struct AudioChunk {
    public let url: URL
    public let offset: Double
    public let duration: Double
    public init(url: URL, offset: Double, duration: Double) { self.url = url; self.offset = offset; self.duration = duration }
}
public struct InputDevice: Identifiable, Equatable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public init(id: UInt32, uid: String, name: String) { self.id = id; self.uid = uid; self.name = name }
}
public enum MeetingError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
