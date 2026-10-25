import AppKit
import SwiftUI

/// 窗口管理中枢：启动器 / 设置 / 编辑器 的创建、显示与互斥。
final class WindowManager {
    static let shared = WindowManager()

    private var launcherWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var recorderFlow: RecorderViewModel?

    /// 屏幕录制入口（由录制流程模块注册；里程碑 C/D 前为占位）。
    var startScreenRecordingHandler: (() -> Void)?

    private init() {}

    // MARK: - 启动器

    func showLauncher() {
        let window: NSWindow
        if let existing = launcherWindow {
            window = existing
        } else {
            window = makeFramelessSized(
                size: NSSize(width: 500, height: 230),
                content: LauncherView()
            )
            window.title = "ScreenToGif"
            window.isRestorable = false
            launcherWindow = window
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// 录制期间隐藏启动器（避免入镜）。
    func hideLauncher() {
        launcherWindow?.orderOut(nil)
    }

    /// 托盘/启动器请求开始屏幕录制。
    func launcherRequestScreenRecorder() {
        if let handler = startScreenRecordingHandler {
            handler()
        } else {
            // 默认录制流程（选区 → 控制 → 编辑器）
            let flow = recorderFlow ?? RecorderViewModel()
            recorderFlow = flow
            flow.beginFlow()
        }
    }

    func launchWebcamRecorder() {
        showPlaceholderAlert(feature: "摄像头录制（Phase 3）")
    }

    func launchBoardRecorder() {
        showPlaceholderAlert(feature: "画板录制（Phase 3）")
    }

    // MARK: - 设置

    func showSettings() {
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = makeStandardWindow(
                size: NSSize(width: 760, height: 520),
                title: "选项",
                content: SettingsWindowView()
            )
            window.isRestorable = false
            settingsWindow = window
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 编辑器

    func showEditor(with project: Project?) {
        let window: NSWindow
        if let existing = editorWindow {
            window = existing
            if let vm = (existing.contentViewController as? NSHostingController<EditorWindowView>)?.rootView.viewModel {
                if let project { vm.load(project: project) }
            }
        } else {
            let viewModel = EditorViewModel()
            if let project { viewModel.load(project: project) }
            window = makeStandardWindow(
                size: NSSize(width: 1180, height: 760),
                title: "编辑器 — ScreenToGif",
                content: EditorWindowView(viewModel: viewModel)
            )
            window.isRestorable = false
            window.setFrameAutosaveName("EditorWindow")
            editorWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// spike 验证：模拟用户点 X 关闭当前存在的窗口（launcher/editor/settings）。
    func debugCloseAllWindows() {
        launcherWindow?.performClose(nil)
        editorWindow?.performClose(nil)
        settingsWindow?.performClose(nil)
    }

    // MARK: - 工具

    private func makeFramelessSized(size: NSSize, content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 关键：Swift 持有窗口时必须关闭 releasedWhenClosed，否则点 X 关闭会额外
        // release 导致过度释放，缓存的窗口引用变僵尸（点 Dock 图标重开时 SIGSEGV）。
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Theme.background)
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    private func makeStandardWindow(size: NSSize, title: String, content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false   // 同上：防过度释放僵尸窗口
        window.title = title
        window.backgroundColor = NSColor(Theme.background)
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    private func showPlaceholderAlert(feature: String) {
        let alert = NSAlert()
        alert.messageText = "功能建设中"
        alert.informativeText = "\(feature) 将在后续里程碑接入。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
