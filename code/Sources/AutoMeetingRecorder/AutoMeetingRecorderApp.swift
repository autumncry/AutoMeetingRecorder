import SwiftUI
import UserNotifications
import MeetingCore

@main struct AutoMeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup(Brand.name, id: "library") {
            LibraryView().environmentObject(model).onAppear { AppDelegate.model = model }
                .frame(minWidth: 850, minHeight: 580).tint(Brand.accent).foregroundStyle(Brand.text)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入录音…") { model.chooseAudioFiles() }.keyboardShortcut("i", modifiers: [.command])
                Button("导入分享链接…") { model.showLinkSheet = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button(model.activeRecording == nil ? "开始录音" : "停止并保存") {
                    Task { if model.activeRecording == nil { await model.beginRecording() } else { await model.endRecording() } }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView().environmentObject(model).frame(width: 680, height: 590).tint(Brand.accent) }
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            if model.activeRecording == nil { Image(nsImage: Brand.menuIcon) }
            else { Image(systemName: "record.circle.fill").symbolRenderingMode(.palette).foregroundStyle(Color.red) }
        }
    }
}
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("AMR · " + model.recordingLabel)
        if model.activeRecording != nil { Text(LocalStore.timestamp(model.elapsed)) }
        if model.activeRecording?.status == .pending {
            Button("保留并继续录音") { model.confirmRecording() }
            Button("不录，丢弃") { Task { await model.endRecording(discard: true) } }
        } else if model.activeRecording != nil {
            Button("停止并保存") { Task { await model.endRecording() } }
            Button(model.isPaused ? "继续录音" : "暂停录音") { model.togglePause() }
        } else { Button("开始录音") { Task { await model.beginRecording() } } }
        Divider()
        Toggle("自动检测飞书", isOn: $model.settings.automaticDetection)
        Button("打开资料库") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 AutoMeetingRecorder") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if let icon = Brand.icon { NSApp.applicationIconImage = icon }
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.activeRecording != nil else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "录音尚未结束"; alert.informativeText = "退出前保存录音。待确认录音会被丢弃。"; alert.addButton(withTitle: "保存并退出"); alert.addButton(withTitle: "继续录音")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.terminating = true
        Task { await model.endRecording(); model.processingTask?.cancel(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in Self.model?.notificationAction(response.actionIdentifier, sessionID: id); completionHandler() }
    }
}
