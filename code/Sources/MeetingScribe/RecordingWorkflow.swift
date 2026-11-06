import Foundation
import AVFoundation
import UserNotifications
import MeetingCore

extension AppModel {
    func beginRecording(automatic: Bool = false, pending: Bool = false, generation: UInt64? = nil) async {
        guard !terminating, activeRecording == nil, !isStarting, !isStopping else { return }
        let token = generation ?? automaticGate.generation
        if automatic && !automaticGate.permits(token, enabled: settings.automaticDetection) { return }
        isStarting = true; defer { isStarting = false; resumeDeferredAutomaticStart() }
        guard #available(macOS 14.2, *) else { errorMessage = "录音需要 macOS 14.2 或更新版本"; return }
        if settings.microphoneMode != .remoteOnly, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard !terminating, activeRecording == nil else { return }
        if automatic && !automaticGate.permits(token, enabled: settings.automaticDetection) { return }
        var created: MeetingSession?
        do {
            let title = Date().formatted(date: .abbreviated, time: .shortened) + (automatic ? " 飞书会议" : " 会议录音")
            let s = try store.create(title: title, source: automatic ? "飞书自动检测" : "手动录音", status: pending ? .pending : .recording)
            created = s
            let directory = try store.directory(for: s)
            try capture.start(in: directory, microphoneUID: settings.microphoneUID, microphoneEnabled: localMicAllowed)
            lastAppliedMicGate = localMicAllowed
            automaticSession = automatic; activeRecording = s; selectedID = s.id
            detector.start()
            isPaused = false; startedAt = Date(); elapsed = 0; reload()
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, let start = self.startedAt { self.elapsed = Date().timeIntervalSince(start); self.applyMicrophoneGate() }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if pending {
                notify("发现疑似飞书会议", body: "已在本地暂存。保留或丢弃？两分钟未答复将自动丢弃。", pending: true, id: s.id)
                pendingTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    guard !Task.isCancelled, let self, self.activeRecording?.id == s.id, self.activeRecording?.status == .pending else { return }
                    await self.endRecording(discard: true)
                }
            } else if automatic { notify("飞书会议录音已开始", body: "正在保存系统声音。\(feishu.detail)") }
        } catch {
            if var s = created { s.status = .failed; s.lastError = error.localizedDescription; try? update(s) }
            errorMessage = "录音启动失败：\(error.localizedDescription)"
        }
    }
    func confirmRecording() {
        guard var s = activeRecording, s.status == .pending, !isStopping else { return }
        do {
            s.status = .recording; try update(s); activeRecording = s
            pendingTask?.cancel(); pendingTask = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [s.id.uuidString])
        } catch { errorMessage = error.localizedDescription }
    }
    func togglePause() {
        guard activeRecording != nil, !isStopping else { return }
        isPaused.toggle(); capture.setPaused(isPaused)
    }
    func endRecording(discard: Bool = false, becauseMeetingEnded: Bool = false) async {
        if isStopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        guard var s = activeRecording else { return }
        isStopping = true
        if !becauseMeetingEnded { automaticGate.suppressCurrent(); deferredAutomaticStart = nil }
        pendingTask?.cancel(); pendingTask = nil; clockTask?.cancel(); clockTask = nil
        let shouldDiscard = discard || s.status == .pending
        // Persist deletion intent before awaiting finalization, so a crash cannot retain rejected audio as confirmed.
        if shouldDiscard { s.status = .pending; activeRecording = s; do { try store.save(s) } catch { errorMessage = "丢弃标记写入失败：\(error.localizedDescription)" } }
        defer {
            activeRecording = nil; startedAt = nil; levels = (0, 0); elapsed = 0; isPaused = false; isStopping = false; automaticSession = false
            configureDetection(); reload()
            let waiters = stopWaiters; stopWaiters.removeAll(); waiters.forEach { $0.resume() }
            resumeDeferredAutomaticStart()
        }
        do {
            let result = try await capture.stop()
            if shouldDiscard {
                // Preserve the on-disk pending marker until cleanup; explicit discard of a confirmed session is also user requested.
                if s.status != .pending { s.status = .pending; try store.save(s) }
                try store.discardPending(s)
            } else {
                s.audioFile = result.audioURL.lastPathComponent; s.duration = result.duration; s.status = .ready
                if settings.microphoneMode == .followFeishu { s.notes.append("本地麦克风仅在确认飞书开麦时保留；未识别区间可能缺少本人发言。") }
                s.notes.append("系统音轨为全系统声音，可能包含其他应用；原始音轨保留。")
                try update(s)
                if !terminating, settings.autoTranscribe, let profile = settings.activeASR, !profile.baseURL.isEmpty, !profile.model.isEmpty { enqueue(s.id, profile: profile) }
                else { notify("录音已保存", body: "设置 ASR 地址和模型后，可自动或手动转写。") }
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [s.id.uuidString])
        } catch {
            if shouldDiscard {
                do { s.status = .pending; try store.save(s); try store.discardPending(s) } catch { errorMessage = "临时录音清理失败，请检查会议文件夹：\(error.localizedDescription)" }
            } else {
                s.status = .interrupted; s.lastError = "保存混音失败，原始音轨仍在文件夹：\(error.localizedDescription)"; try? update(s)
                errorMessage = s.lastError
            }
        }
    }
}
