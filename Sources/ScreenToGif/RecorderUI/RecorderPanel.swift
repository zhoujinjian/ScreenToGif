import AppKit
import SwiftUI

/// 录制控制条宿主（NSPanel：不抢焦点 + 不进屏幕捕获）。
/// 复刻原版 Recorder.xaml 31pt 底栏布局。
final class RecorderPanel: NSPanel {
    init(region: CaptureRegion, viewModel: RecorderViewModel) {
        let content = NSHostingView(rootView: RecorderPanelView(viewModel: viewModel))
        let size = NSSize(width: max(430, content.fittingSize.width), height: 42)
        // 初始位置：选区下边缘外 6px；放不下则放选区内贴底。
        var origin = CGPoint(x: region.rect.midX - size.width / 2, y: region.rect.minY - size.height - 6)
        if let screen = DisplayInfo.by(id: region.displayID)?.screen {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = region.rect.maxY + 6
            }
            if origin.y + size.height > visible.maxY {
                origin.y = region.rect.minY - size.height - 6   // 兜底放选区下
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isReleasedWhenClosed = false   // 防过度释放（Swift 持有 + close 即回收会变僵尸）
        level = .floating
        backgroundColor = NSColor(Theme.panel2)
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none       // 关键：不出现在录制画面中
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        contentView = content
    }

    override var canBecomeKey: Bool { true }
}
