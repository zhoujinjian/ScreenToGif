import Foundation
import CoreGraphics

/// RGBA8 颜色（含 alpha）。涂抹用透明色需要四个通道（C# 直接写 WPF Color 的四个分量）。
struct RgbaColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// 未变化像素检测与涂抹。
/// 移植自 C# ScreenToGif/ImageUtil/ImageMethods.cs 的 PaintTransparentAndCut 逐帧核心。
///
/// C# 语义要点（忠实保留）：
/// - 比较只看 RGB 三个通道，忽略 alpha；
/// - 与前一帧相同的像素被替换为指定透明色（四个通道全写），供 LZW 压缩掉重复区域；
/// - C# 在帧序列层（从尾到头两两比较）还有"完全相同的帧并入前一帧延迟并丢弃"的调度，
///   该决策不在本类型职责内 —— 调用方依据 `changed == false`（或包围盒为 nil）自行处理。
enum UnchangedPixelCut {
    /// 把 current 中与 previous 相同的像素替换为 transparent。
    ///
    /// - Returns: (两帧是否存在差异, 涂抹后的当前帧像素)。差异判定同样只看 RGB。
    static func paintUnchanged(previous: [UInt8], current: [UInt8], width: Int, height: Int,
                               transparent: RgbaColor) -> (changed: Bool, pixels: [UInt8]) {
        let expected = width * height * 4
        precondition(previous.count == expected && current.count == expected,
                     "像素缓冲应为宽×高×4 字节")

        var output = current
        var changed = false

        var i = 0
        while i < output.count {
            if previous[i] == output[i], previous[i + 1] == output[i + 1], previous[i + 2] == output[i + 2] {
                output[i] = transparent.r
                output[i + 1] = transparent.g
                output[i + 2] = transparent.b
                output[i + 3] = transparent.a
            } else {
                changed = true
            }
            i += 4
        }
        return (changed, output)
    }

    /// 两帧差异的最小包围盒（C# 的 firstX/lastX/firstY/lastY 及其 +1 收敛，
    /// 在存在差异时恰好等价于覆盖全部差异像素的最小矩形）。
    ///
    /// - Returns: nil 表示两帧完全相同（RGB 口径）—— 对应 C# 走"延迟合并"分支的情况。
    static func boundingBoxOfDifference(previous: [UInt8], current: [UInt8],
                                        width: Int, height: Int) -> CGRect? {
        let expected = width * height * 4
        precondition(previous.count == expected && current.count == expected,
                     "像素缓冲应为宽×高×4 字节")

        var minX = width, minY = height
        var maxX = -1, maxY = -1

        var pixel = 0
        while pixel < expected {
            if previous[pixel] != current[pixel]
                || previous[pixel + 1] != current[pixel + 1]
                || previous[pixel + 2] != current[pixel + 2] {
                let index = pixel / 4
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
            pixel += 4
        }

        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
