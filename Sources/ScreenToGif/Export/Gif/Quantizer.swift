import Foundation

/// 8 位 RGB 颜色（GIF 调色板条目）。
/// 对应 C# System.Windows.Media.Color 的 RGB 分量（alpha 不进入 GIF 调色板）。
struct GifColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// GIF 颜色量化器公共协议（对应 C# Quantizer 抽象类的公开面）。
///
/// 像素格式约定：输入一律为 RGBA8 —— `[UInt8]`、RGBA 顺序、宽×高×4 字节。
/// C# 原实现从 GDI/WPF 位图读 BGRA（Quantizer.Depth = 4，按 B,G,R,A 解读）；
/// 本移植在基类边界处完成通道换序，八叉树/中位切分算法本体不变。
protocol GifQuantizer: AnyObject {
    /// 调色板颜色上限（2–256；越界值会被收敛到该区间）。
    var maxColors: Int { get set }

    /// 指定透明色（构建调色板时追加到末位；语义同 C# 的 alpha=0 版本）。nil 表示无。
    var transparentColor: GifColor? { get set }

    /// 最近一次构建出的调色板。
    var colorTable: [GifColor] { get }

    /// 两遍量化总入口。`secondPassOnly` 为 true 时跳过分析、沿用现有调色板
    /// （全局颜色表模式下后续帧复用）。`width/height` 有效（>0）且开启抖动时，
    /// 第二遍采用 Floyd-Steinberg 误差扩散（渐变区域观感大幅提升）。
    func quantize(_ pixels: [UInt8], width: Int, height: Int, secondPassOnly: Bool) -> [UInt8]

    /// 重建并返回调色板（C# GetPalette）。
    func palette() -> [GifColor]

    /// 查询单个像素（RGB）映射到的调色板索引；查不到时返回 nil。
    func paletteIndex(r: UInt8, g: UInt8, b: UInt8) -> UInt8?
}

extension GifQuantizer {
    /// quantize 的便捷重载（无几何信息 → 不抖动，行为与旧签名一致）。
    func quantize(_ pixels: [UInt8]) -> [UInt8] {
        quantize(pixels, width: 0, height: 0, secondPassOnly: false)
    }

    func quantize(_ pixels: [UInt8], secondPassOnly: Bool) -> [UInt8] {
        quantize(pixels, width: 0, height: 0, secondPassOnly: secondPassOnly)
    }
}

/// 量化器基类：实现两遍流程骨架与像素→索引缓存（对应 C# Quantizer 抽象类本体）。
///
/// 与 C# 的差异：
/// - C# 越界的 MaxColors 抛 ArgumentOutOfRangeException；移植版收敛到 [2, 256]；
/// - C# 的 _singlePass 单遍模式（Neural 等量化器用）未移植，两种已移植量化器均为两遍。
class GifQuantizerBase: GifQuantizer {
    /// 调色板颜色上限，写入时收敛到 [2, 256]。
    var maxColors: Int {
        didSet { maxColors = min(256, max(2, maxColors)) }
    }

    /// Floyd-Steinberg 误差扩散抖动（仅当 quantize 传入有效 width/height 时生效）。
    /// 渐变（天空、阴影）用邻近像素噪点模拟中间色，消除量化色带。
    var dither = true

    /// 指定透明色（构建调色板时追加到末位）。
    var transparentColor: GifColor?

    /// 除去透明色后可用的颜色上限（C# MaxColorsWithTransparency）。
    var maxColorsWithTransparency: Int { transparentColor != nil ? maxColors - 1 : maxColors }

    /// 最近一次构建的调色板。
    private(set) var colorTable: [GifColor] = []

    /// 像素→索引缓存（C# _colorMap；键对应 C# 的 BitConverter.ToInt32([255,R,G,B]) 小端值）。
    private var colorMap: [UInt32: UInt8] = [:]

    init(maxColors: Int = 256, transparentColor: GifColor? = nil) {
        self.maxColors = min(256, max(2, maxColors))
        self.transparentColor = transparentColor
    }

    // MARK: - GifQuantizer

    func quantize(_ pixels: [UInt8], width: Int, height: Int, secondPassOnly: Bool) -> [UInt8] {
        if !secondPassOnly {
            firstPass(pixels)
            colorTable = buildPalette()
        }
        if dither, width > 0, height > 0, width * height * 4 == pixels.count {
            return secondPassDithered(pixels, width: width, height: height)
        }
        return secondPass(pixels)
    }

    func palette() -> [GifColor] {
        colorTable = buildPalette()
        return colorTable
    }

    func paletteIndex(r: UInt8, g: UInt8, b: UInt8) -> UInt8? {
        quantizePixel(r: r, g: g, b: b)
    }

    // MARK: - 落空回退

