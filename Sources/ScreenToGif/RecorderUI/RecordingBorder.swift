import AppKit

/// 录制边框：选区四周 4 条蓝色细条窗口（对标原版 RegionSelection 录制边框）。
/// 不参与捕获（sharingType = .none）、不挡鼠标。
final class RecordingBorder {
    private var windows: [NSWindow] = []
    static let thickness: CGFloat = 2

    func show(region: CaptureRegion) {
        remove()
        let t = Self.thickness
        let r = region.rect
        let strips = [
            NSRect(x: r.minX - t, y: r.maxY, width: r.width + t * 2, height: t),      // 上
            NSRect(x: r.minX - t, y: r.minY - t, width: r.width + t * 2, height: t),  // 下
            NSRect(x: r.minX - t, y: r.minY, width: t, height: r.height),             // 左
            NSRect(x: r.maxX, y: r.minY, width: t, height: r.height)                  // 右
        ]
        for strip in strips {
            let window = NSWindow(
                contentRect: strip, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            window.backgroundColor = NSColor(hex: 0x0066CC)
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.sharingType = .none
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func remove() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}
