import AppKit
import SwiftUI

@main struct XianwaiwuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var work = Workspace()
    var body: some Scene {
        Window("弦外屋", id: "studio") {
            StudioRootView(workspace: work)
                .frame(minWidth: 880, minHeight: 588)
                .preferredColorScheme(.dark)
                .background(WindowConfiguration(work: work))
                .onAppear { delegate.work = work }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开音频…", action: work.chooseInput).keyboardShortcut("o").disabled(work.busy || work.importing)
                Button("所有项目", action: work.showHome).keyboardShortcut("1")
            }
            CommandGroup(after: .appInfo) {
                Button("开源许可与模型来源") {
                    let notices = Project.root.appendingPathComponent("THIRD_PARTY_NOTICES.md")
                    NSWorkspace.shared.open(notices)
                }
            }
            CommandGroup(replacing: .appSettings) { }
            CommandMenu("乐谱") {
                Button("打开弹唱谱", action: work.openScore)
                    .disabled(work.currentProject == nil || work.showingHome || work.rangeEditing)
                Button("导出弹唱谱 PDF…") { work.exportScore(pdf: true) }
                    .disabled(work.currentScore == nil || work.showingHome)
            }
            CommandMenu("歌词") {
                Button("导入带时间的歌词…", action: work.chooseLyrics)
                    .disabled(work.currentProject == nil || work.showingHome || work.importingLyrics)
                Button("导出歌词…", action: work.exportLyrics)
                    .disabled(work.currentProject?.lyrics == nil || work.showingHome)
            }
            CommandMenu("播放") {
                Button("播放 / 暂停", action: work.togglePlayback)
                Button("向前一秒") { work.seekAbsolute(work.absoluteTime+1) }
                Button("向后一秒") { work.seekAbsolute(work.absoluteTime-1) }
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var work: Workspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let work else { return .terminateNow }
        if work.busy {
            let alert = NSAlert(); alert.messageText = "退出会取消当前任务"; alert.informativeText = "项目和已经完成的分离结果会保留。"; alert.addButton(withTitle: "取消任务并退出"); alert.addButton(withTitle: "继续处理")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            work.quit()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                if !work.hasRunningProcess { timer.invalidate(); sender.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        work.quit(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
private struct WindowConfiguration: NSViewRepresentable {
    let work: Workspace
    func makeCoordinator() -> WindowCloseGuard { WindowCloseGuard() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 21/255, green: 21/255, blue: 19/255, alpha: 1)
            window.minSize = NSSize(width: 880, height: 620)
            window.setContentSize(NSSize(width: 1120, height: 740)); window.center()
            window.tabbingMode = .disallowed
            context.coordinator.forwarded = window.delegate
            window.delegate = context.coordinator
            if let index = CommandLine.arguments.firstIndex(of: "--verify-score"), CommandLine.arguments.count > index + 1 {
                ScoreAcceptance.run(work: work, window: window,
                                    destination: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                    reopen: CommandLine.arguments.contains("--score-reopen"))
            }
            if let index = CommandLine.arguments.firstIndex(of: "--verify"), CommandLine.arguments.count > index+1 {
                NativeAcceptance.run(work: work, window: window, destination: URL(fileURLWithPath: CommandLine.arguments[index+1]))
            }
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
}

/// Ask before closing the last window, so choosing to continue keeps the studio visible.
private final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var forwarded: NSWindowDelegate?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwarded?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwarded?.responds(to: selector) == true { return forwarded }
        return super.forwardingTarget(for: selector)
    }
}
