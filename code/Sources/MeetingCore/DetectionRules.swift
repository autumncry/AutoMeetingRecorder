import Foundation

public struct AudioActivity: Equatable {
    public var pid: Int32
    public var processName: String
    public var evidence: String
    public init(pid: Int32, processName: String, evidence: String) { self.pid = pid; self.processName = processName; self.evidence = evidence }
}
public enum DetectionRules {
    public static func presence(inputActive: Bool?, appRunning: Bool, uiValid: Bool, inMeeting: Bool) -> Bool? {
        if !appRunning { return false }
        if inputActive == true || inMeeting { return true }
        guard inputActive != nil, uiValid else { return nil }
        return false
    }
    public static func parseAssertions(_ text: String) -> [AudioActivity] {
        let header = try! NSRegularExpression(pattern: #"(?m)^\s*pid\s+(\d+)\(([^)]+)\):"#)
        let client = try! NSRegularExpression(pattern: #"(?i)Created for PID:\s*(\d+)"#)
        let ns = text as NSString
        let matches = header.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen = Set<Int32>(); var activities: [AudioActivity] = []
        for (i, match) in matches.enumerated() {
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let block = ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
            let lower = block.lowercased()
            guard ["audio-in", ":input", "builtinmicrophonedevice"].contains(where: lower.contains) else { continue }
            var pid = Int32(ns.substring(with: match.range(at: 1))) ?? 0
            let name = ns.substring(with: match.range(at: 2))
            if let attributed = client.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)) {
                pid = Int32((block as NSString).substring(with: attributed.range(at: 1))) ?? 0
            } else if name.lowercased() == "coreaudiod" { continue }
            guard pid > 0, seen.insert(pid).inserted else { continue }
            activities.append(AudioActivity(pid: pid, processName: name, evidence: "系统音频输入活动"))
        }
        return activities
    }
    /// Labels describe an ACTION, so "unmute" means currently muted.
    public static func muteState(labels: [String]) -> MuteState {
        var states = Set<String>()
        for label in labels {
            let s = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["全员", "全体", "他人", "所有", " all", "participant"].contains(where: s.contains) { continue }
            if ["取消静音", "解除静音", "开启麦克风", "打开麦克风", "unmute", "turn on microphone"].contains(where: s.hasPrefix) { states.insert("muted") }
            else if ["关闭麦克风", "turn off microphone", "mute microphone"].contains(where: s.hasPrefix) { states.insert("unmuted") }
            else if s == "静音" || s == "mute" || s.hasPrefix("静音 (") || s.hasPrefix("静音（") || s.hasPrefix("mute (") { states.insert("unmuted") }
        }
        guard states.count == 1, let value = states.first else { return .unknown }
        return MuteState(rawValue: value) ?? .unknown
    }
}
public struct MeetingPresenceMachine {
    public enum Event: Equatable { case began, ended }
    public var active = false
    private var firstSeen: Date?
    private var absentSince: Date?
    public init() {}
    public mutating func update(present: Bool?, now: Date) -> Event? {
        guard let present else { firstSeen = nil; absentSince = nil; return nil }
        if present {
            absentSince = nil
            if !active {
                if firstSeen == nil { firstSeen = now }
                if now.timeIntervalSince(firstSeen!) >= 3 { active = true; firstSeen = nil; return .began }
            }
        } else {
            firstSeen = nil
            if active {
                if absentSince == nil { absentSince = now }
                if now.timeIntervalSince(absentSince!) >= 8 { active = false; absentSince = nil; return .ended }
            }
        }
        return nil
    }
}
