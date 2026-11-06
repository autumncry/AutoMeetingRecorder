import Foundation
import AppKit
import ApplicationServices
import Darwin

public struct FeishuState {
    public var inMeeting: Bool = false
    public var mute: MuteState = .unknown
    public var observationValid = false
    public var detail: String = "尚未发现会议窗口"
    public init() {}
}
public enum FeishuAXProbe {
    public static var hasPermission: Bool { AXIsProcessTrusted() }
    public static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    public static func inspect(pids: [Int32]) -> FeishuState {
        var result = FeishuState()
        if pids.isEmpty { result.observationValid = true; return result }
        guard AXIsProcessTrusted() else { result.detail = "未授予辅助功能权限；只录远端"; return result }
        var labels: [String] = []
        var failed = false
        let deadline = Date().addingTimeInterval(0.25)
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.08)
            let rawWindows = attribute(app, kAXWindowsAttribute, failed: &failed) as? [AXUIElement] ?? []
            let windows = rawWindows.sorted { a, b in
                let aTitle = (attribute(a, kAXTitleAttribute, failed: &failed) as? String ?? "").lowercased()
                let bTitle = (attribute(b, kAXTitleAttribute, failed: &failed) as? String ?? "").lowercased()
                let home = ["飞书", "lark", "feishu", ""]
                return !home.contains(aTitle) && home.contains(bTitle)
            }
            for window in windows {
                var stack: [(AXUIElement, Bool)] = [(window, false)]
                var visited = 0; var leaveFound = false; var windowLabels: [String] = []
                while visited < 500, Date() < deadline, !stack.isEmpty {
                    let (node, toolbar) = stack.removeLast()
                    visited += 1
                    let role = attribute(node, kAXRoleAttribute, failed: &failed) as? String ?? ""
                    let insideToolbar = toolbar || role == kAXToolbarRole
                    // Meeting controls are outside chat/document text and participant lists.
                    // Do not traverse these content surfaces just to discover mute state.
                    if [kAXStaticTextRole, kAXTextAreaRole, kAXTableRole, kAXOutlineRole, kAXListRole].contains(role) { continue }
                    if role == kAXButtonRole || role == kAXCheckBoxRole {
                        let title = attribute(node, kAXTitleAttribute, failed: &failed) as? String ?? ""
                        let desc = attribute(node, kAXDescriptionAttribute, failed: &failed) as? String ?? ""
                        let help = attribute(node, kAXHelpAttribute, failed: &failed) as? String ?? ""
                        let identifier = attribute(node, kAXIdentifierAttribute, failed: &failed) as? String ?? ""
                        let parts = [title, desc, help].filter { !$0.isEmpty }
                        if parts.contains(where: { ["离开会议", "结束会议", "挂断", "leave meeting", "end meeting"].contains($0.lowercased()) }) { leaveFound = true }
                        // Avoid attendee-row mute controls: accept only toolbar or explicit self-mic identifiers/shortcut hints.
                        let ownMic = insideToolbar || identifier.lowercased().contains("self-mic") || identifier.lowercased().contains("toolbar-mic") || parts.contains { ($0.contains("麦克风") || $0.lowercased().contains("microphone")) && ($0.contains("⌘") || $0.lowercased().contains("command")) }
                        if ownMic { windowLabels.append(contentsOf: parts) }
                    }
                    let children = attribute(node, kAXChildrenAttribute, failed: &failed) as? [AXUIElement] ?? []
                    for child in children.reversed() { stack.append((child, insideToolbar)) }
                }
                if !stack.isEmpty || Date() >= deadline { failed = true }
                if leaveFound { result.inMeeting = true; labels.append(contentsOf: windowLabels) }
            }
        }
        result.observationValid = !failed
        result.mute = result.inMeeting && !failed ? DetectionRules.muteState(labels: labels) : .unknown
        switch result.mute { case .muted: result.detail = "飞书已静音 · 仅录远端"; case .unmuted: result.detail = "飞书已开麦 · 录制双方"; case .unknown: result.detail = result.inMeeting ? "检测到会议；静音状态不可读，仅录远端" : "未确认会中状态；仅录远端" }
        return result
    }
    private static func attribute(_ element: AXUIElement, _ key: String, failed: inout Bool) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        if status != .success && status != .noValue && status != .attributeUnsupported { failed = true }
        guard status == .success else { return nil }
        return value
    }
}

@MainActor public final class MeetingDetector {
    public var onState: ((FeishuState, Bool?, String) -> Void)?
    public var onBegan: ((Bool) -> Void)?
    public var onEnded: (() -> Void)?
    private var task: Task<Void, Never>?
    private var machine = MeetingPresenceMachine()
    public init() {}
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let apps = NSWorkspace.shared.runningApplications.filter { app in
                    let name = (app.bundleIdentifier ?? "") + " " + (app.localizedName ?? "")
                    let matches = name.lowercased().contains("lark") || name.lowercased().contains("feishu") || name.contains("飞书")
                    return matches && app.activationPolicy != .prohibited
                }
                let pids = apps.map(\.processIdentifier)
                let (activity, probe) = await Task.detached(priority: .utility) {
                    (Self.readActivity(), FeishuAXProbe.inspect(pids: pids))
                }.value
                if Task.isCancelled { break }
                var inputActive: Bool? = nil
                if let activity {
                    inputActive = activity.contains { a in
                        let name = Self.processPath(a.pid).lowercased()
                        return name.contains("feishu") || name.contains("lark.app/") || a.processName.lowercased().contains("feishu") || a.processName.lowercased().contains("lark")
                    }
                }
                let candidate = DetectionRules.presence(inputActive: inputActive, appRunning: !pids.isEmpty, uiValid: probe.observationValid, inMeeting: probe.inMeeting)
                self.onState?(probe, candidate, candidate == nil ? "会议状态暂不可确认；不会据此自动结束" : "系统活动检测运行中")
                if let event = self.machine.update(present: candidate, now: Date()) {
                    switch event { case .began: self.onBegan?(probe.inMeeting); case .ended: self.onEnded?() }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    public func stop() { task?.cancel(); task = nil; machine = MeetingPresenceMachine() }
    nonisolated private static func processPath(_ pid: Int32) -> String {
        // proc_info.h defines this as 4 * MAXPATHLEN; the macro is not imported by Swift.
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return "" }
        return String(cString: bytes)
    }
    nonisolated private static func readActivity() -> [AudioActivity]? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = ["-g", "assertions"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timer.cancel()
            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8), text.contains("Assertion") || text.contains("assertion") else { return nil }
            return DetectionRules.parseAssertions(text)
        } catch { return nil }
    }
}
