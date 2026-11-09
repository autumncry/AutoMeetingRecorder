import SwiftUI
import MeetingCore

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("搜索会议标题", text: $search).textFieldStyle(.roundedBorder).padding(12)
                List(selection: $model.selectedID) {
                Section("会议与录音") {
                    ForEach(model.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { s in
                        HStack(spacing: 10) {
                            Image(systemName: symbol(s.status)).foregroundStyle(s.status == .failed ? .orange : Brand.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.title).lineLimit(1)
                                Text(s.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + LocalStore.timestamp(s.duration)).font(.caption).foregroundStyle(Brand.secondary)
                            }
                        }.padding(.vertical, 5).tag(s.id)
                    }
                }
                }.listStyle(.sidebar).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack { Circle().fill(model.settings.automaticDetection ? Brand.accent : .gray).frame(width: 7, height: 7); Text(model.settings.automaticDetection ? "飞书自动检测已开启" : "飞书自动检测已关闭").font(.caption); Spacer(); SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain) }.padding()
            }.frame(minWidth: 240, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)
                .background(Brand.sidebar)
            VStack(spacing: 0) {
                if model.activeRecording != nil { RecordingBanner().padding().background(Brand.panel) }
                if model.processingID != nil || model.importing {
                    HStack { ProgressView().controlSize(.small); Text(model.activityMessage).font(.caption); Spacer() }.padding(10).background(.quaternary.opacity(0.5))
                }
                if let session = model.selected { SessionDetailView(session: session).id(session.id) }
                else { WelcomeView() }
            }.frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).background(Brand.canvas)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseAudioFiles() } label: { Label("导入录音", systemImage: "square.and.arrow.down") }.disabled(model.importing)
                Button { model.showLinkSheet = true } label: { Label("分享链接", systemImage: "link") }.disabled(model.importing)
                Button { Task { if model.activeRecording == nil { await model.beginRecording() } else { await model.endRecording() } } } label: {
                    Label(model.activeRecording == nil ? "开始录音" : "停止", systemImage: model.activeRecording == nil ? "record.circle" : "stop.fill")
                }.disabled(model.isStarting || model.isStopping)
                SettingsLink { Label("设置", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $model.showLinkSheet) { LinkImportSheet() }
        .alert("需要注意", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(model.errorMessage ?? "") }
    }
    private func symbol(_ status: SessionStatus) -> String {
        switch status { case .recording, .pending: return "record.circle.fill"; case .processing: return "waveform"; case .completed: return "doc.text"; case .failed, .interrupted: return "exclamationmark.circle"; case .ready: return "waveform.circle" }
    }
}
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let icon = Brand.icon { Image(nsImage: icon).resizable().frame(width: 76, height: 76).accessibilityLabel("AMR 应用图标") }
            VStack(alignment: .leading, spacing: 8) {
                Text("AMR · 让会议留下清晰记录").font(.largeTitle.bold())
                Text("录音保存在你的 Mac，转写交给你的模型。") .font(.title3).foregroundStyle(Brand.secondary)
            }
            HStack(spacing: 12) {
                Button("导入一段录音") { model.chooseAudioFiles() }.buttonStyle(.borderedProminent)
                SettingsLink { Text("配置 ASR 与总结模型") }.buttonStyle(.bordered)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Label("飞书会议检测 · 不确定时先暂存，由你确认", systemImage: "video.badge.waveform")
                Label("跟随飞书静音 · 无法识别时仅录远端", systemImage: "mic.slash")
                Label("Markdown 文件 · 可直接在其他笔记软件阅读", systemImage: "doc.text")
            }.foregroundStyle(Brand.secondary)
            Text("首次使用请在设置中开启会议检测并完成权限授权。系统音频包含其他应用播放的声音；飞书静音跟随需在你的客户端上实测。")
                .font(.callout).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(48).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct RecordingBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(model.recordingLabel).font(.headline)
                Text(LocalStore.timestamp(model.elapsed)).monospacedDigit().foregroundStyle(Brand.secondary)
                Spacer()
                if model.activeRecording?.status == .pending {
                    Button("不录，丢弃", role: .destructive) { Task { await model.endRecording(discard: true) } }
                    Button("保留并继续") { model.confirmRecording() }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.isPaused ? "继续" : "暂停") { model.togglePause() }
                    Button("停止并保存") { Task { await model.endRecording() } }.buttonStyle(.borderedProminent)
                    Menu { Button("放弃本次录音", role: .destructive) { Task { await model.endRecording(discard: true) } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }
            }.disabled(model.isStopping)
            HStack(spacing: 16) {
                Label("系统音频", systemImage: "speaker.wave.2").font(.caption)
                ProgressView(value: Double(model.levels.1), total: 1).frame(width: 90)
                Label(model.localMicAllowed ? "允许保留本地声音" : "本地麦克风未保留", systemImage: model.localMicAllowed ? "mic" : "mic.slash").font(.caption)
                ProgressView(value: Double(model.levels.0), total: 1).frame(width: 90)
                Spacer()
            }
            Text(model.activeRecording?.status == .pending ? "仅在本地暂存，尚未上传。两分钟未确认会自动丢弃。" : model.feishu.detail).font(.caption).foregroundStyle(Brand.secondary)
        }
    }
}
struct LinkImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var link = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("导入分享录音", systemImage: "link").font(.title2.bold())
            Text("粘贴 plaud.cn 分享链接或音频直链。只有可访问且包含音频的链接才能转写；需要登录的链接，请先导出音频再导入。") .foregroundStyle(Brand.secondary)
            TextField("https://web.plaud.cn/share/…", text: $link).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("获取并导入") { let value = link; dismiss(); Task { await model.importLink(value) } }.buttonStyle(.borderedProminent).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(28).frame(width: 520)
    }
}
