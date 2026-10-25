import Foundation

/// GIF89a 容器写入器。
/// 移植自 C# ScreenToGif.Util/Codification/Gif/Encoder/GifFile.cs（Nicke Manarin 的原生编码器）。
///
/// 像素格式：输入一律 RGBA8 —— `[UInt8]`、RGBA 顺序、rect 宽×高×4 字节。
/// C# 原版量化器从 GDI 位图读 BGRA；本移植在量化器基类入口完成通道换序，
/// 容器、量化与 LZW 算法本体不变。
///
/// 结构（与 C# 逐块对应）：
/// - 文件头 "GIF89a" + 逻辑屏幕描述符（首帧时写出）；
/// - NETSCAPE2.0 循环扩展（loopCount > -1 时写出；0 = 无限循环）；
/// - 逐帧：图形控制扩展（延迟/透明/处置法）→ 图像描述符 → 局部/全局颜色表 → LZW 数据；
/// - 收尾：注释扩展 "Made with ScreenToGif" + 0x3B 结束符（对应 C# Dispose）。
///
/// 与 C# 的语义差异（均已在方法处注明）：
/// - 逻辑屏幕宽高由构造参数给定（C# 取首帧 rect，二者在等尺寸录制下一致）；
/// - 延迟统一钳制为 ≥ 2 个 1/100 秒（Constants.minimumGifFrameDelayMs = 20ms）；
///   C# 的 GifFile 本身不钳制（钳制散落在调用方）；
/// - 透明索引不作为入参，由 transparentColor 查调色板得出（C# FindTransparentColorIndex）；
/// - UseGlobalColorTable + Octree 组合下，C# 每帧仍重建调色板（与其全局表语义矛盾），
///   移植版统一采用 MedianCut 的模式：首帧建表，后续帧仅做第二遍映射。
final class GifFileWriter {
    /// 帧矩形（C# Int32Rect 的对应物；默认整幅画布）。
    struct GifRect {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// 单帧描述（静态 write 便捷入口用）。
    struct FrameSpec {
        var pixels: [UInt8]
        var delayMs: Int
        var rect: GifRect?

        init(pixels: [UInt8], delayMs: Int, rect: GifRect? = nil) {
            self.pixels = pixels
            self.delayMs = delayMs
            self.rect = rect
        }
    }

    enum GifWriterError: Error, CustomStringConvertible {
        /// 像素缓冲长度与 rect 尺寸不符。
        case invalidPixelCount(expected: Int, got: Int)
        /// finish 之后继续追加帧。
        case alreadyFinished
        /// 矩形越界（超出逻辑屏幕）。
        case rectOutOfBounds(GifRect)

        var description: String {
            switch self {
            case .invalidPixelCount(let e, let g): return "像素数不符：期望 \(e)，实际 \(g)"
            case .alreadyFinished: return "GIF 已收尾，不能继续追加帧"
            case .rectOutOfBounds(let r): return "帧矩形越界：\(r)"
            }
        }
    }

    // MARK: - 配置（镜像 C# GifFile 公开属性）

    /// 循环次数：-1 不循环（不写 NETSCAPE 块），0 无限循环，>0 为额外重复次数。
    let loopCount: Int

    /// 是否使用全局颜色表（C# 默认 false，即逐帧局部颜色表）。
    var useGlobalColorTable = false

    /// 全透明背景模式（C# UseFullTransparency：非末帧用 Restore Background 处置法）。
    var useFullTransparency = false

    /// 透明色（色度键）。设置后追加到各帧调色板末位；nil 表示无透明。
    var transparentColor: GifColor?

    /// 每帧最大颜色数（2–256，写入时收敛）。
    var maximumColorCount: Int = 256 {
        didSet { maximumColorCount = min(256, max(2, maximumColorCount)) }
    }

    /// 量化器工厂：非全局表模式下每帧调用一次（镜像 C# 按 QuantizationType 逐帧 new）。
    var quantizerFactory: () -> GifQuantizer = { OctreeQuantizer() }

    // MARK: - 状态

    private let width: Int
    private let height: Int
    private var writer = DataWriter()
    private var isFirstFrame = true
    private var indexedPixels: [UInt8] = []
    private var colorTable: [GifColor] = []
    private var colorTableHasTransparency = false
    /// 颜色表规模码（0–7，实际容量 2^(码+1)）。
    private var colorTableSize = 0
    /// 全局表模式下保留的首帧量化器。
    private var globalQuantizer: GifQuantizer?
    private var finished = false

