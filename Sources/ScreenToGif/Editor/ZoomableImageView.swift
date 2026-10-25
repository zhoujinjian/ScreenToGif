import AppKit
import SwiftUI

/// 预览视图（AppKit 岛）：像素对齐绘制 + 滚轮缩放（光标为锚点）+ 平移 + 透明棋盘格背景。
/// 对标原版 ZoomBox + ImageViewer。
final class ZoomableImageView: NSView {
    // MARK: 状态
    private(set) var zoom: CGFloat = 1
    private(set) var panOffset = CGPoint.zero
    private(set) var image: CGImage?

    var imageDidChange: ((CGImage?) -> Void)?

    private let transparencyColors: [NSColor] = [
        NSColor(hex: 0xFFFFFF), NSColor(hex: 0xE8E8E8)
    ]
    private var checkerPattern: NSColor {
        NSColor(patternImage: makeCheckerImage())
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - 图像

    /// 用户手动缩放/平移后停止自动跟随窗口适配（原版行为）；工具栏"适配"恢复跟随。
    var userInteracted = false

    func setImage(_ newImage: CGImage?) {
        let wasEmpty = image == nil
        image = newImage
        needsDisplay = true
        // 首帧到达且视口已布局 → 自动适配（铺满预览区）
        if wasEmpty, newImage != nil, !userInteracted, bounds.width > 10 {
            zoomToFit()
        }
        imageDidChange?(newImage)
    }

    override func layout() {
        super.layout()
        // 用户未手动缩放前，窗口/布局尺寸变化时持续重新适配
        // （首次布局 bounds 可能为 0 或偏小，一次性标记会锁死错误缩放）
        if !userInteracted, image != nil, bounds.width > 10 {
            zoomToFit()
        }
    }

    // MARK: - 缩放

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        userInteracted = true
        let clamped = min(max(newZoom, 0.05), 32)
        let anchorPoint = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        // 以锚点为不动点调整 pan
        let imageAnchor = screenToImage(anchorPoint)
        zoom = clamped
        panOffset = imageToScreen(imageAnchor) .applying(.init(translationX: -anchorPoint.x, y: -anchorPoint.y))
        panOffset.x = anchorPoint.x - (imageAnchor.x * zoom)
        panOffset.y = anchorPoint.y - (imageAnchor.y * zoom)
        needsDisplay = true
    }

    func zoomToFit() {
        guard let image else { return }
        let inset: CGFloat = 12
        let sx = (bounds.width - inset * 2) / CGFloat(image.width)
        let sy = (bounds.height - inset * 2) / CGFloat(image.height)
        // 下限保护：bounds 尚未布局（0）时 sx/sy 为负，禁止产生负缩放
        zoom = min(max(min(sx, sy), 0.05), 32)
        centerImage()
    }

    func zoomToActual() {
        zoom = 1
        centerImage()
    }

    private func centerImage() {
        guard let image else { return }
        let w = CGFloat(image.width) * zoom
        let h = CGFloat(image.height) * zoom
        panOffset = CGPoint(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2)
        needsDisplay = true
    }

