import Foundation

/// 八叉树颜色量化器（两遍）。
/// 移植自 C# ScreenToGif.Util/Codification/Gif/Encoder/Quantization/OctreeQuantizer.cs。
///
/// 与 C# 的差异（均不改变正常路径的结果）：
/// - 像素输入为 RGBA8，基类入口完成通道换序（C# 读 BGRA）；
/// - C# 在颜色不在树中时抛 "Not expected!" 异常；移植版回退到调色板最近色
///   （抖动扰动色与全局表后续帧的新颜色都会查树落空，这里选择优雅降级而非崩溃）；
/// - C# 在无可归约节点时 Reduce() 会空引用崩溃（如 8 种颜色归约到 4）；
///   移植版此时直接保留多于目标的叶子数，调色板仍按 2 的幂填充为合法 GIF。
final class OctreeQuantizer: GifQuantizerBase {
    private let octree: Octree

    /// - Parameter maxColorBits: 颜色有效位数（1–8），默认 8。
    init(maxColorBits: Int = 8, maxColors: Int = 256, transparentColor: GifColor? = nil) {
        precondition(maxColorBits >= 1 && maxColorBits <= 8, "maxColorBits 应在 1 到 8 之间")
        octree = Octree(maxColorBits: maxColorBits)
        super.init(maxColors: maxColors, transparentColor: transparentColor)
    }

    override func initialQuantizePixel(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard a != 0 else { return }
        octree.addColor(GifColor(r, g, b))
    }

    override func buildPalette() -> [GifColor] {
        var palette = octree.palletize(maxColorsWithTransparency)

        // 透明色固定追加到调色板末位（C#：一个画面中不会用到的颜色）。
        if let transparent = transparentColor {
            palette.append(transparent)
        }
        return palette
    }

    override func quantizePixel(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let index = octree.paletteIndex(of: GifColor(r, g, b))
        // 抖动扰动色 / 全局表后续帧的新颜色会落入归约剪枝后的空分支（返回 -1），
        // 此时回退调色板最近色，避免错误映射到索引 0 造成杂色斑点。
        if index >= 0 { return UInt8(index) }
        return nearestPaletteIndex(r: r, g: g, b: b)
    }
}

/// 各层取位掩码（C# Octree.Mask；节点与树共用，放文件作用域）。
private let octreeMask = [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]

/// 八叉树本体（C# OctreeQuantizer.Octree）。
private final class Octree {
    /// 根节点。IUO 是因为构造根节点需要把 self 传入（先于 let 完成初始化）。
    var root: OctreeNode!
    /// 各层可归约节点链（C# ReducibleNodes，9 个槽位）。
    var reducibleNodes: [OctreeNode?]
    /// 颜色有效位数（1–8）。
    let maxColorBits: Int
    /// 上一次量化到的节点（C# _previousNode）。
    var previousNode: OctreeNode?
    /// 上一次加入的颜色（C# _previousColor；仅 RGB 参与，等效于 C# 含 alpha 的比较，
    /// 因为 A==0 的像素在量化器入口即被跳过）。
    var previousColor: GifColor?
    /// 叶子数（C# Leaves）；节点构造/归约时跨类修改，故 fileprivate(set)。
    fileprivate(set) var leafCount = 0

    init(maxColorBits: Int) {
        self.maxColorBits = maxColorBits
        reducibleNodes = Array(repeating: nil, count: 9)
        root = OctreeNode(level: 0, colorBits: maxColorBits, tree: self)
    }

    /// 加入一个颜色（C# AddColor）：与上个颜色相同时只更新缓存节点。
    func addColor(_ pixel: GifColor) {
        if previousColor == pixel {
            if let node = previousNode {
                node.increment(pixel)
            } else {
                previousColor = pixel
                root.addColor(pixel, colorBits: maxColorBits, level: 0, tree: self)
            }
        } else {
            previousColor = pixel
            root.addColor(pixel, colorBits: maxColorBits, level: 0, tree: self)
        }
    }

    /// 归约最深层最近加入的可归约节点（C# Reduce）。
    private func reduce() {
        var index = maxColorBits - 1
        while index > 0 && reducibleNodes[index] == nil {
            index -= 1
        }

        // C# 在此处取 ReducibleNodes[index] 后直接解引用，无可归约节点时抛空引用；
        // 移植版选择直接返回（见类头注释）。
        guard let node = reducibleNodes[index] else { return }
        reducibleNodes[index] = node.nextReducible
        leafCount -= node.reduce()
        previousNode = nil
    }

    func trackPrevious(_ node: OctreeNode) {
        previousNode = node
    }

