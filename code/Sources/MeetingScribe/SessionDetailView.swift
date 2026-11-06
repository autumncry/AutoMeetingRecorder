import SwiftUI
import AVFoundation
import MeetingCore

@MainActor final class AudioPlayerModel: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    func load(_ url: URL?) {
        stop()
        guard let url else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url); duration = player?.duration ?? 0; error = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.position = self.player?.currentTime ?? 0; self.playing = self.player?.isPlaying ?? false }
            }
        } catch { self.error = error.localizedDescription }
    }
    func toggle() { guard let player else { return }; if player.isPlaying { player.pause() } else { player.play() }; playing = player.isPlaying }
    func seek(_ t: Double, play: Bool = false) { player?.currentTime = min(max(0, t), duration); position = player?.currentTime ?? 0; if play { player?.play(); playing = true } }
    func stop() { timer?.invalidate(); timer = nil; player?.stop(); player = nil; playing = false; position = 0; duration = 0 }
}
struct SessionDetailView: View {
    @EnvironmentObject var model: AppModel
    let session: MeetingSession
    @StateObject private var player = AudioPlayerModel()
    @State private var tab = 0
    @State private var summary = ""
    @State private var transcript: TranscriptResult?
    @State private var editing = false
    var current: MeetingSession { model.sessions.first(where: { $0.id == session.id }) ?? session }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) { Text(current.title).font(.title.bold()).textSelection(.enabled); Text("\(current.source) · \(current.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(LocalStore.timestamp(current.duration))").foregroundStyle(.secondary).font(.callout) }
                    Spacer()
                    Menu {
                        ForEach(model.settings.asrProfiles) { p in Button("用 \(p.name) 转写") { model.enqueue(current.id, profile: p) } }
                        Divider()
                        Button("重新总结所选转写") { if let p = model.settings.activeASR { model.enqueue(current.id, profile: p, summaryOnly: true) } }
                        Button("在 Finder 中打开") { model.openFolder(current) }
                    } label: { Label("处理与导出", systemImage: "ellipsis.circle") }.disabled(current.status == .recording || current.status == .pending)
                }
                if current.audioFile != nil {
                    HStack {
                        Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 22) }.buttonStyle(.bordered)
                        Text(LocalStore.timestamp(player.position)).font(.caption.monospacedDigit())
                        Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                        Text(LocalStore.timestamp(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let error = current.lastError { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if let error = player.error { Text("播放失败：\(error)").font(.caption).foregroundStyle(.orange) }
                Picker("内容", selection: $tab) { Text("会议纪要").tag(0); Text("转写记录").tag(1); Text("文件与信息").tag(2) }.pickerStyle(.segmented).frame(width: 330)
            }.padding(26)
            Divider()
            if tab == 0 {
                if current.summaryFile != nil, current.summaryTranscriptID != current.selectedTranscriptID {
                    Text("当前纪要基于其他转写版本。切换版本后，可在“处理与导出”中重新总结。") .font(.caption).foregroundStyle(.orange).padding(.horizontal, 26).padding(.top, 10)
                }
                if summary.isEmpty && !editing {
                    ContentUnavailableView { Label("纪要尚未生成", systemImage: "doc.text") } description: { Text(current.transcriptVersions.isEmpty ? "先配置模型并转写这段录音。" : "转写已保存。配置总结模型后，可选择重新总结。") } actions: { SettingsLink { Text("查看模型设置") } }
                } else {
                    HStack { Text(editing ? "编辑 Markdown" : "Markdown 预览").font(.caption).foregroundStyle(.secondary); Spacer(); Button(editing ? "保存" : "编辑") { if editing { model.saveSummary(summary, session: current) }; editing.toggle() }.disabled(model.processingID == current.id) }.padding(.horizontal, 26).padding(.top, 12)
                    if editing { TextEditor(text: $summary).font(.body.monospaced()).padding(20) } else { MarkdownReader(text: summary) }
                }
            } else if tab == 1 {
                if !current.transcriptVersions.isEmpty {
                    HStack { Text("转写版本").font(.caption).foregroundStyle(.secondary); Picker("版本", selection: Binding(get: { current.selectedTranscriptID ?? current.transcriptVersions.last!.id }, set: { id in if let v = current.transcriptVersions.first(where: { $0.id == id }) { model.selectVersion(v, session: current) } })) { ForEach(current.transcriptVersions) { v in Text("\(v.profileName) · \(v.createdAt.formatted(date: .omitted, time: .shortened))").tag(v.id) } }.labelsHidden(); Spacer() }.padding(.horizontal, 26).padding(.top, 12)
                }
                if let transcript {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if transcript.segments.isEmpty { Text(transcript.text).textSelection(.enabled) }
                            ForEach(transcript.segments) { segment in
                                HStack(alignment: .top, spacing: 16) {
                                    Button(LocalStore.timestamp(segment.start)) { player.seek(segment.start, play: true) }.buttonStyle(.plain).foregroundStyle(.teal).font(.caption.monospacedDigit())
                                    VStack(alignment: .leading, spacing: 4) { if let speaker = segment.speaker { Text(speaker).font(.caption.bold()).foregroundStyle(.secondary) }; Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                            }
                        }.padding(26)
                    }
                } else { ContentUnavailableView("还没有转写", systemImage: "waveform", description: Text("原音频保存在本地，可选择任意 ASR 模型进行转写。")) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledContent("状态", value: statusText(current.status))
                        LabeledContent("转写版本", value: "\(current.transcriptVersions.count)")
                        Text((try? model.store.directory(for: current).path) ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        Button("打开会议文件夹") { model.openFolder(current) }
                        Divider()
                        ForEach(Array(current.notes.enumerated()), id: \.offset) { _, note in Label(note, systemImage: "info.circle").foregroundStyle(.secondary) }
                    }.padding(26)
                }
            }
        }
        .task(id: current.audioFile) { let url = current.audioFile.flatMap { name in (try? model.store.directory(for: current))?.appendingPathComponent(name) }; player.load(url) }
        .task(id: "\(current.selectedTranscriptID?.uuidString ?? "")-\(current.summaryFile ?? "")-\(current.status.rawValue)") { loadNotes() }
        .onDisappear { player.stop() }
    }
    private func loadNotes() {
        if let d = try? model.store.directory(for: current), let name = current.summaryFile, !editing { summary = (try? String(contentsOf: d.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        if let v = current.transcriptVersions.first(where: { $0.id == current.selectedTranscriptID }) ?? current.transcriptVersions.last { transcript = try? model.store.loadTranscript(v, session: current) }
    }
    private func statusText(_ s: SessionStatus) -> String { switch s { case .pending: return "等待确认"; case .recording: return "录音中"; case .ready: return "音频已保存"; case .processing: return "正在处理"; case .completed: return "已完成"; case .failed: return "处理失败，可重试"; case .interrupted: return "录音曾中断，原始音轨已保留" } }
}
struct MarkdownReader: View {
    let text: String
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("### ") { Text(String(line.dropFirst(4))).font(.headline).padding(.top, 10) }
                    else if line.hasPrefix("## ") { Text(String(line.dropFirst(3))).font(.title2.bold()).padding(.top, 14) }
                    else if line.hasPrefix("# ") { Text(String(line.dropFirst(2))).font(.title.bold()).padding(.top, 10) }
                    else if line == "---" { Divider() }
                    else { Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.textSelection(.enabled).padding(26).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
