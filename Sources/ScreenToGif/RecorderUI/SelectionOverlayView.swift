import AppKit

/// 选区覆盖视图：50% 遮罩挖洞 + 拖拽选区 + 窗口吸附高亮 + 8 手柄调整。
/// 每显示器一个，由 RegionSelectController 编排。
final class SelectionOverlayView: NSView {
    // MARK: 回调（主线程）
    var onConfirm: ((CaptureRegion) -> Void)?
    var onCancel: (() -> Void)?
    /// 窗口命中（view 内坐标）→ 由控制器决定是否吸附。
    var windowLister: WindowLister?
    var snapEnabled = true

    private enum Interaction: Equatable {
        case none
        case dragging(anchor: CGPoint)        // view 坐标（flipped）
        case moving(offset: CGSize, origin: CGRect)
        case resizing(handle: Handle)
    }

    private enum Handle: Int, CaseIterable {
        case topLeft = 0, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func cursor() -> NSCursor {
            switch self {
            case .topLeft, .bottomRight, .topRight, .bottomLeft:
                return .crosshair   // 对角手柄（P1 用十字光标，后续可换斜向箭头）
            case .top, .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            }
        }
    }

    private var interaction: Interaction = .none
    /// 选区（view 本地 flipped 坐标，原点左上）。
    private var selection: CGRect = .zero
    private var hasSelection = false
    /// mouseDown 前的选区快照：单击空白（触控板误触常见）时恢复旧选区，不静默丢失。
    private var selectionSnapshot: CGRect?
    /// 状态提示（Enter 无选区等反馈），限时显示。
    private var statusMessage: String?
    private var statusUntil = Date.distantPast
    /// 悬停窗口高亮（view 坐标）。
    private var hoveredWindowRect: CGRect?
    private var hoverLastCheck = Date.distantPast

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// 是否存在可确认的选区（供控制器跨显示器查找）。
    var hasValidSelection: Bool {
        hasSelection && selection.width >= 25 && selection.height >= 25
    }

    /// spike 验证用：当前选区的 AppKit 全局 rect（经 convertToGlobal）。
    var debugGlobalSelection: CGRect { convertToGlobal(selection) }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let mask = NSColor.black.withAlphaComponent(0.5)
        mask.setFill()

        if hasSelection {
            // 选区四周遮罩（四边形拼合，避免合成操作）
            let inset = selection
            NSRect(x: 0, y: 0, width: bounds.width, height: inset.minY).fill()                    // 上
            NSRect(x: 0, y: inset.maxY, width: bounds.width, height: bounds.height - inset.maxY).fill()  // 下
            NSRect(x: 0, y: inset.minY, width: inset.minX, height: inset.height).fill()           // 左
            NSRect(x: inset.maxX, y: inset.minY, width: bounds.width - inset.maxX, height: inset.height).fill() // 右

            // 边框（原版蓝色录制边框）
            NSColor(hex: 0x0066CC).setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()

            // 尺寸标签
            let label = "\(Int(selection.width)) × \(Int(selection.height))"
            drawLabel(label, above: selection)

            // 手柄
            for handle in Handle.allCases {
                let r = handleRect(handle)
                NSColor.white.setFill()
                r.fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(rect: r).stroke()
            }
        } else {
            bounds.fill()

            // 悬停窗口高亮（提亮挖洞）
            if let hovered = hoveredWindowRect {
                NSColor.black.withAlphaComponent(0.2).setFill()
                hovered.fill()
                NSColor.white.withAlphaComponent(0.7).setStroke()
                let path = NSBezierPath(rect: hovered)
                path.lineWidth = 1
                path.stroke()
            }
            drawHint()
        }

