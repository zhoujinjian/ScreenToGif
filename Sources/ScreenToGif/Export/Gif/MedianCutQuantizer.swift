import Foundation

/// 中位切分颜色量化器（两遍）。
/// 移植自 C# ScreenToGif.Util/Codification/Gif/Encoder/Quantization/MedianCutQuantizer.cs
/// （上游注明的原始出处：ehotsk8/Picturea_ImageProcessing 的 MedianCutQuantizer）。
///
/// 忠实保留的上游行为：
/// - `SplitAtMedian` 的三个分支（按 R/G/B 轴）排序时全部按 R 比较 —— 上游笔误，
///   实际分裂轴恒为 R。移植保持一致以保证同输入同输出；
/// - 分裂到 maxColors 个立方体后，空立方体（颜色已在更早的立方体中分尽）以黑色
///   进入调色板，因此调色板条目数恒等于 maxColors（透明色再追加 1 个到末位）；
/// - 排序对 R 相同的元素顺序由具体实现决定（C# List.Sort 为不稳定内省排序），
///   本移植在固定输入下输出确定，但与 C# 在 R 重复时可能逐字节不同（结果仍合法）。
final class MedianCutQuantizer: GifQuantizerBase {
    /// 第一遍收集的全部不透明像素颜色（含重复；C# Colors）。
    private var colors: [GifColor] = []
    /// 分裂出的立方体（C# _cubes）。
    private var cubes: [MedianCutCube] = []

    override func initialQuantizePixel(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard a != 0 else { return }
        colors.append(GifColor(r, g, b))
    }

    override func buildPalette() -> [GifColor] {
        // 先整体装进一个立方体，再分裂到目标数量（C# BuildPalette）。
        cubes = [MedianCutCube(colors: colors)]
        splitCubes(&cubes, count: maxColorsWithTransparency)

        var palette: [GifColor] = []
        palette.reserveCapacity(maxColors)
        for index in 0..<maxColorsWithTransparency {
            palette.append(cubes[index].color)
            cubes[index].setPaletteIndex(index)
        }

        // 透明色固定追加到调色板末位。
        if let transparent = transparentColor {
            palette.append(transparent)
        }
        return palette
    }

    override func quantizePixel(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        // 返回第一个包含该颜色的立方体（C# QuantizePixel）。
        for cube in cubes where cube.isColorIn(r: r, g: g, b: b) {
            return UInt8(cube.paletteIndex)
        }
        // 抖动扰动色可能落在所有立方体包围盒之外（C# 原版返回 palette[0]），
        // 回退调色板最近色，避免错误映射到索引 0 造成杂色斑点。
        return nearestPaletteIndex(r: r, g: g, b: b)
    }

    /// 从最后一个立方体向前逐个分裂，直到达到 count 个（C# SplitCubes）。
    private func splitCubes(_ cubes: inout [MedianCutCube], count: Int) {
        var indexToSplit = cubes.count - 1

        while cubes.count < count {
            let cubeToSplit = cubes[indexToSplit]

            // 找最长的一边作为分裂轴。
            if cubeToSplit.redSize >= cubeToSplit.greenSize && cubeToSplit.redSize >= cubeToSplit.blueSize {
                let (cube1, cube2) = cubeToSplit.splitAtMedian(0)
                replaceCubes(&cubes, at: indexToSplit, with: cube1, cube2)
            } else if cubeToSplit.greenSize >= cubeToSplit.blueSize {
                let (cube1, cube2) = cubeToSplit.splitAtMedian(1)
                replaceCubes(&cubes, at: indexToSplit, with: cube1, cube2)
            } else {
                let (cube1, cube2) = cubeToSplit.splitAtMedian(2)
                replaceCubes(&cubes, at: indexToSplit, with: cube1, cube2)
            }

            indexToSplit -= 1
            if indexToSplit < 0 {
                indexToSplit = cubes.count - 1
            }
        }
    }

    /// C# 的 RemoveAt + 两次 Insert(index)：得到 [.., cube1, cube2, ..]。
    private func replaceCubes(_ cubes: inout [MedianCutCube], at index: Int,
                              with cube1: MedianCutCube, _ cube2: MedianCutCube) {
        cubes.remove(at: index)
        cubes.insert(cube2, at: index)
        cubes.insert(cube1, at: index)
    }
}

/// 中位切分立方体（C# MedianCutQuantizer.MedianCutCube）。
private final class MedianCutCube {
    private var redLow: UInt8 = 255
    private var redHigh: UInt8 = 0
    private var greenLow: UInt8 = 255
    private var greenHigh: UInt8 = 0
    private var blueLow: UInt8 = 255
    private var blueHigh: UInt8 = 0

    private var cachedColor: GifColor?
    private let colorList: [GifColor]

    private(set) var paletteIndex = 0

    /// 红边长度（C# byte 相减提升为 int，空立方体为负数）。
    var redSize: Int { Int(redHigh) - Int(redLow) }
    var greenSize: Int { Int(greenHigh) - Int(greenLow) }
    var blueSize: Int { Int(blueHigh) - Int(blueLow) }

    /// 立方体的平均色（C# Color 属性；空立方体为黑色）。
    var color: GifColor {
        if let cached = cachedColor {
            return cached
        }

        var red = 0, green = 0, blue = 0
        for color in colorList {
            red += Int(color.r)
            green += Int(color.g)
            blue += Int(color.b)
        }

        let count = colorList.count
        if count != 0 {
            red /= count
            green /= count
            blue /= count
        }

        let result = GifColor(UInt8(red), UInt8(green), UInt8(blue))
        cachedColor = result
        return result
    }

    init(colors: [GifColor]) {
        colorList = colors
        shrink()
    }

    /// 收缩到颜色的包围盒（C# Shrink）。
    private func shrink() {
        redLow = 255; greenLow = 255; blueLow = 255
        redHigh = 0; greenHigh = 0; blueHigh = 0

        for color in colorList {
            if color.r < redLow { redLow = color.r }
            if color.r > redHigh { redHigh = color.r }
            if color.g < greenLow { greenLow = color.g }
            if color.g > greenHigh { greenHigh = color.g }
            if color.b < blueLow { blueLow = color.b }
            if color.b > blueHigh { blueHigh = color.b }
        }
    }

    /// 按指定分量排序后从中位数一分为二（C# SplitAtMedian）。
    /// 上游三个 case 均按 R 比较（笔误），此处保持一致。
    func splitAtMedian(_ componentIndex: UInt8) -> (MedianCutCube, MedianCutCube) {
        let sorted = colorList.sorted { $0.r < $1.r }
        let medianIndex = sorted.count >> 1

        let cube1 = MedianCutCube(colors: Array(sorted[0..<medianIndex]))
        let cube2 = MedianCutCube(colors: Array(sorted[medianIndex...]))
        return (cube1, cube2)
    }

    func setPaletteIndex(_ newPaletteIndex: Int) {
        paletteIndex = newPaletteIndex
    }

    /// 颜色是否落在立方体包围盒内（C# IsColorIn；空立方体恒为 false）。
    func isColorIn(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        (r >= redLow && r <= redHigh) && (g >= greenLow && g <= greenHigh) && (b >= blueLow && b <= blueHigh)
    }
}
