import AppKit
import ScreenCaptureKit

/// 可选窗口列表（选区吸附用）。基于 SCShareableContent.windows（CGWindowListCopyWindowInfo 已废弃）。
final class WindowLister {
    struct Target {
        let frame: CGRect          // AppKit 全局坐标
        let title: String
        let ownerName: String
        let owningApplication: SCRunningApplication?
    }

    private(set) var targets: [Target] = []

    /// 刷新窗口快照（过滤：可见窗口层、有尺寸、非本应用）。
    /// 注意：SCWindow.frame 为 CG 坐标（左上原点），此处统一转换为 AppKit 全局坐标（左下原点）。
    func refresh() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            targets = []
            return
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let myPID = ProcessInfo.processInfo.processIdentifier
        targets = content.windows.compactMap { window -> Target? in
            let cg = window.frame
            guard !cg.isEmpty, cg.width >= 25, cg.height >= 25 else { return nil }
            guard window.owningApplication?.processID != myPID else { return nil }
            let appKitFrame = CGRect(x: cg.minX, y: mainHeight - cg.maxY, width: cg.width, height: cg.height)
            return Target(
                frame: appKitFrame,
                title: window.title ?? "",
                ownerName: window.owningApplication?.applicationName ?? "",
                owningApplication: window.owningApplication
            )
        }
    }

    /// 命中测试：返回包含点的最上层窗口（列表已按 z 序排列，取最后一个命中的）。
    func hitTest(_ point: CGPoint) -> Target? {
        for target in targets.reversed() where target.frame.contains(point) {
            return target
        }
        return nil
    }
}