    /// 调色板线性最近色（平方欧氏距离）。
    ///
    /// `quantizePixel` 查结构落空时的回退：FS 抖动的扰动色（原值+扩散误差）不参与
    /// 第一遍统计，八叉树归约剪枝后查询会落入空分支、MedianCut 的扰动色可能落在
    /// 所有立方体包围盒之外——两者原会被钳到索引 0（调色板首色），表现为大片
    /// 平滑色区散布同一杂色斑点。回退到真最近色消除该失真。
    /// 仅落空像素走此路径（O(256) 线性扫），正常像素仍走各自的快速查找结构。
    func nearestPaletteIndex(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        var bestIndex: UInt8 = 0
        var bestDistance = Int.max
        for (index, color) in colorTable.enumerated() {
            let dr = Int(color.r) - Int(r)
            let dg = Int(color.g) - Int(g)
            let db = Int(color.b) - Int(b)
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = UInt8(index)
            }
        }
        return bestIndex
    }

    /// 透明像素的输出索引。与 GifFileWriter 声明的透明索引（firstIndex(of:)）
    /// 保持同一槽位，防止画面自然含量化出的洋红时中部槽与末位槽错位。
    var transparentOutputIndex: UInt8 {
        if let transparent = transparentColor,
           let index = colorTable.firstIndex(of: transparent) {
            return UInt8(index)
        }
        return UInt8(max(0, colorTable.count - 1))
    }

    // MARK: - 模板方法（子类覆写）

    /// 第一遍：逐像素统计（C# FirstPass → InitialQuantizePixel）。
    func firstPass(_ pixels: [UInt8]) {
        var i = 0
        while i + 3 < pixels.count {
            initialQuantizePixel(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
            i += 4
        }
    }

    /// 第一遍的单像素回调。默认空实现（C# virtual）。
    func initialQuantizePixel(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {}

    /// 构建调色板（C# BuildPalette 抽象方法）。默认空。
    func buildPalette() -> [GifColor] { [] }

    /// 第二遍的单像素映射（C# QuantizePixel 抽象方法）。默认 0。
    func quantizePixel(r: UInt8, g: UInt8, b: UInt8) -> UInt8 { 0 }

    // MARK: - 第二遍（Floyd-Steinberg 误差扩散）

    /// 逐像素最近色映射后，将量化误差按 7/16、3/16、5/16、1/16 扩散到
    /// 右、左下、下、右下邻域（标准 FS 核）。透明像素输出透明索引且不扩散。
    private func secondPassDithered(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        var buf = pixels
        var output = [UInt8]()
        output.reserveCapacity(width * height)
        let transparentIndex = transparentOutputIndex
        let clamp255: (Int) -> UInt8 = { UInt8(min(255, max(0, $0))) }

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if buf[i + 3] == 0 {
                    output.append(transparentIndex)
                    continue
                }
                let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
                let index = Int(quantizePixel(r: clamp255(r), g: clamp255(g), b: clamp255(b)))
                output.append(UInt8(max(0, min(255, index))))
                guard index >= 0, index < colorTable.count else { continue }
                let chosen = colorTable[index]
                // 误差（基于量化前的调整值）
                let er = r - Int(chosen.r)
                let eg = g - Int(chosen.g)
                let eb = b - Int(chosen.b)
                // FS 扩散目标：右(7/16)、左下(3/16)、下(5/16)、右下(1/16)
                func spread(_ dx: Int, _ dy: Int, _ factor: Double) {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny < height else { return }
                    let j = (ny * width + nx) * 4
                    guard buf[j + 3] != 0 else { return }   // 透明像素不受污染
                    buf[j] = clamp255(Int(buf[j]) + Int(Double(er) * factor))
                    buf[j + 1] = clamp255(Int(buf[j + 1]) + Int(Double(eg) * factor))
                    buf[j + 2] = clamp255(Int(buf[j + 2]) + Int(Double(eb) * factor))
                }
                spread(1, 0, 7.0 / 16)
                spread(-1, 1, 3.0 / 16)
                spread(0, 1, 5.0 / 16)
                spread(1, 1, 1.0 / 16)
            }
        }
        return output
    }

    // MARK: - 第二遍

    /// 第二遍：把每个像素映射为调色板索引（C# SecondPass）。
    /// 完全透明的像素（A == 0）固定映射到调色板末位索引。
    func secondPass(_ pixels: [UInt8]) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(pixels.count / 4)
        var i = 0
        while i + 3 < pixels.count {
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2], a = pixels[i + 3]

            // 透明像素翻译到透明槽位（C# 原注释：末位）。
            if a == 0 {
                output.append(transparentOutputIndex)
                i += 4
                continue
            }

            let hash = 0xFF as UInt32 | (UInt32(r) << 8) | (UInt32(g) << 16) | (UInt32(b) << 24)
            if let cached = colorMap[hash] {
                output.append(cached)
            } else {
                let position = quantizePixel(r: r, g: g, b: b)
                output.append(position)
                colorMap[hash] = position
            }
            i += 4
        }
        return output
    }
}