    // MARK: - 生命周期

    init(width: Int, height: Int, loopCount: Int) {
        self.width = width
        self.height = height
        self.loopCount = loopCount
    }

    /// 追加一帧（C# AddFrame）。
    ///
    /// - Parameters:
    ///   - pixels: RGBA8 像素（rect 宽×高×4 字节）。
    ///   - rect: 帧矩形；nil 取整幅画布（脏矩形裁剪由 UnchangedPixelCut 产出）。
    ///   - delayMs: 帧延迟（毫秒），写出时四舍五入到 1/100 秒并钳制 ≥ 20ms。
    ///   - isLastFrame: 全透明模式末帧的处置法切换（C# 同名参数）。
    ///   - quantizer: 本帧量化器；nil 时用 quantizerFactory()。全局表模式下应传入
    ///     首帧用过的同一实例（或留 nil 由写入器保管）。
    func appendFrame(pixels: [UInt8], rect: GifRect? = nil, delayMs: Int = 66,
                     isLastFrame: Bool = false, quantizer: GifQuantizer? = nil) throws {
        guard !finished else { throw GifWriterError.alreadyFinished }

        let frameRect = rect ?? GifRect(x: 0, y: 0, width: width, height: height)
        guard frameRect.x >= 0, frameRect.y >= 0,
              frameRect.x + frameRect.width <= width,
              frameRect.y + frameRect.height <= height,
              frameRect.width > 0, frameRect.height > 0 else {
            throw GifWriterError.rectOutOfBounds(frameRect)
        }
        let expected = frameRect.width * frameRect.height * 4
        guard pixels.count == expected else {
            throw GifWriterError.invalidPixelCount(expected: expected, got: pixels.count)
        }

        readPixels(pixels, rect: frameRect, quantizer: quantizer)

        // 全局表模式下仅首帧需要重算调色板规模。
        if !useGlobalColorTable || isFirstFrame {
            calculateColorTableSize()
        }

        if isFirstFrame {
            writeLogicalScreenDescriptor()

            if useGlobalColorTable {
                writePalette()
            }
            if loopCount > -1 {
                writeApplicationExtension()
            }
        }

        writeGraphicControlExtension(delayMs: delayMs, isLastFrame: isLastFrame)
        writeImageDescriptor(frameRect)

        isFirstFrame = false

        if !useGlobalColorTable {
            writePalette()
        }
        writeImage()
    }

    /// 收尾：注释扩展 + 0x3B（C# Dispose），返回完整 GIF 数据。可重复调用。
    @discardableResult
    func finish() -> Data {
        guard !finished else { return Data(writer.bytes) }
        writeComment("Made with ScreenToGif")
        writer.put(UInt8(0x3B))
        finished = true
        return Data(writer.bytes)
    }

    /// 已写出的数据（未收尾时也可取）。
    var data: Data { Data(writer.bytes) }

    /// 便捷入口：多帧一次写成文件。
    ///
    /// - Parameters:
    ///   - frames: 各帧像素与延迟。
    ///   - progress: 进度回调 (已完成帧数, 总帧数)。
    static func write(frames: [FrameSpec], width: Int, height: Int, loopCount: Int,
                      maximumColorCount: Int = 256, useGlobalColorTable: Bool = false,
                      transparentColor: GifColor? = nil,
                      quantizerFactory: (() -> GifQuantizer)? = nil,
                      to url: URL, progress: ((Int, Int) -> Void)? = nil) throws {
        let gif = GifFileWriter(width: width, height: height, loopCount: loopCount)
        gif.maximumColorCount = maximumColorCount
        gif.useGlobalColorTable = useGlobalColorTable
        gif.transparentColor = transparentColor
        if let quantizerFactory = quantizerFactory {
            gif.quantizerFactory = quantizerFactory
        }

        let last = frames.count - 1
        for (index, frame) in frames.enumerated() {
            try gif.appendFrame(pixels: frame.pixels, rect: frame.rect,
                                delayMs: frame.delayMs, isLastFrame: index == last)
            progress?(index + 1, frames.count)
        }

        try gif.finish().write(to: url)
    }