    /// 归约到 colorCount 个颜色并收集调色板（C# Palletize）。
    func palletize(_ colorCount: Int) -> [GifColor] {
        while leafCount > colorCount {
            reduce()
        }

        var palette: [GifColor] = []
        palette.reserveCapacity(leafCount)
        var paletteIndex = 0
        root.constructPalette(into: &palette, paletteIndex: &paletteIndex)
        return palette
    }

    /// 查颜色的调色板索引；不在树中时返回 -1（C# 由节点抛 "Not expected!"）。
    func paletteIndex(of pixel: GifColor) -> Int {
        root.paletteIndex(of: pixel, level: 0)
    }
}

/// 八叉树节点（C# OctreeQuantizer.Octree.OctreeNode）。
private final class OctreeNode {
    private var isLeaf: Bool
    private var red = 0
    private var green = 0
    private var blue = 0
    private var pixelCount = 0
    /// 本节点在调色板中的索引（叶子有效）。
    private(set) var paletteIndex = 0
    /// 同层下一个可归约节点。
    var nextReducible: OctreeNode?
    /// 8 个子节点；叶子为 nil（C# Children）。
    var children: [OctreeNode?]?

    init(level: Int, colorBits: Int, tree: Octree) {
        isLeaf = level == colorBits

        if isLeaf {
            tree.leafCount += 1
            nextReducible = nil
            children = nil
        } else {
            // 挂到本层的可归约链头部。
            nextReducible = tree.reducibleNodes[level]
            tree.reducibleNodes[level] = self
            children = Array(repeating: nil, count: 8)
        }
    }

    /// 计算颜色在第 level 层的子节点下标（C# AddColor 内联公式）。
    ///
    /// 注意移位量复现：C#/CLR 对 int 移位量取模 32 —— 第 7 层的 (shift-2) = -2
    /// 实际按 30 处理（红绿位被移出、只剩蓝的最低位参与），Swift 的 `>>` 对负数会陷阱，
    /// 因此显式 `& 31` 复现 CLR 语义。
    private func childIndex(of pixel: GifColor, level: Int) -> Int {
        let shift = 7 - level
        return ((Int(pixel.r) & octreeMask[level]) >> ((shift - 2) & 31))
            | ((Int(pixel.g) & octreeMask[level]) >> ((shift - 1) & 31))
            | ((Int(pixel.b) & octreeMask[level]) >> (shift & 31))
    }

    /// 递归加入颜色（C# OctreeNode.AddColor）。
    func addColor(_ pixel: GifColor, colorBits: Int, level: Int, tree: Octree) {
        if isLeaf {
            increment(pixel)
            tree.trackPrevious(self)
        } else {
            let index = childIndex(of: pixel, level: level)
            if children![index] == nil {
                children![index] = OctreeNode(level: level + 1, colorBits: colorBits, tree: tree)
            }
            children![index]!.addColor(pixel, colorBits: colorBits, level: level + 1, tree: tree)
        }
    }

    /// 归约：吸收全部子节点并变成本叶（C# OctreeNode.Reduce），返回应从叶子计数中扣除的数量。
    func reduce() -> Int {
        red = 0
        green = 0
        blue = 0
        var childrenCount = 0

        for index in 0..<8 {
            guard let child = children![index] else { continue }
            red += child.red
            green += child.green
            blue += child.blue
            pixelCount += child.pixelCount
            childrenCount += 1
            children![index] = nil
        }

        isLeaf = true
        return childrenCount - 1
    }

    /// 遍历树构建调色板（C# ConstructPalette）。
    func constructPalette(into palette: inout [GifColor], paletteIndex: inout Int) {
        if isLeaf {
            self.paletteIndex = paletteIndex
            paletteIndex += 1
            let count = max(1, pixelCount)
            palette.append(GifColor(UInt8(red / count), UInt8(green / count), UInt8(blue / count)))
        } else {
            for index in 0..<8 {
                if let child = children![index] {
                    child.constructPalette(into: &palette, paletteIndex: &paletteIndex)
                }
            }
        }
    }

    /// 查颜色的调色板索引（C# GetPaletteIndex）；走不到叶子时返回 -1。
    func paletteIndex(of pixel: GifColor, level: Int) -> Int {
        if isLeaf {
            return paletteIndex
        }

        let index = childIndex(of: pixel, level: level)
        if let child = children![index] {
            return child.paletteIndex(of: pixel, level: level + 1)
        }
        return -1
    }

    /// 像素计数与颜色累加（C# Increment）。
    func increment(_ pixel: GifColor) {
        pixelCount += 1
        red += Int(pixel.r)
        green += Int(pixel.g)
        blue += Int(pixel.b)
    }
}