    private func screenToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - panOffset.x) / zoom, y: (p.y - panOffset.y) / zoom)
    }

    private func imageToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + panOffset.x, y: p.y * zoom + panOffset.y)
    }

    // MARK: - 交互

    override func scrollWheel(with event: NSEvent) {
        userInteracted = true
        // ⌘/⌃ + 滚轮：缩放（macOS 惯例；原版 Ctrl+滚轮）。
        // 普通滚轮/触控板双指：平移——之前普通滚轮也缩放，导致用户想滚动浏览时
        // 图像朝光标方向不断放大生长，体验混乱。
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if event.deltaY != 0 || event.deltaX != 0 {
                let delta = event.deltaY != 0 ? event.deltaY : event.deltaX
                let location = convert(event.locationInWindow, from: nil)
                let step: CGFloat = delta < 0 ? -1 : 1
                setZoom(zoom * pow(1.1, -step), anchor: location)
            }
            return
        }
        // 平移
        panOffset.x += event.scrollingDeltaX
        panOffset.y += event.scrollingDeltaY
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // 空格/中键拖拽平移简化为：直接拖拽平移
        window?.makeFirstResponder(self)
        dragging = true
        dragStart = convert(event.locationInWindow, from: nil)
        panStart = panOffset
    }

    private var dragging = false
    private var dragStart = CGPoint.zero
    private var panStart = CGPoint.zero

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        userInteracted = true
        let p = convert(event.locationInWindow, from: nil)
        panOffset = CGPoint(x: panStart.x + p.x - dragStart.x, y: panStart.y + p.y - dragStart.y)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 透明棋盘格背景
        checkerPattern.setFill()
        bounds.fill()

        guard let image else {
            NSColor(hex: 0x262626).setFill()
            bounds.fill()
            return
        }

        let rect = CGRect(origin: panOffset, size: CGSize(width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom))
        // 像素对齐（缩放 = 整数倍时）
        var drawRect = rect
        if zoom >= 1 {
            drawRect.origin.x = rect.origin.x.rounded()
            drawRect.origin.y = rect.origin.y.rounded()
        }

        NSGraphicsContext.current?.imageInterpolation = zoom < 1 ? .high : .none
        let context = NSGraphicsContext.current?.cgContext
        // flipped 视图：垂直翻转绘制；先裁剪到自身 bounds，
        // 否则放大/平移时图像会溢出预览区盖住时间轴等其它 UI
        context?.saveGState()
        context?.clip(to: CGRect(origin: .zero, size: bounds.size))
        context?.translateBy(x: 0, y: drawRect.maxY + drawRect.minY)
        context?.scaleBy(x: 1, y: -1)
        context?.draw(image, in: CGRect(
            x: drawRect.minX, y: drawRect.minY,
            width: drawRect.width, height: drawRect.height
        ))
        context?.restoreGState()
    }

    private func makeCheckerImage() -> NSImage {
        let cell: CGFloat = 8
        let img = NSImage(size: NSSize(width: cell * 2, height: cell * 2))
        img.lockFocus()
        transparencyColors[0].setFill()
        NSRect(x: 0, y: 0, width: cell * 2, height: cell * 2).fill()
        transparencyColors[1].setFill()
        NSRect(x: 0, y: 0, width: cell, height: cell).fill()
        NSRect(x: cell, y: cell, width: cell, height: cell).fill()
        img.unlockFocus()
        return img
    }
}

/// SwiftUI 包装。
struct ZoomableImagePane: NSViewRepresentable {
    let image: CGImage?
    let zoomCommand: ZoomCommand?

    final class Coordinator {
        var lastCommandId = UUID()
    }

    /// 缩放指令（外部工具栏触发）。
    struct ZoomCommand: Equatable {
        let id = UUID()
        let kind: Kind
        enum Kind { case fit, actual, in_, out }
    }

    func makeNSView(context: Context) -> ZoomableImageView {
        // 首次适配由 ZoomableImageView 在 layout/首帧 setImage 时自动执行
        // （此处立即 fit 会因 bounds 尚为 0 得到负缩放，导致预览只显示局部）
        ZoomableImageView()
    }

    func updateNSView(_ view: ZoomableImageView, context: Context) {
        if view.image !== image {
            view.setImage(image)
        }
        if let cmd = zoomCommand, cmd.id != context.coordinator.lastCommandId {
            context.coordinator.lastCommandId = cmd.id
            switch cmd.kind {
            case .fit:
                view.userInteracted = false   // 恢复自动跟随
                view.zoomToFit()
            case .actual:
                view.userInteracted = true
                view.zoomToActual()
            case .in_:
                view.setZoom(view.zoom * 1.25)
            case .out:
                view.setZoom(view.zoom / 1.25)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
