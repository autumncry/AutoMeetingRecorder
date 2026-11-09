import SwiftUI
import MeetingCore
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var profileID: UUID?
    @State private var inputs: [InputDevice] = []
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        TabView {
            Form {
                Section("飞书会议") {
                    Toggle("自动检测会议", isOn: $model.settings.automaticDetection)
                    Toggle("不确定时暂存并询问", isOn: $model.settings.confirmUncertain)
                    Text("识别到疑似会议会先本地录制。确认前不上传；拒绝或两分钟未答复则丢弃。") .font(.caption).foregroundStyle(Brand.secondary)
                    Text(model.detectorStatus).font(.caption).foregroundStyle(Brand.accent)
                }
                Section("音频来源") {
                    Picker("本地麦克风", selection: $model.settings.microphoneMode) { ForEach(MicrophoneMode.allCases) { Text($0.label).tag($0) } }
                        .onChange(of: model.settings.microphoneMode) { _, _ in model.applyMicrophoneGate() }
                    Picker("麦克风设备", selection: $model.settings.microphoneUID) {
                        Text("系统默认输入设备").tag("")
                        ForEach(inputs) { Text($0.name).tag($0.uid) }
                    }.disabled(model.activeRecording != nil)
                    Text("请与飞书使用相同麦克风。系统声音采用全局捕获，可能包含音乐或提示音。外放时可能串音，建议先用耳机验收。") .font(.caption).foregroundStyle(Brand.secondary)
                    if model.settings.microphoneMode == .independent { Label("独立模式会录到会议静音期间的本地谈话。", systemImage: "mic.fill").foregroundStyle(.orange).font(.caption) }
                    if model.settings.microphoneMode == .followFeishu { Text("静音跟随是保守模式：只有可靠识别到飞书开麦才保留本地声音。读不到状态时仅录远端。切换边界需实会验证，可能缺少短暂本人发言。") .font(.caption).foregroundStyle(Brand.secondary) }
                }
                Section("权限与启动") {
                    Button("发送 AMR 测试通知") { Task { await model.sendTestNotification() } }
                    HStack { Text(FeishuAXProbe.hasPermission ? "辅助功能：已授权" : "辅助功能：未授权"); Spacer(); Button("授权静音状态读取") { FeishuAXProbe.requestPermission() } }
                    HStack { Text("麦克风：\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "已授权" : "未授权")"); Spacer(); Button("请求麦克风权限") { Task { _ = await AVCaptureDevice.requestAccess(for: .audio) } } }
                    Button("打开系统音频录制权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                    Toggle("登录时启动", isOn: $login).onChange(of: login) { _, value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { model.errorMessage = "登录项设置失败：\(error.localizedDescription)"; login = SMAppService.mainApp.status == .enabled }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("录音", systemImage: "waveform") }
            VStack(spacing: 0) {
                HStack {
                    Picker("配置", selection: $profileID) { ForEach(model.settings.asrProfiles) { Text($0.name).tag(Optional($0.id)) } }
                    Button { let p = ASRProfile(); model.settings.asrProfiles.append(p); profileID = p.id } label: { Image(systemName: "plus") }
                    Button { if let i = index, model.settings.asrProfiles.count > 1 { model.settings.asrProfiles.remove(at: i); profileID = model.settings.asrProfiles.first?.id } } label: { Image(systemName: "minus") }.disabled(model.settings.asrProfiles.count <= 1)
                }.padding()
                if let index { ASRProfileEditor(profile: $model.settings.asrProfiles[index]).id(model.settings.asrProfiles[index].id) }
                HStack { Toggle("录音结束或导入后自动转写", isOn: $model.settings.autoTranscribe); Spacer(); Button("设为默认") { model.settings.selectedASRID = profileID ?? model.settings.asrProfiles.first?.id }; Text("默认：\(model.settings.activeASR?.name ?? "无")").font(.caption).foregroundStyle(Brand.secondary) }.padding()
            }.tabItem { Label("ASR 模型", systemImage: "text.bubble") }
            LLMEditor().tabItem { Label("总结模型", systemImage: "sparkles") }
            Form {
                Section("本地资料库") {
                    Text(model.settings.libraryPath).font(.callout.monospaced()).textSelection(.enabled)
                    HStack { Button("选择文件夹…") { model.changeLibrary() }; Button("在 Finder 中打开") { model.openFolder() } }
                    Text("每场会议一个文件夹，包含原音频、转写版本、summary.md、transcript.md 和 meeting.json。可以选择其他笔记软件使用的目录。切换目录不会搬走原有文件。") .foregroundStyle(Brand.secondary)
                }
                Section("数据流") {
                    Text("待确认录音只暂存在本机。正式录音仅发送到你配置的 ASR 地址；总结时转写文本发送到你配置的 LLM 地址。API Key 存储在 macOS 钥匙串。")
                    Text("关闭主窗口仍会继续运行。菜单栏可随时暂停或停止录音。")
                }
                Section("AutoMeetingRecorder · AMR") {
                    HStack(spacing: 12) {
                        if let icon = Brand.icon { Image(nsImage: icon).resizable().frame(width: 48, height: 48) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AutoMeetingRecorder").font(.headline)
                            Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · 北电数智蓝 · macOS 14.2+").font(.caption).foregroundStyle(Brand.secondary)
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("存储", systemImage: "folder") }
        }.onAppear { profileID = model.settings.selectedASRID ?? model.settings.asrProfiles.first?.id; inputs = AudioCaptureService.inputDevices() }
    }
    private var index: Int? { model.settings.asrProfiles.firstIndex(where: { $0.id == profileID }) ?? model.settings.asrProfiles.indices.first }
}
struct ASRProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var profile: ASRProfile
    @State private var key = ""
    @State private var testing = false
    @State private var response = ""
    @State private var showResponse = false
    var body: some View {
        Form {
            TextField("配置名称", text: $profile.name)
            Picker("接口类型", selection: $profile.interface) { ForEach(ASRInterface.allCases) { Text($0.label).tag($0) } }
            if profile.interface == .chatAudio { Picker("音频消息格式", selection: $profile.chatAudioFormat) { Text("audio_url（Base64 data URL）").tag("audio_url"); Text("input_audio（Base64 WAV）").tag("input_audio") } }
            TextField("API 地址", text: $profile.baseURL, prompt: Text("http://服务器IP:8000/v1"))
            TextField("模型名称", text: $profile.model, prompt: Text("服务端的 served-model-name"))
            HStack { SecureField("API Key（可留空）", text: $key); Button("保存 Key") { do { try KeychainStore.save(key, for: profile.id) } catch { model.errorMessage = error.localizedDescription } } }
            TextField("语言（留空自动）", text: $profile.language)
            TextField("返回格式（可留空）", text: $profile.responseFormat)
            TextField("提示 / 热词", text: $profile.prompt, axis: .vertical).lineLimit(2...4)
            HStack { TextField("分段秒数", value: $profile.chunkSeconds, format: .number); TextField("单文件 MB", value: $profile.maxUploadMB, format: .number) }
            HStack { Stepper("并发：\(profile.concurrency)", value: $profile.concurrency, in: 1...8); TextField("超时秒数", value: $profile.timeoutSeconds, format: .number) }
            HStack {
                Button(testing ? "正在测试…" : "选择音频测试（前 5 秒）") { test() }.disabled(testing || profile.baseURL.isEmpty || profile.model.isEmpty)
                Button("查看测试结果") { showResponse = true }.disabled(response.isEmpty)
            }
        }.formStyle(.grouped)
        .onAppear { key = KeychainStore.read(profile.id) ?? "" }
        .sheet(isPresented: $showResponse) { VStack(alignment: .leading) { Text("ASR 测试 · 解析结果与原始返回").font(.headline); TextEditor(text: .constant(response)).font(.callout.monospaced()); Button("关闭") { showResponse = false } }.padding(22).frame(width: 640, height: 440) }
    }
    private func test() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let p = profile; let apiKey = key
        testing = true
        Task {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { testing = false; try? FileManager.default.removeItem(at: dir); showResponse = true }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let wav = dir.appendingPathComponent("test.wav")
                _ = try await AudioFileTools.prepareForASR(source: source, destination: wav)
                let chunks = try AudioFileTools.splitForASR(source: wav, into: dir.appendingPathComponent("chunks"), seconds: 5)
                guard let first = chunks.first else { throw MeetingError.message("音频为空") }
                let result = try await AIClient().transcribe(file: first.url, profile: p, apiKey: apiKey)
                response = "解析结果：\n\(result.text)\n\n片段数：\(result.segments.count)\n\n原始返回：\n\(result.rawResponse ?? "无")"
            } catch { response = error.localizedDescription }
        }
    }
}
struct LLMEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var result = ""
    @State private var testing = false
    var body: some View {
        Form {
            Section("OpenAI 兼容聊天接口") {
                TextField("名称", text: $model.settings.llmProfile.name)
                TextField("API 地址", text: $model.settings.llmProfile.baseURL, prompt: Text("https://服务地址/v1"))
                TextField("模型名称", text: $model.settings.llmProfile.model)
                HStack { SecureField("API Key", text: $key); Button("保存 Key") { do { try KeychainStore.save(key, for: model.settings.llmProfile.id) } catch { model.errorMessage = error.localizedDescription } } }
                TextField("超时秒数", value: $model.settings.llmProfile.timeoutSeconds, format: .number)
            }
            Section("总结方式") {
                Toggle("转写后自动总结", isOn: $model.settings.autoSummarize)
                TextEditor(text: $model.settings.llmProfile.prompt).frame(height: 120)
                Text("可以使用 DeepSeek 或其他兼容接口，也可连接你的内网 LLM。") .font(.caption).foregroundStyle(Brand.secondary)
            }
            Button(testing ? "正在测试…" : "测试连接") {
                testing = true; let p = model.settings.llmProfile; let apiKey = key
                Task { defer { testing = false }; do { result = try await AIClient().summarize(transcript: "这是连接测试，没有会议内容。请只回复：连接成功。", profile: p, apiKey: apiKey) } catch { result = error.localizedDescription } }
            }.disabled(testing || model.settings.llmProfile.baseURL.isEmpty || model.settings.llmProfile.model.isEmpty)
            if !result.isEmpty { Text(result).textSelection(.enabled) }
        }.formStyle(.grouped).onAppear { key = KeychainStore.read(model.settings.llmProfile.id) ?? "" }
    }
}
