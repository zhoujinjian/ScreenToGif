import Foundation
import AppKit

/// 录制选区（AppKit 全局坐标，pt 单位）+ 所在显示器。
/// 注：CGRect 在旧 SDK（macOS 14/Xcode 15）无 Hashable conformance，
/// 仅按值传递使用，不声明 Hashable 以兼容新旧工具链。
struct CaptureRegion: Codable {
    /// 选区矩形（全局 AppKit 坐标，左下原点）。
    var rect: CGRect
    /// 所在显示器（CGDirectDisplayID）。
    var displayID: CGDirectDisplayID

    var size: CGSize { rect.size }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}
