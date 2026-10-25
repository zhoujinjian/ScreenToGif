import AppKit

/// 选区流程编排：弹覆盖窗 → 用户拖选/点窗口 → Enter 确认 → 回调 CaptureRegion。
///
/// 键盘可达性四层保险（任一生效即可退出，绝不把用户锁死在全屏遮罩下）：
/// 1. 覆盖窗 canBecomeKey == true（根修：borderless 默认不可成 key）
/// 2. 覆盖窗 performKeyEquivalent 拦 Esc/Enter（不依赖 first responder）
/// 3. 本类 local keyDown monitor（app 激活即有效，与窗口 key 状态无关）
/// 4. app 失活（Cmd+Tab 切走等）自动取消撤遮罩；右键任意时刻可取消
final class RegionSelectController: NSObject {
    static let shared = RegionSelectController()

    private var overlays: [SelectionOverlayWindow] = []
    private let windowLister = WindowLister()
    private var completion: ((CaptureRegion?) -> Void)?
    private var keyMonitor: Any?

    private override init() {
        super.init()
        // key window 丢失守卫：注册一次，事件里按 overlays 过滤。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(overlayDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    /// 调试/验证用：首个覆盖窗是否为 key window（nil = 当前无覆盖窗）。
    var debugOverlayIsKeyWindow: Bool? { overlays.first?.isKeyWindow }

    /// spike 验证：合成一次拖拽选区（直接驱动 view 状态机，不经事件路由），返回是否有有效选区。
    func debugSynthesizeDragSelection() -> Bool {
        guard let window = overlays.first else { return false }
        let view = window.overlayView
        let b = view.bounds
        let p0 = NSPoint(x: b.width * 0.3, y: b.height * 0.3)
        let p1 = NSPoint(x: b.width * 0.7, y: b.height * 0.7)
        func mk(_ type: NSEvent.EventType, _ loc: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: loc, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            )
        }
        guard let down = mk(.leftMouseDown, p0),
              let drag = mk(.leftMouseDragged, p1),
              let up = mk(.leftMouseUp, p1) else { return false }
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        return view.hasValidSelection
    }

    /// spike 验证：合成拖拽（固定 0.3~0.7 居中）后，view 的 global 转换与独立数学计算是否一致。
    /// 独立数学：期望 y = winFrame.minY + (H − 0.7H_view)（flipped 视觉底 → AppKit 左下角语义）。
    func debugVerifyConversionMath() -> Bool {
        guard let window = overlays.first else { return false }
        let view = window.overlayView
        guard view.hasValidSelection else { return false }
        let b = view.bounds.size
        let f = window.frame
        let expected = CGRect(
            x: f.minX + b.width * 0.3,
            y: f.minY + (b.height - b.height * 0.7),
            width: b.width * 0.4,
            height: b.height * 0.4
        )
        let actual = view.debugGlobalSelection
        return abs(actual.midX - expected.midX) < 0.5
            && abs(actual.midY - expected.midY) < 0.5
            && abs(actual.width - expected.width) < 0.5
            && abs(actual.height - expected.height) < 0.5
    }