        // 状态提示（确认失败反馈），浮于遮罩上方
        if let status = statusMessage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = status.size(withAttributes: attrs)
            let box = NSRect(
                x: bounds.midX - size.width / 2 - 12,
                y: bounds.midY - size.height / 2 + 34,
                width: size.width + 24, height: size.height + 16
            )
            NSColor(calibratedRed: 0.88, green: 0.32, blue: 0.32, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            status.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attrs)
        }
    }

    private func drawLabel(_ text: String, above rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        origin.y = max(origin.y, 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(
            x: origin.x - 5, y: origin.y - 3,
            width: size.width + 10, height: size.height + 6
        ), xRadius: 3, yRadius: 3).fill()
        text.draw(at: origin, withAttributes: attrs)
    }

    private func drawHint() {
        let hint = "拖拽选择录制区域 · 单击窗口吸附 · Enter 确认 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white
        ]
        let size = hint.size(withAttributes: attrs)
        NSColor.black.withAlphaComponent(0.6).setFill()
        let box = NSRect(
            x: bounds.midX - size.width / 2 - 12, y: bounds.midY - size.height / 2 - 8,
            width: size.width + 24, height: size.height + 16
        )
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        hint.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hasSelection {
            if let handle = hitHandle(p) {
                interaction = .resizing(handle: handle)
                return
            }
            if selection.insetBy(dx: -6, dy: -6).contains(p) {
                interaction = .moving(offset: CGSize(width: p.x - selection.minX, height: p.y - selection.minY), origin: selection)
                return
            }
        }
        // 新选区（或单击吸附窗口）
        if !hasSelection || !selection.contains(p) {
            selectionSnapshot = hasSelection ? selection : nil
            interaction = .dragging(anchor: p)
            selection = CGRect(origin: p, size: .zero)
            hasSelection = false
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch interaction {
        case .dragging(let anchor):
            selection = rectFrom(anchor: anchor, to: p)
            hasSelection = true
            hoveredWindowRect = nil
        case .moving(let offset, let origin):
            var r = origin
            r.origin = CGPoint(x: p.x - offset.width, y: p.y - offset.height)
            r.origin.x = r.origin.x.clamped(to: 0...bounds.width - r.width)
            r.origin.y = r.origin.y.clamped(to: 0...bounds.height - r.height)
            selection = r
        case .resizing(let handle):
            selection = resize(selection, with: handle, to: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch interaction {
        case .dragging(let anchor):
            let r = rectFrom(anchor: anchor, to: p)
            if r.width < 10 || r.height < 10 {
                // 视为单击：吸附悬停窗口
                if snapEnabled, let lister = windowLister, let target = lister.hitTest(globalPoint(for: p)) {
                    selection = convertFromGlobal(target.frame)
                    hasSelection = true
                } else if let snapshot = selectionSnapshot {
                    // 单击空白（触控板误触常见）：恢复原选区，不静默丢失
                    selection = snapshot
                    hasSelection = true
                } else {
                    // 原本就没有选区：重置
                    hasSelection = false
                    selection = .zero
                }
            } else {
                hasSelection = true
            }
        default:
            break
        }
        selectionSnapshot = nil
        interaction = .none
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 60ms 节流命中测试
        if Date().timeIntervalSince(hoverLastCheck) > 0.06 {
            hoverLastCheck = Date()
            let global = globalPoint(for: p)
            let hit = (snapEnabled && !hasSelection) ? windowLister?.hitTest(global) : nil
            let newRect = hit.map { convertFromGlobal($0.frame) }
            if newRect != hoveredWindowRect {
                hoveredWindowRect = newRect
                needsDisplay = true
            }
        }
        // 手柄光标
        if hasSelection, interaction == .none, let handle = hitHandle(p) {
            handle.cursor().set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Enter / Return
            confirmIfPossible()
        default:
            super.keyDown(with: event)
        }
    }

    /// 右键逃生门：即使键盘事件因任何原因不可达，右键也能退出全屏遮罩。
    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    func confirmIfPossible() {
        guard hasSelection, selection.width >= 25, selection.height >= 25 else {
            Log.app.notice("选区确认被拒：选区无效 hasSelection=\(self.hasSelection, privacy: .public) 尺寸=\(Int(self.selection.width), privacy: .public)×\(Int(self.selection.height), privacy: .public)")
            flashStatus(hasSelection ? "选区太小（至少 25×25），请重新拖选" : "尚未选择录制区域，请先拖选或单击窗口吸附")
            return
        }
        let global = convertToGlobal(selection)
        guard let display = DisplayInfo.containing(CGPoint(x: global.midX, y: global.midY)) else {
            Log.app.notice("选区确认被拒：中点 (\(Int(global.midX), privacy: .public), \(Int(global.midY), privacy: .public)) 未命中任何显示器")
            flashStatus("选区位置异常（未命中显示器），请重新选择")
            return
        }
        Log.app.notice("选区确认：global=(\(Int(global.minX), privacy: .public),\(Int(global.minY), privacy: .public),\(Int(global.width), privacy: .public)×\(Int(global.height), privacy: .public)) displayID=\(display.displayID, privacy: .public)")
        onConfirm?(CaptureRegion(rect: global, displayID: display.displayID))
    }

    /// 限时状态提示（确认失败等反馈）：beep + 中上浮字。
    func flashStatus(_ text: String) {
        statusMessage = text
        statusUntil = Date().addingTimeInterval(1.8)
        needsDisplay = true
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, Date() >= self.statusUntil, self.statusMessage != nil else { return }
            self.statusMessage = nil
            self.needsDisplay = true
        }
    }

    // MARK: - 坐标

    /// view 本地（flipped，y 向下）→ AppKit 全局（y 向上）。
    /// 关键：flipped 的 rect.origin 是视觉左上角，而目标坐标系的 origin 语义是左下角，
    /// 必须转换两个对角点再取 min/max（单点转换会把矩形垂直翻转错位）。
    private func convertToGlobal(_ r: CGRect) -> CGRect {
        guard let window = window else { return r }
        let p1 = convert(CGPoint(x: r.minX, y: r.minY), to: nil)   // 视觉左上 → 窗口坐标
        let p2 = convert(CGPoint(x: r.maxX, y: r.maxY), to: nil)   // 视觉右下 → 窗口坐标
        let winRect = CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
        return window.convertToScreen(winRect)
    }

    /// AppKit 全局 → view 本地（flipped）。同样双角转换。
    private func convertFromGlobal(_ r: CGRect) -> CGRect {
        guard let window = window else { return r }
        let winRect = window.convertFromScreen(r)
        let p1 = convert(CGPoint(x: winRect.minX, y: winRect.minY), from: nil)
        let p2 = convert(CGPoint(x: winRect.maxX, y: winRect.maxY), from: nil)
        return CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
    }

    private func globalPoint(for p: CGPoint) -> CGPoint {
        convertToGlobal(CGRect(origin: p, size: .zero)).origin
    }

    // MARK: - 手柄

    private static let handleSize: CGFloat = 8

    private func handleRect(_ handle: Handle) -> CGRect {
        let s = Self.handleSize
        let midX = selection.midX - s / 2, midY = selection.midY - s / 2
        let minX = selection.minX - s / 2, maxX = selection.maxX - s / 2
        let minY = selection.minY - s / 2, maxY = selection.maxY - s / 2
        switch handle {
        case .topLeft: return CGRect(x: minX, y: minY, width: s, height: s)
        case .top: return CGRect(x: midX, y: minY, width: s, height: s)
        case .topRight: return CGRect(x: maxX, y: minY, width: s, height: s)
        case .right: return CGRect(x: maxX, y: midY, width: s, height: s)
        case .bottomRight: return CGRect(x: maxX, y: maxY, width: s, height: s)
        case .bottom: return CGRect(x: midX, y: maxY, width: s, height: s)
        case .bottomLeft: return CGRect(x: minX, y: maxY, width: s, height: s)
        case .left: return CGRect(x: minX, y: midY, width: s, height: s)
        }
    }

    private func hitHandle(_ p: CGPoint) -> Handle? {
        guard hasSelection else { return nil }
        return Handle.allCases.first { handleRect($0).insetBy(dx: -3, dy: -3).contains(p) }
    }

    // MARK: - 几何工具

    private func rectFrom(anchor: CGPoint, to p: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, p.x), y: min(anchor.y, p.y),
            width: abs(anchor.x - p.x), height: abs(anchor.y - p.y)
        )
    }

    private func resize(_ r: CGRect, with handle: Handle, to p: CGPoint) -> CGRect {
        var rect = StandardRect(r)
        switch handle {
        case .topLeft: rect.topLeft = p
        case .top: rect.top = p.y
        case .topRight: rect.topRight = p
        case .right: rect.right = p.x
        case .bottomRight: rect.bottomRight = p
        case .bottom: rect.bottom = p.y
        case .bottomLeft: rect.bottomLeft = p
        case .left: rect.left = p.x
        }
        var out = rect.cgRect
        // 最小尺寸 + 边界
        out.size.width = max(25, min(out.width, bounds.width))
        out.size.height = max(25, min(out.height, bounds.height))
        out.origin.x = out.origin.x.clamped(to: 0...bounds.width - out.width)
        out.origin.y = out.origin.y.clamped(to: 0...bounds.height - out.height)
        return out
    }
}

/// flipped 视图里的“上下左右”辅助（top = y 小）。
private struct StandardRect {
    var left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat
    init(_ r: CGRect) {
        left = r.minX; right = r.maxX; top = r.minY; bottom = r.maxY
    }
    var cgRect: CGRect {
        CGRect(x: min(left, right), y: min(top, bottom),
               width: abs(right - left), height: abs(bottom - top))
    }
    var topLeft: CGPoint {
        get { CGPoint(x: left, y: top) }
        set { left = newValue.x; top = newValue.y }
    }
    var topRight: CGPoint {
        get { CGPoint(x: right, y: top) }
        set { right = newValue.x; top = newValue.y }
    }
    var bottomLeft: CGPoint {
        get { CGPoint(x: left, y: bottom) }
        set { left = newValue.x; bottom = newValue.y }
    }
    var bottomRight: CGPoint {
        get { CGPoint(x: right, y: bottom) }
        set { right = newValue.x; bottom = newValue.y }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
