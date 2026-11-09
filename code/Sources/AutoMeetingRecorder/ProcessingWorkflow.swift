import Foundation
import AppKit
import UniformTypeIdentifiers
import MeetingCore

extension AppModel {
    func chooseAudioFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls) }
    }
    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }; importing = true; defer { importing = false }
        for url in urls {
            var created: MeetingSession?
            do {
                var s = try store.create(title: url.deletingPathExtension().lastPathComponent, source: "导入音频", status: .processing)
                created = s
                let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
                let target = try store.directory(for: s).appendingPathComponent("original.\(ext)")
                s.duration = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: url, to: target)
                    return try AudioFileTools.duration(of: target)
                }.value
                s.audioFile = target.lastPathComponent; s.status = .ready
                try update(s); selectedID = s.id
                if settings.autoTranscribe, let p = settings.activeASR, !p.baseURL.isEmpty, !p.model.isEmpty { enqueue(s.id, profile: p) }
            } catch {
                if var s = created { s.status = .failed; s.lastError = error.localizedDescription; try? update(s) }
                errorMessage = "导入失败：\(url.lastPathComponent)\n\(error.localizedDescription)"
            }
        }
    }
    func importLink(_ text: String) async {
        guard !importing else { return }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { errorMessage = "链接无效"; return }
        importing = true; activityMessage = "正在获取分享录音…"
        defer { importing = false; activityMessage = "" }
        var created: MeetingSession?
        do {
            var s = try store.create(title: "PLAUD 分享录音", source: "分享链接", status: .processing)
            created = s
            let directory = try store.directory(for: s)
            let audio = try await ShareLinkResolver().importAudio(from: url, to: directory)
            s.audioFile = audio.lastPathComponent; s.duration = try AudioFileTools.duration(of: audio); s.status = .ready
            try update(s); selectedID = s.id
            if settings.autoTranscribe, let p = settings.activeASR, !p.baseURL.isEmpty, !p.model.isEmpty { enqueue(s.id, profile: p) }
        } catch {
            if var s = created { s.status = .failed; s.lastError = error.localizedDescription; try? update(s) }
            errorMessage = error.localizedDescription
        }
    }
    func enqueue(_ id: UUID, profile: ASRProfile, summaryOnly: Bool = false) {
        guard !queueIDs.contains(id), let s = sessions.first(where: { $0.id == id }), s.status != .pending, s.status != .recording else { return }
        guard summaryOnly || (!profile.baseURL.isEmpty && !profile.model.isEmpty) else { errorMessage = "请先在设置中填写 ASR 地址和模型名称"; return }
        queueIDs.insert(id); jobs.append((id, profile, summaryOnly))
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            while !self.jobs.isEmpty, !Task.isCancelled {
                let job = self.jobs.removeFirst()
                await self.process(job.0, profile: job.1, summaryOnly: job.2)
                self.queueIDs.remove(job.0)
            }
            self.processingID = nil; self.processingTask = nil; self.activityMessage = ""
        }
    }
    func process(_ id: UUID, profile: ASRProfile, summaryOnly: Bool) async {
        guard var s = sessions.first(where: { $0.id == id }), s.status != .pending else { return }
        processingID = id
        let llm = settings.llmProfile
        let wantsSummary = summaryOnly || settings.autoSummarize
        var workingDirectory: URL?
        defer { if let d = workingDirectory { try? FileManager.default.removeItem(at: d) } }
        do {
            s.status = .processing; s.lastError = nil; try update(s)
            let directory = try store.directory(for: s)
            var transcript: TranscriptResult
            if summaryOnly {
                guard let v = s.transcriptVersions.first(where: { $0.id == s.selectedTranscriptID }) ?? s.transcriptVersions.last else { throw MeetingError.message("没有可用于总结的转写") }
                transcript = try store.loadTranscript(v, session: s)
            } else {
                guard let audio = s.audioFile, audio == (audio as NSString).lastPathComponent else { throw MeetingError.message("没有可转写音频。中断录音请先导入保留的音轨。") }
                let work = directory.appendingPathComponent(".work-\(UUID().uuidString)")
                workingDirectory = work; try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                activityMessage = "转换音频 · \(s.title)"
                let wav = work.appendingPathComponent("input.wav")
                _ = try await AudioFileTools.prepareForASR(source: directory.appendingPathComponent(audio), destination: wav)
                // PCM16 mono 16kHz is 32000 bytes/sec; reserve header/multipart headroom.
                let byteBudgetSeconds = max(1, (max(0.1, profile.maxUploadMB) * 1_000_000 - 4096) / 32_000)
                let seconds = min(max(1, profile.chunkSeconds), byteBudgetSeconds)
                let chunks = try await Task.detached(priority: .userInitiated) {
                    try AudioFileTools.splitForASR(source: wav, into: work.appendingPathComponent("chunks"), seconds: seconds)
                }.value
                let key = KeychainStore.read(profile.id)
                var outputs: [(Int, TranscriptResult)] = []
                let width = max(1, min(8, profile.concurrency))
                for base in stride(from: 0, to: chunks.count, by: width) {
                    try Task.checkCancellation()
                    let batch = Array(chunks.enumerated().dropFirst(base).prefix(width))
                    let results = try await withThrowingTaskGroup(of: (Int, TranscriptResult).self) { group in
                        for (index, chunk) in batch {
                            group.addTask {
                                var last: Error?
                                for attempt in 0..<3 {
                                    do { return (index, try await AIClient().transcribe(file: chunk.url, profile: profile, apiKey: key, offset: chunk.offset)) }
                                    catch { last = error; if error is CancellationError { throw error }; if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) } }
                                }
                                throw last ?? MeetingError.message("转写失败")
                            }
                        }
                        var completed: [(Int, TranscriptResult)] = []
                        for try await value in group { completed.append(value) }
                        return completed
                    }
                    outputs.append(contentsOf: results)
                    activityMessage = "转写 \(outputs.count)/\(chunks.count) 段 · \(profile.name)"
                }
                outputs.sort { $0.0 < $1.0 }
                let segments = outputs.flatMap { index, result in result.segments.map { part -> TranscriptSegment in
                    var p = part
                    if chunks.count > 1, let speaker = p.speaker { p.speaker = "片段\(index + 1) · \(speaker)" }
                    return p
                } }.sorted { $0.start < $1.start }
                transcript = TranscriptResult(text: outputs.map { $0.1.text }.joined(separator: "\n"), segments: segments)
                guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingError.message("ASR 返回空转写，请检查音频和模型") }
                try store.saveTranscript(transcript, profile: profile, session: &s)
            }
            if wantsSummary, !llm.baseURL.isEmpty, !llm.model.isEmpty {
                activityMessage = "生成纪要 · \(llm.model)"
                let content = transcript.segments.isEmpty ? transcript.text : transcript.segments.map { "[\(LocalStore.timestamp($0.start))] \($0.speaker ?? "说话人未识别"): \($0.text)" }.joined(separator: "\n")
                let summary = try await AIClient().summarize(transcript: content, profile: llm, apiKey: KeychainStore.read(llm.id))
                if let old = s.summaryFile, FileManager.default.fileExists(atPath: directory.appendingPathComponent(old).path) {
                    try FileManager.default.copyItem(at: directory.appendingPathComponent(old), to: directory.appendingPathComponent("summary.previous.\(UUID().uuidString).md"))
                }
                try Data(summary.utf8).write(to: directory.appendingPathComponent("summary.md"), options: .atomic)
                s.summaryFile = "summary.md"
                s.summaryTranscriptID = s.selectedTranscriptID
            } else if summaryOnly { throw MeetingError.message("请先设置总结模型的地址和模型名") }
            s.status = .completed; try update(s)
            notify("会议笔记已完成", body: s.title)
        } catch {
            // s includes any successfully persisted transcript, even when only LLM failed.
            s.status = .failed; s.lastError = error.localizedDescription; try? update(s)
            errorMessage = "处理失败，原音频已保留：\(error.localizedDescription)"
        }
    }
    func selectVersion(_ version: TranscriptVersion, session: MeetingSession) {
        guard processingID != session.id else { errorMessage = "处理期间不能切换转写版本，请等待完成"; return }
        var s = session; s.selectedTranscriptID = version.id
        do {
            let d = try store.directory(for: s)
            let text = try Data(contentsOf: d.appendingPathComponent(version.markdownFile))
            try text.write(to: d.appendingPathComponent("transcript.md"), options: .atomic)
            try update(s)
        } catch { errorMessage = error.localizedDescription }
    }
    func saveSummary(_ text: String, session: MeetingSession) {
        guard processingID != session.id else { errorMessage = "请等待处理完成后编辑纪要"; return }
        do {
            var s = session; let d = try store.directory(for: s); s.summaryFile = "summary.md"
            try Data(text.utf8).write(to: d.appendingPathComponent("summary.md"), options: .atomic); try update(s)
        } catch { errorMessage = error.localizedDescription }
    }
}
