import AppKit

/// 托盘图标（NSStatusItem），复刻原版 NotifyIcon 行为：新建录制/编辑器/选项/退出。
final class StatusItemController {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?

    private init() {}

    func activate() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "ScreenToGif")

        let menu = NSMenu()

        menu.addItem(withTitle: "新建屏幕录制", action: #selector(startScreenRecording), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "编辑器", action: #selector(openEditor), keyEquivalent: "e")
        menu.addItem(withTitle: "选项…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ScreenToGif", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func startScreenRecording() {
        // 直接进入选区（beginFlow 会隐藏启动器，先 show 会闪一下）
        WindowManager.shared.launcherRequestScreenRecorder()
    }

    @objc private func openEditor() {
        WindowManager.shared.showEditor(with: nil)
    }

    @objc private func openSettings() {
        WindowManager.shared.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
