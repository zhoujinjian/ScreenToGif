import AppKit

/// 选区覆盖窗按键动作（由控制器统一裁决，支持跨显示器选区）。
enum OverlayKeyAction {
    case confirm
    case cancel
}

/// 选区覆盖窗：每显示器一个，全屏无边框、置顶、透明、不参与捕获。
final class SelectionOverlayWindow: NSWindow {
    let display: DisplayInfo
    let overlayView: SelectionOverlayView
    /// 键盘动作出口（返回 false 表示未处理，继续走默认链）。
    var onKeyAction: ((OverlayKeyAction) -> Bool)?

    init(display: DisplayInfo, view: SelectionOverlayView) {
        self.display = display
        self.overlayView = view
        super.init(
            contentRect: display.appKitFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .screenSaver
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        // 关键：不显示在屏幕捕获中（避免选区 UI 进画面）
        self.sharingType = .none
        self.contentView = view
    }

    /// 关键修复：borderless 窗口默认 canBecomeKey == false，
    /// makeKeyAndOrderFront 会静默失败 → 键盘事件永远不可达 → Enter/Esc 失灵、
    /// 全屏遮罩吞掉所有鼠标点击，用户被锁死在遮罩下。
    override var canBecomeKey: Bool { true }

    /// 第二层保险：只要窗口是 key window，Esc/Enter 无需经过 first responder 链即可处理，
    /// 防止视图焦点异常时按键丢失。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc（含 Cmd+.，keyCode 同为 53）
            return onKeyAction?(.cancel) ?? false
        case 36, 76: // Return / 小键盘 Enter
            return onKeyAction?(.confirm) ?? false
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
