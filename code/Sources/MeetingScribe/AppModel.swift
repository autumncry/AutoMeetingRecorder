import SwiftUI
import AppKit
import MeetingCore
import AVFoundation
import UserNotifications

@MainActor final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { saveSettings(); if oldValue.automaticDetection != settings.automaticDetection { configureDetection() } } }
    @Published var sessions: [MeetingSession] = []
    @Published var selectedID: UUID?
    @Published var activeRecording: MeetingSession?
    @Published var isPaused = false
    @Published var isStopping = false
    @Published var elapsed: Double = 0
    @Published var levels: (Float, Float) = (0, 0)
    @Published var feishu = FeishuState()
    @Published var detectorStatus = "会议检测已关闭"
    @Published var errorMessage: String?
    @Published var activityMessage = ""
    @Published var processingID: UUID?
    @Published var importing = false
    @Published var showLinkSheet = false
    @Published var testResponse = ""
    let detector = MeetingDetector()
    let capture = AudioCaptureService()
    var store: LocalStore
    let settingsURL: URL
    var startedAt: Date?
    var clockTask: Task<Void, Never>?
    var pendingTask: Task<Void, Never>?
    var processingTask: Task<Void, Never>?
    var jobs: [(UUID, ASRProfile, Bool)] = []
    var queueIDs = Set<UUID>()
    var isStarting = false
    var automaticSession = false
    var lastMuteObservation = Date.distantPast
    var lastAppliedMicGate: Bool?
    var automaticGate = AutomaticStartGate()
    var deferredAutomaticStart: (UInt64, Bool)?
    var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var terminating = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        let qaPath = args.firstIndex(of: "--library").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let config = qaPath.map { URL(fileURLWithPath: $0).appendingPathComponent(".settings.json") } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeetingScribe/settings.json")
        settingsURL = config
        var loaded = (try? Data(contentsOf: config)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        if let qaPath { loaded.libraryPath = qaPath; loaded.automaticDetection = false }
        settings = loaded
        do { store = try LocalStore(root: URL(fileURLWithPath: loaded.libraryPath)) }
        catch {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingScribe-Recovery")
            store = try! LocalStore(root: fallback)
            settings.libraryPath = fallback.path
            errorMessage = "无法打开资料库，暂时使用恢复目录：\(error.localizedDescription)"
        }
        reload()
        recoverInterrupted()
        detector.onState = { [weak self] state, present, status in
            guard let self else { return }
            self.feishu = state; self.lastMuteObservation = Date(); self.detectorStatus = status
            self.automaticGate.observe(present, at: Date())
            self.applyMicrophoneGate()
        }
        detector.onBegan = { [weak self] certain in
            guard let self else { return }
            let token = self.automaticGate.began()
            guard self.automaticGate.permits(token, enabled: self.settings.automaticDetection), !self.terminating else { return }
            if self.isStopping || self.isStarting { self.deferredAutomaticStart = (token, certain); return }
            guard self.activeRecording == nil else { return }
            Task { await self.beginRecording(automatic: true, pending: !certain && self.settings.confirmUncertain, generation: token) }
        }
        detector.onEnded = { [weak self] in
            guard let self else { return }
            self.automaticGate.ended(); self.deferredAutomaticStart = nil
            guard self.automaticSession, self.activeRecording != nil else { return }
            Task { await self.endRecording(discard: self.activeRecording?.status == .pending, becauseMeetingEnded: true) }
        }
        capture.onLevel = { [weak self] mic, system in self?.levels = (mic, system) }
        capture.onIssue = { [weak self] issue in
            guard let self else { return }
            self.activeRecording?.notes.append(issue)
            self.errorMessage = issue
        }
        capture.onFatalIssue = { [weak self] issue in
            guard let self, self.activeRecording != nil else { return }
            self.activeRecording?.notes.append("录音异常中止：" + issue)
            self.errorMessage = "录音已中止，将保存已有音频：\(issue)"
            Task { await self.endRecording() }
        }
        configureDetection()
    }
    var selected: MeetingSession? { sessions.first { $0.id == selectedID } }
    var recordingLabel: String { activeRecording?.status == .pending ? "待确认录音" : isPaused ? "录音已暂停" : activeRecording != nil ? "正在录音" : "准备就绪" }
    var localMicAllowed: Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        switch settings.microphoneMode { case .remoteOnly: return false; case .independent: return true; case .followFeishu: return feishu.mute == .unmuted && feishu.inMeeting && Date().timeIntervalSince(lastMuteObservation) < 1.8 }
    }
    func applyMicrophoneGate() {
        guard activeRecording != nil else { return }
        let enabled = localMicAllowed
        guard lastAppliedMicGate != enabled else { return }
        lastAppliedMicGate = enabled; capture.setMicrophoneEnabled(enabled)
    }
    func saveSettings() {
        do { try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic) }
        catch { errorMessage = "设置保存失败：\(error.localizedDescription)" }
    }
    func configureDetection() {
        if settings.automaticDetection { detector.start(); detectorStatus = "正在检测飞书会议"; Task { await registerNotifications() } }
        else {
            automaticGate.disabled(); deferredAutomaticStart = nil
            if activeRecording == nil { detector.stop(); detectorStatus = "会议检测已关闭" }
        }
    }
    func resumeDeferredAutomaticStart() {
        guard !terminating, activeRecording == nil, !isStarting, !isStopping, let (token, certain) = deferredAutomaticStart else { return }
        deferredAutomaticStart = nil
        guard automaticGate.permits(token, enabled: settings.automaticDetection) else { return }
        Task { await beginRecording(automatic: true, pending: !certain && settings.confirmUncertain, generation: token) }
    }
    func reload() { do { sessions = try store.load() } catch { errorMessage = error.localizedDescription } }
    func update(_ session: MeetingSession) throws {
        try store.save(session)
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.insert(session, at: 0) }
    }
    func recoverInterrupted() {
        for var s in sessions {
            if s.status == .pending { do { try store.discardPending(s) } catch { errorMessage = "待确认录音清理失败：\(error.localizedDescription)" }; continue }
            if s.status == .recording {
                s.status = .interrupted; s.lastError = "上次录音中断，原始音轨保留在会议文件夹。可导入 system.caf 进行转写。"
                if let d = try? store.directory(for: s), FileManager.default.fileExists(atPath: d.appendingPathComponent("recording.wav").path) { s.audioFile = "recording.wav"; s.status = .ready }
                try? store.save(s)
            } else if s.status == .processing { s.status = .failed; s.lastError = "上次处理被中断，音频已保留。点击重新转写。"; try? store.save(s) }
        }
        reload()
    }
    func changeLibrary() {
        guard activeRecording == nil, processingTask == nil, !importing else { errorMessage = "请等待录音和处理完成后切换资料库"; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { store = try LocalStore(root: url); settings.libraryPath = url.path; selectedID = nil; reload(); recoverInterrupted() } catch { errorMessage = error.localizedDescription }
    }
    func openFolder(_ session: MeetingSession? = nil) {
        let url = session.flatMap { try? store.directory(for: $0) } ?? store.root
        NSWorkspace.shared.open(url)
    }
    func registerNotifications() async {
        let keep = UNNotificationAction(identifier: "KEEP", title: "保留并继续", options: [])
        let discard = UNNotificationAction(identifier: "DISCARD", title: "不录，丢弃", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "MEETING_PENDING", actions: [keep, discard], intentIdentifiers: [])])
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func notify(_ title: String, body: String, pending: Bool = false, id: UUID? = nil) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        if pending { c.categoryIdentifier = "MEETING_PENDING" }
        if let id { c.userInfo = ["session": id.uuidString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id?.uuidString ?? UUID().uuidString, content: c, trigger: nil))
    }
    func notificationAction(_ action: String, sessionID: String?) {
        guard sessionID == activeRecording?.id.uuidString, activeRecording?.status == .pending else { return }
        if action == "KEEP" { confirmRecording() }
        if action == "DISCARD" { Task { await endRecording(discard: true) } }
    }
}