    /// spike 验证：合成 Enter keyDown 经 NSApp.sendEvent 走完整 AppKit 分发。
    func debugSendEnterKey() {
        guard let window = overlays.first,
              let enter = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
              ) else { return }
        NSApp.sendEvent(enter)
    }

    /// 开始选区。completion 在主线程回调；nil = 用户取消。
    func begin(completion: @escaping (CaptureRegion?) -> Void) {
        guard self.completion == nil else { return }   // 已在进行中

        // 无屏幕录制权限时先引导
        guard PermissionManager.hasScreenCapture() || PermissionManager.requestScreenCapture() else {
            PermissionManager.showScreenCaptureGuide()
            completion(nil)
            return
        }

        Task { @MainActor in
            guard self.completion == nil else { return }
            self.completion = completion

            await self.windowLister.refresh()

            let displays = DisplayInfo.all()
            guard !displays.isEmpty else {
                self.finish(with: nil)
                return
            }

            self.installKeyMonitor()

            // 先激活再弹窗：app 未激活时 borderless 窗口申请 key 会被系统拒绝
            NSApp.activate(ignoringOtherApps: true)

            self.overlays = displays.map { display in
                let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: display.appKitFrame.size))
                view.windowLister = self.windowLister
                view.snapEnabled = UserSettings.shared.snapToWindow
                view.onConfirm = { [weak self] region in
                    self?.finish(with: region)
                }
                view.onCancel = { [weak self] in
                    self?.finish(with: nil)
                }
                let window = SelectionOverlayWindow(display: display, view: view)
                window.onKeyAction = { [weak self] action in
                    self?.handleKeyAction(action) ?? false
                }
                window.orderFrontRegardless()
                return window
            }
            // 第一个覆盖窗成为 key window（其余仅显示）
            self.overlays.first?.makeKeyAndOrderFront(nil)
            // key 状态不稳（系统弹窗/焦点抢占可致 activate 失败）→ 主动重试确认
            self.reassertKeyWindow(attempt: 0)
        }
    }

    /// 确保任一覆盖窗持有 key：没有则重激活重申请（最多 5 次 × 0.35s）。
    private func reassertKeyWindow(attempt: Int) {
        guard completion != nil, attempt < 5 else { return }
        if overlays.contains(where: { $0.isKeyWindow }) {
            if attempt > 0 { Log.app.notice("选区覆盖窗 key 已恢复（第 \(attempt, privacy: .public) 次重试）") }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        overlays.first?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.reassertKeyWindow(attempt: attempt + 1)
        }
    }

    // MARK: - 按键裁决

    /// 仅在主线程调用（NSEvent monitor 与窗口按键链均保证主线程）。
    private func handleKeyAction(_ action: OverlayKeyAction) -> Bool {
        guard completion != nil else { return false }
        switch action {
        case .cancel:
            Log.app.notice("选区按键：取消")
            finish(with: nil)
            return true
        case .confirm:
            let ok = confirmAnySelection()
            if !ok { Log.app.notice("选区按键：确认未生效（无有效选区或校验未通过）") }
            return ok
        }
    }

    /// 跨显示器确认：选区可能在非 key window 的那块屏上。
    private func confirmAnySelection() -> Bool {
        guard overlays.contains(where: { $0.overlayView.hasValidSelection }) else {
            Log.app.notice("确认扫描：\(self.overlays.count, privacy: .public) 个覆盖窗均无有效选区")
            // 反馈到 key 覆盖窗（无选区/选区过小都要让用户看见原因，不能无声吞掉 Enter）
            let view = overlays.first(where: { $0.isKeyWindow })?.overlayView
                ?? overlays.first?.overlayView
            view?.flashStatus("尚未选择录制区域，请先拖选或单击窗口吸附")
            return false
        }
        for window in overlays where window.overlayView.hasValidSelection {
            window.overlayView.confirmIfPossible()   // 内含 onConfirm → finish
            return true
        }
        return false
    }

    // MARK: - 键盘兜底 monitor

    /// 第三层保险：app 激活期间无论窗口 key 状态如何，Esc/Enter 必达。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.completion != nil else { return event }
            switch event.keyCode {
            case 53: // Esc
                _ = self.handleKeyAction(.cancel)
                return nil            // 消费，避免再走窗口链
            case 36, 76: // Return / 小键盘 Enter
                _ = self.handleKeyAction(.confirm)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - key 丢失守卫

    @objc private func overlayDidResignKey(_ note: Notification) {
        guard completion != nil,
              let window = note.object as? SelectionOverlayWindow,
              overlays.contains(window) else { return }
        // 我们的任一覆盖窗仍是 key → 正常状态，忽略
        if overlays.contains(where: { $0.isKeyWindow }) { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.completion != nil else { return }
            if NSApp.isActive {
                // app 仍激活但 key 意外丢失：抢回，保证键盘可达
                NSApp.activate(ignoringOtherApps: true)
                self.overlays.first?.makeKey()
            } else {
                // 用户已切走（Cmd+Tab 等）：自动取消，绝不留遮罩锁屏
                self.finish(with: nil)
            }
        }
    }

    // MARK: - 收尾

    private func finish(with region: CaptureRegion?) {
        let handler = completion
        completion = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for overlay in overlays {
            overlay.orderOut(nil)
        }
        overlays = []
        handler?(region)
    }
}