    // MARK: - 量化调度（C# ReadPixels 的 Octree/MedianCut 分支）

    private func readPixels(_ pixels: [UInt8], rect: GifRect, quantizer: GifQuantizer?) {
        // C#：非首帧 / 全局表 / 全透明模式才向量化器声明透明色（首帧透明位留给正式内容）。
        let wantsTransparent = !isFirstFrame || useGlobalColorTable || useFullTransparency

        if useGlobalColorTable {
            if globalQuantizer == nil {
                let created = quantizer ?? quantizerFactory()
                configure(created, wantsTransparent: wantsTransparent)
                globalQuantizer = created
                indexedPixels = created.quantize(pixels, width: rect.width, height: rect.height, secondPassOnly: false)
                colorTable = created.colorTable
            } else {
                // 后续帧：沿用首帧调色板，仅做第二遍映射。
                let q = quantizer ?? globalQuantizer!
                q.transparentColor = wantsTransparent ? transparentColor : nil
                indexedPixels = q.quantize(pixels, width: rect.width, height: rect.height, secondPassOnly: true)
            }
        } else {
            let q = quantizer ?? quantizerFactory()
            configure(q, wantsTransparent: wantsTransparent)
            indexedPixels = q.quantize(pixels, width: rect.width, height: rect.height, secondPassOnly: false)
            colorTable = q.colorTable
        }

        colorTableHasTransparency = transparentColor.map { colorTable.contains($0) } ?? false
    }

    private func configure(_ quantizer: GifQuantizer, wantsTransparent: Bool) {
        quantizer.maxColors = maximumColorCount
        quantizer.transparentColor = wantsTransparent ? transparentColor : nil
    }

    // MARK: - 容器各块（C# 对应私有方法）

    /// 逻辑屏幕描述符（C# WriteLogicalScreenDescriptor）。
    private func writeLogicalScreenDescriptor() {
        // 文件头，6 字节。
        writer.put(ascii: "GIF89a")

        // 逻辑屏幕宽高，各 2 字节小端。
        writer.put(UInt16(width))
        writer.put(UInt16(height))

        // packed 字段：全局表标志 | 颜色分辨率(规模码<<4) | 排序标志(固定 1) | 全局表容量(规模码)。
        // C# 的 BitArray 双重反转恰好抵消，等价于下面的直接拼装。
        var packed: UInt8 = 0x08
        if useGlobalColorTable {
            packed |= 0x80
        }
        let gctSizeCode = useGlobalColorTable ? colorTableSize : 0
        packed |= UInt8((colorTableSize << 4) | gctSizeCode)
        writer.put(packed)

        // 背景色索引（全透明模式指向透明色，否则 0）与像素宽高比（1:1）。
        writer.put(useFullTransparency ? UInt8(findTransparentColorIndex()) : UInt8(0))
        writer.put(UInt8(0))
    }

    /// 颜色表（C# WritePalette）：逐条 RGB，不足 2^(规模码+1) 的部分补零。
    private func writePalette() {
        for color in colorTable {
            writer.put(color.r)
            writer.put(color.g)
            writer.put(color.b)
        }
        let emptySpace = (maximumColorCountOfTable - colorTable.count) * 3
        if emptySpace > 0 {
            writer.put([UInt8](repeating: 0, count: emptySpace))
        }
    }

    /// NETSCAPE2.0 循环扩展（C# WriteApplicationExtension）。
    private func writeApplicationExtension() {
        writer.put(UInt8(0x21)) // 扩展引导
        writer.put(UInt8(0xFF)) // 扩展标签
        writer.put(UInt8(0x0B)) // 应用块长度：11 字节
        writer.put(ascii: "NETSCAPE2.0")
        writer.put(UInt8(0x03)) // 子块长度
        writer.put(UInt8(0x01)) // 循环子块 ID
        writer.put(UInt16(loopCount)) // 循环次数，2 字节小端
        writer.put(UInt8(0x00)) // 终止符
    }

