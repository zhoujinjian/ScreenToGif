import AppKit
import CoreGraphics
import ApplicationServices

/// 权限引导：屏幕录制（TCC）与辅助功能（CGEventTap 需要）。
enum PermissionManager {
    /// 屏幕录制权限是否已授予。
    static func hasScreenCapture() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 请求屏幕录制权限（触发系统弹窗；授予后需重启应用生效）。
    /// 返回：当前是否已有权限。
    @discardableResult
    static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    /// 辅助功能权限（用于 CGEventTap 记录点击/按键）。
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// 请求辅助功能权限（弹系统引导窗）。
    @discardableResult
    static func requestAccessibility(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        if prompt {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    /// 权限缺失时的用户引导弹窗。
    static func showScreenCaptureGuide() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 ScreenToGif，然后重启本应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }
}
