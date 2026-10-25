import AppKit
import CoreGraphics

/// 显示器信息 + AppKit(左下原点) ↔ CoreGraphics/SCK(左上原点) 坐标转换。
struct DisplayInfo {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// AppKit 全局 frame（左下原点）。
    let appKitFrame: CGRect
    /// CG 全局 frame（左上原点，CGDisplayBounds）。
    let cgFrame: CGRect
    let scale: CGFloat

    /// 遍历所有显示器。
    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return DisplayInfo(
                screen: screen,
                displayID: id,
                appKitFrame: screen.frame,
                cgFrame: CGDisplayBounds(id),
                scale: screen.backingScaleFactor
            )
        }
    }

    /// AppKit 全局点 → 所在显示器。
    static func containing(_ point: CGPoint) -> DisplayInfo? {
        all().first { $0.appKitFrame.contains(point) }
    }

    /// 按 displayID 查找。
    static func by(id: CGDirectDisplayID) -> DisplayInfo? {
        all().first { $0.displayID == id }
    }
}

/// 坐标系转换工具。
/// - AppKit 全局坐标：原点在主显示器左下，y 向上。
/// - CG 全局坐标：原点在主显示器左上，y 向下（CGDisplayBounds 使用的空间）。
/// - SCK sourceRect 坐标（2026-10-24 实录纠正 + spike 自动校验）：
///   **显示器本地坐标，左上原点，y 向下，pt 单位**。
///   即 y 需用目标显示器高度翻转：ySck = H - (appKitLocalMinY + height)。
///   （此前误记为"AppKit 左下原点"导致录屏区域镜像偏移到选区上方。）
enum ScreenMath {
    /// AppKit 全局 y → CG 全局 y（主显示器高度翻转）。
    static func cgGlobalY(fromAppKitY y: CGFloat) -> CGFloat {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return mainHeight - y
    }

    /// CG 全局 y → AppKit 全局 y。
    static func appKitGlobalY(fromCGY y: CGFloat) -> CGFloat {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return mainHeight - y
    }

    /// AppKit 全局矩形 → 指定显示器的 SCK sourceRect（本地坐标，左上原点，y 向下）。
    static func sckLocalRect(fromAppKitGlobal rect: CGRect, display: DisplayInfo) -> CGRect {
        sckLocalRect(fromAppKitGlobal: rect, displayFrame: display.appKitFrame)
    }

    /// 纯坐标版本（无 NSScreen 依赖，可单测）。
    static func sckLocalRect(fromAppKitGlobal rect: CGRect, displayFrame: CGRect) -> CGRect {
        let localMinY = rect.minY - displayFrame.minY               // 左下原点本地 y
        let yFromTop = displayFrame.height - (localMinY + rect.height)
        return CGRect(
            x: rect.minX - displayFrame.minX,
            y: yFromTop,
            width: rect.width,
            height: rect.height
        )
    }

    /// SCK sourceRect → AppKit 全局矩形（逆向）。
    static func appKitGlobalRect(fromSckLocal local: CGRect, display: DisplayInfo) -> CGRect {
        appKitGlobalRect(fromSckLocal: local, displayFrame: display.appKitFrame)
    }

    static func appKitGlobalRect(fromSckLocal local: CGRect, displayFrame: CGRect) -> CGRect {
        let yFromBottom = displayFrame.minY + displayFrame.height - (local.minY + local.height)
        return CGRect(
            x: local.minX + displayFrame.minX,
            y: yFromBottom,
            width: local.width,
            height: local.height
        )
    }
}