    /// 图形控制扩展（C# WriteGraphicControlExtension）。
    private func writeGraphicControlExtension(delayMs: Int, isLastFrame: Bool) {
        writer.put(UInt8(0x21))
        writer.put(UInt8(0xF9))
        writer.put(UInt8(0x04)) // 块大小

        // 处置法（占 bit 2–4）：
        // 0 未定义 / 1 保留画面(Leave) / 2 恢复背景 —— 与 C# 的分支一致。
        let disposal: UInt8
        if useFullTransparency {
            // 全透明：末帧 Leave，其余帧 Restore Background。
            disposal = isLastFrame ? 1 : 2
        } else {
            // 未变化像素涂抹模式：首帧 Leave，后续帧未定义（配合透明色跳过重绘）。
            disposal = isFirstFrame ? 1 : 0
        }

        var packed: UInt8 = disposal << 2
        // 透明色标志：非首帧（或全透明模式）且调色板确实含透明色。
        if (!isFirstFrame || useFullTransparency) && colorTableHasTransparency {
            packed |= 0x01
        }
        writer.put(packed)

        // 延迟：ms → 1/100s，四舍五入取整（C# Math.Round AwayFromZero 对正数即 +5 再整除），
        // 并钳制到 ≥ 2（20ms，见 Constants.minimumGifFrameDelayMs）。
        let minimumTicks = max(1, Constants.minimumGifFrameDelayMs / 10)
        let ticks = max(minimumTicks, (delayMs + 5) / 10)
        writer.put(UInt16(ticks))

        writer.put(UInt8(findTransparentColorIndex())) // 透明索引
        writer.put(UInt8(0)) // 终止符
    }

    /// 图像描述符（C# WriteImageDescriptor），无隔行扫描。
    private func writeImageDescriptor(_ rect: GifRect) {
        writer.put(UInt8(0x2C)) // 分隔符
        writer.put(UInt16(rect.x))
        writer.put(UInt16(rect.y))
        writer.put(UInt16(rect.width))
        writer.put(UInt16(rect.height))

        if useGlobalColorTable {
            writer.put(UInt8(0)) // 无局部表，packed 全零
            return
        }

        // packed：局部表标志 + 排序标志(固定 1) + 局部表容量(规模码)。
        writer.put(UInt8(0x80 | 0x20 | colorTableSize))
    }

    /// LZW 图像数据（C# WriteImage）。
    /// C# 固定使用 8 位初始码宽的经典编码器（其新版 LzwEncoder 在 256 色时有损坏问题）。
    /// 移植修正：初始码宽须匹配当前色表位深（≤ 表容量位数的规模码+1）——
    /// 固定 8 在少色表（如 2 色全局表）下违反 GIF 规范，CoreGraphics 等解码器
    /// 会拒解该帧并回退为合成上一帧，表现为帧内容错乱/静态。
    private func writeImage() {
        let codeSize = max(2, colorTableSize + 1)
        let encoder = LegacyLzwEncoder(width: width, height: height,
                                       pixels: indexedPixels, colorDepth: codeSize)
        encoder.encode(to: &writer)
    }

    /// 注释扩展（C# WriteComment）。
    private func writeComment(_ comment: String) {
        writer.put(UInt8(0x21))
        writer.put(UInt8(0xFE))
        let bytes = Array(comment.utf8)
        writer.put(UInt8(min(255, bytes.count)))
        writer.put(bytes)
        writer.put(UInt8(0))
    }

    // MARK: - 辅助（C# 对应 Helper methods）

    /// 调色板规模码：使 2^(码+1) ≥ 颜色数的最小值（C# CalculateColorTableSize 的
    /// (int)Math.Log(count - 1, 2) 的整数实现，避免浮点误差）。
    private func calculateColorTableSize() {
        let count = colorTable.count
        if count > 1 {
            let v = UInt32(count - 1)
            colorTableSize = Int(31 - v.leadingZeroBitCount) // floor(log2(v))
        } else {
            colorTableSize = 0
        }
    }

    /// 当前规模码下的颜色表容量：2^(码+1)。
    private var maximumColorCountOfTable: Int {
        1 << (colorTableSize + 1)
    }

    /// 透明索引（C# FindTransparentColorIndex）：首帧（非全透明模式）或调色板
    /// 不含透明色时取 0，否则查表。
    private func findTransparentColorIndex() -> Int {
        if (isFirstFrame && !useFullTransparency) || !colorTableHasTransparency {
            return 0
        }
        guard let transparent = transparentColor,
              let index = colorTable.firstIndex(of: transparent) else { return 0 }
        return index
    }
}
