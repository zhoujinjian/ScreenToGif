import Foundation
import CoreGraphics
import ImageIO

/// GIF 编码栈自测：容器字节结构、ImageIO 解码回读、量化器、LZW、未变化像素涂抹。
/// 黄金样例（1×1 白点）的期望字节为按规范手算的完整序列。
enum GifTests {
    static func register() {
        byteStructureTests()
        decodeRoundtripTests()
        quantizerTests()
        ditherFallbackTests()
        lzwTests()
        unchangedPixelTests()
        goldenTest()
    }

    // MARK: - 字节结构

    private static func byteStructureTests() {
        SelfTest.register("GIF 单帧字节结构（局部颜色表）") {
            // 3×2：顶行红 ×3，底行蓝 ×3。
            let red = (UInt8(255), UInt8(0), UInt8(0))
            let blue = (UInt8(0), UInt8(0), UInt8(255))
            let pixels = rgbaPixels(width: 3, height: 2) { x, y in y == 0 ? red : blue }

            let gif = GifFileWriter(width: 3, height: 2, loopCount: 3)
            try gif.appendFrame(pixels: pixels, delayMs: 66, isLastFrame: true)
            let data = Array(gif.finish())

            // 文件头 + 逻辑屏幕描述符。
            SelfTest.expectEqual(String(bytes: data[0..<6], encoding: .ascii) ?? "", "GIF89a", "文件头")
            SelfTest.expectEqual(data[6], UInt8(3), "宽度低字节")
            SelfTest.expectEqual(data[7], UInt8(0), "宽度高字节")
            SelfTest.expectEqual(data[8], UInt8(2), "高度低字节")
            SelfTest.expectEqual(data[9], UInt8(0), "高度高字节")
            // packed：无全局表(0x80 位清零) | 分辨率 0 | 排序标志 0x08 | 全局表容量 0。
            SelfTest.expectEqual(data[10], UInt8(0x08), "LSD packed")
            SelfTest.expectEqual(data[11], UInt8(0), "背景色索引")
            SelfTest.expectEqual(data[12], UInt8(0), "宽高比")

            // NETSCAPE2.0 循环扩展（loopCount = 3）。
            SelfTest.expectEqual(data[13], UInt8(0x21), "扩展引导")
            SelfTest.expectEqual(data[14], UInt8(0xFF), "应用扩展标签")
            SelfTest.expectEqual(data[15], UInt8(0x0B), "应用块长度")
            SelfTest.expectEqual(String(bytes: data[16..<27], encoding: .ascii) ?? "", "NETSCAPE2.0", "循环扩展标识")
            SelfTest.expectEqual(data[27], UInt8(0x03), "子块长度")
            SelfTest.expectEqual(data[28], UInt8(0x01), "循环子块 ID")
            SelfTest.expectEqual(data[29], UInt8(3), "循环次数低字节")
            SelfTest.expectEqual(data[30], UInt8(0), "循环次数高字节")
            SelfTest.expectEqual(data[31], UInt8(0), "循环扩展终止符")

            // 图形控制扩展：处置法 1(Leave)=0x04，延迟 66ms → 7 个 1/100s。
            SelfTest.expectEqual(data[32], UInt8(0x21), "GCE 引导")
            SelfTest.expectEqual(data[33], UInt8(0xF9), "GCE 标签")
            SelfTest.expectEqual(data[34], UInt8(0x04), "GCE 块大小")
            SelfTest.expectEqual(data[35], UInt8(0x04), "GCE packed（处置法 1，无透明）")
            SelfTest.expectEqual(data[36], UInt8(7), "延迟低字节（66ms → 7）")
            SelfTest.expectEqual(data[37], UInt8(0), "延迟高字节")
            SelfTest.expectEqual(data[38], UInt8(0), "透明索引")
            SelfTest.expectEqual(data[39], UInt8(0), "GCE 终止符")

            // 图像描述符 + 局部颜色表（八叉树按子节点序输出：蓝在前、红在后）。
            SelfTest.expectEqual(data[40], UInt8(0x2C), "图像分隔符")
            SelfTest.expectEqual(Array(data[41..<49]), [0, 0, 0, 0, 3, 0, 2, 0], "帧矩形")
            SelfTest.expectEqual(data[49], UInt8(0xA0), "描述符 packed（局部表 + 排序 + 容量码 0）")
            SelfTest.expectEqual(Array(data[50..<56]), [0, 0, 255, 255, 0, 0], "局部颜色表（蓝、红）")

            // LZW 数据：初始码宽 = 色表位深（2 色表 → 2；规范要求 ≤ 表容量位数），子块链完整。
            SelfTest.expectEqual(data[56], UInt8(2), "LZW 初始码宽")
            let blocks = concatSubBlocks(data, start: 57)
            SelfTest.expect(blocks != nil, "子块链应以 0 终止")
            SelfTest.expect(blocks!.payload.count > 0, "应有 LZW 数据")
            let after = blocks!.endIndex
            // 注释扩展 + 结束符。
            SelfTest.expectEqual(data[after], UInt8(0x21), "注释扩展引导")
            SelfTest.expectEqual(data[after + 1], UInt8(0xFE), "注释扩展标签")
            SelfTest.expectEqual(data[after + 2], UInt8(0x15), "注释长度（21 字节）")
            let comment = String(bytes: data[(after + 3)..<(after + 24)], encoding: .ascii) ?? ""
            SelfTest.expectEqual(comment, "Made with ScreenToGif", "注释内容")
            SelfTest.expectEqual(data[data.count - 1], UInt8(0x3B), "文件结束符")
        }

        SelfTest.register("GIF 全局颜色表字节结构") {
            let red = (UInt8(255), UInt8(0), UInt8(0))
            let blue = (UInt8(0), UInt8(0), UInt8(255))
            let pixels = rgbaPixels(width: 3, height: 2) { x, y in y == 0 ? red : blue }

            let gif = GifFileWriter(width: 3, height: 2, loopCount: 3)
            gif.useGlobalColorTable = true
            try gif.appendFrame(pixels: pixels, delayMs: 66, isLastFrame: true)
            let data = Array(gif.finish())

            // packed：全局表标志 0x80 | 排序 0x08 | 容量码 0（2 色）。
            SelfTest.expectEqual(data[10], UInt8(0x88), "LSD packed（全局表）")
            // 全局颜色表紧跟 LSD：蓝、红，2 项共 6 字节。
            SelfTest.expectEqual(Array(data[13..<19]), [0, 0, 255, 255, 0, 0], "全局颜色表")
            // 之后是 NETSCAPE 块。
            SelfTest.expectEqual(data[19], UInt8(0x21), "NETSCAPE 起始")
            SelfTest.expectEqual(data[20], UInt8(0xFF), "应用扩展标签")

            // 图像描述符应声明"无局部表"（packed = 0）。
            let idStart = 19 + 19 + 8 // NETSCAPE(19) + GCE(8)
            SelfTest.expectEqual(data[idStart], UInt8(0x2C), "图像分隔符")
            SelfTest.expectEqual(data[idStart + 9], UInt8(0), "描述符 packed（无局部表）")

            // 不循环（loopCount = -1）时不写 NETSCAPE，LSD 后直接 GCE。
            let once = GifFileWriter(width: 3, height: 2, loopCount: -1)
            try once.appendFrame(pixels: pixels, delayMs: 66)
            let onceData = Array(once.finish())
            SelfTest.expectEqual(onceData[13], UInt8(0x21), "无循环时应直接进入扩展")
            SelfTest.expectEqual(onceData[14], UInt8(0xF9), "应为 GCE 而非 NETSCAPE")
        }
    }

    // MARK: - ImageIO 解码回读

    private static func decodeRoundtripTests() {
        SelfTest.register("GIF 双帧解码回读（延迟/循环/像素）") {
            let red = (UInt8(255), UInt8(0), UInt8(0))
            let blue = (UInt8(0), UInt8(0), UInt8(255))
            let frameA = rgbaPixels(width: 3, height: 2) { x, y in y == 0 ? red : blue }
            let frameB = rgbaPixels(width: 3, height: 2) { x, y in y == 0 ? blue : red }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("screentogif-selftest-\(UUID().uuidString).gif")
            defer { try? FileManager.default.removeItem(at: url) }

            var lastProgress = (0, 0)
            try GifFileWriter.write(frames: [.init(pixels: frameA, delayMs: 66),
                                             .init(pixels: frameB, delayMs: 100)],
                                    width: 3, height: 2, loopCount: 0, to: url) { done, total in
                lastProgress = (done, total)
            }
            SelfTest.expectEqual(lastProgress.0, 2, "进度：完成帧数")
            SelfTest.expectEqual(lastProgress.1, 2, "进度：总帧数")

            let data = try Data(contentsOf: url)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                SelfTest.expect(false, "CGImageSource 创建失败"); return
            }

            SelfTest.expectEqual(CGImageSourceGetCount(source), 2, "帧数")

            // 各帧延迟（未钳制的原始值，单位秒）。
            let delays = (0..<2).map { frameDelay(at: $0, of: source) ?? -1 }
            SelfTest.expect(abs(delays[0] - 0.07) < 0.001, "帧 0 延迟 0.07s（66ms → 7 tick），实际 \(delays[0])")
            SelfTest.expect(abs(delays[1] - 0.10) < 0.001, "帧 1 延迟 0.10s，实际 \(delays[1])")

            // 容器级循环次数：0 = 无限。
            let loop = containerLoopCount(of: source)
            SelfTest.expectEqual(loop ?? -999, 0, "循环次数（NETSCAPE 0）")

            // 像素回读：每帧 3 红 3 蓝（不依赖行序）。
            for index in 0..<2 {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    SelfTest.expect(false, "帧 \(index) 解码失败"); continue
                }
                let buffer = renderedRGBA(image)
                SelfTest.expectEqual(countColor(buffer, 255, 0, 0), 3, "帧 \(index) 红色像素数")
                SelfTest.expectEqual(countColor(buffer, 0, 0, 255), 3, "帧 \(index) 蓝色像素数")
            }
        }

        SelfTest.register("GIF 延迟舍入与最小延迟钳制") {
            // 64ms → 6 tick（四舍五入向下）；5ms → 钳制为 2 tick（20ms）；25ms → 2.5 舍入为 3 tick。
            for (delayMs, expectedSeconds) in [(64, 0.06), (5, 0.02), (25, 0.03)] {
                let pixels = rgbaPixels(width: 1, height: 1) { _, _ in (0, 0, 0) }
                let gif = GifFileWriter(width: 1, height: 1, loopCount: -1)
                try gif.appendFrame(pixels: pixels, delayMs: delayMs)
                let data = gif.finish() as CFData
                guard let source = CGImageSourceCreateWithData(data, nil),
                      let delay = frameDelay(at: 0, of: source) else {
                    SelfTest.expect(false, "\(delayMs)ms 用例解码失败"); continue
                }
                SelfTest.expect(abs(delay - expectedSeconds) < 0.001,
                                "\(delayMs)ms 应为 \(expectedSeconds)s，实际 \(delay)")
            }
        }

        SelfTest.register("GIF 经典 LZW 全链路像素级还原（8 色）") {
            // 每行相同的 8 色序列（与行序无关，便于比对）。
            let palette: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255),
                (255, 255, 0), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            ]
            let pixels = rgbaPixels(width: 8, height: 8) { x, _ in palette[x] }

            let gif = GifFileWriter(width: 8, height: 8, loopCount: 0)
            try gif.appendFrame(pixels: pixels, delayMs: 20)
            let data = gif.finish() as CFData

            guard let source = CGImageSourceCreateWithData(data, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                SelfTest.expect(false, "解码失败"); return
            }
            let buffer = renderedRGBA(image)

            var mismatched = 0
            for y in 0..<8 {
                for x in 0..<8 {
                    let offset = (y * 8 + x) * 4
                    let expected = palette[x]
                    if abs(Int(buffer[offset]) - Int(expected.0)) > 2
                        || abs(Int(buffer[offset + 1]) - Int(expected.1)) > 2
                        || abs(Int(buffer[offset + 2]) - Int(expected.2)) > 2 {
                        mismatched += 1
                    }
                }
            }
            SelfTest.expectEqual(mismatched, 0, "像素不匹配数（8 色应精确还原）")
        }
    }

    // MARK: - 量化器

    private static func quantizerTests() {
        let distinctColors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (0, 0, 0),
        ]

        // 300 个互不相同的颜色（散布在 RGB 空间）。
        var scattered: [(UInt8, UInt8, UInt8)] = []
        for i in 0..<300 {
            scattered.append((UInt8(i & 0xFF), UInt8((i >> 3) & 0xFF), UInt8((i * 37) & 0xFF)))
        }

        SelfTest.register("Octree 量化：少色精确 + 多色收敛 + 确定性") {
            let pixels = rgbaPixels(width: 5, height: 1) { x, _ in distinctColors[x] }

            let quantizer = OctreeQuantizer()
            let indexed = quantizer.quantize(pixels)
            let palette = quantizer.colorTable

            SelfTest.expectEqual(palette.count, 5, "5 色输入应精确建表")
            // 八叉树按子节点序遍历：顶层位序为 black(0)、blue(1)、green(2)、red(4)、white(7)，
            // 故调色板顺序 [黑, 蓝, 绿, 红, 白]，输入 [红,绿,蓝,白,黑] 映射为 [3,2,1,4,0]。
            SelfTest.expectEqual(palette, [GifColor(0, 0, 0), GifColor(0, 0, 255), GifColor(0, 255, 0),
                                           GifColor(255, 0, 0), GifColor(255, 255, 255)], "调色板遍历序")
            SelfTest.expectEqual(indexed, [3, 2, 1, 4, 0].map { UInt8($0) }, "索引图")

            // 调色板内的颜色应精确映射回自身。
            for color in distinctColors {
                let idx = quantizer.paletteIndex(r: color.0, g: color.1, b: color.2)
                SelfTest.expect(idx != nil, "调色板内颜色应有索引")
                if let idx = idx {
                    SelfTest.expectEqual(palette[Int(idx)], GifColor(color.0, color.1, color.2), "映射应精确")
                }
            }

            // 确定性：同输入两次结果一致。
            let again = OctreeQuantizer()
            _ = again.quantize(pixels)
            SelfTest.expectEqual(again.colorTable, palette, "输出应确定")

            // 300 色 → ≤ 256。
            let wide = rgbaPixels(width: 300, height: 1) { x, _ in scattered[x] }
            let wideQuantizer = OctreeQuantizer()
            let wideIndexed = wideQuantizer.quantize(wide)
            SelfTest.expect(wideQuantizer.colorTable.count <= 256, "300 色应收敛到 ≤ 256")
            SelfTest.expect(wideIndexed.allSatisfy { Int($0) < wideQuantizer.colorTable.count }, "索引应落在调色板内")

            // GCT 容量按 2 的幂填充：5 色 → 容量码 2（8 项，24 字节）。
            let gif = GifFileWriter(width: 5, height: 1, loopCount: 0)
            gif.useGlobalColorTable = true
            try gif.appendFrame(pixels: pixels, delayMs: 20)
            let data = Array(gif.finish())
            SelfTest.expectEqual(data[10] & 0x07, UInt8(2), "GCT 容量码（2^3 = 8 项）")
            SelfTest.expectEqual(data[13 + 24], UInt8(0x21), "GCT 应填充为 24 字节")
        }

        SelfTest.register("MedianCut 量化：少色精确 + 多色收敛 + 确定性") {
            let pixels = rgbaPixels(width: 5, height: 1) { x, _ in distinctColors[x] }

            let quantizer = MedianCutQuantizer()
            quantizer.maxColors = 8
            let indexed = quantizer.quantize(pixels)
            let palette = quantizer.colorTable

            // 上游行为：立方体数恒等于 maxColors（空立方体以黑色占位）。
            SelfTest.expectEqual(palette.count, 8, "调色板应填充到 maxColors")

            // 单颜色立方体应精确还原（空立方体不含任何颜色，不会抢占映射）。
            for color in distinctColors {
                let idx = quantizer.paletteIndex(r: color.0, g: color.1, b: color.2)
                SelfTest.expect(idx != nil, "调色板内颜色应有索引")
                if let idx = idx {
                    SelfTest.expectEqual(palette[Int(idx)], GifColor(color.0, color.1, color.2), "映射应精确")
                }
            }
            SelfTest.expect(indexed.allSatisfy { Int($0) < palette.count }, "索引应落在调色板内")

            // 确定性。
            let again = MedianCutQuantizer()
            again.maxColors = 8
            _ = again.quantize(pixels)
            SelfTest.expectEqual(again.colorTable, palette, "输出应确定")

            // 300 色 → 256 项。
            let wide = rgbaPixels(width: 300, height: 1) { x, _ in scattered[x] }
            let wideQuantizer = MedianCutQuantizer()
            let wideIndexed = wideQuantizer.quantize(wide)
            SelfTest.expectEqual(wideQuantizer.colorTable.count, 256, "300 色应收敛到 256 项")
            SelfTest.expect(wideIndexed.allSatisfy { Int($0) < 256 }, "索引应落在调色板内")
        }
    }

    // MARK: - 查树落空回退

    /// 平方欧氏距离（调色板最近色判定用）。
    private static func squaredDistance(_ a: GifColor, r: UInt8, g: UInt8, b: UInt8) -> Int {
        let dr = Int(a.r) - Int(r), dg = Int(a.g) - Int(g), db = Int(a.b) - Int(b)
        return dr * dr + dg * dg + db * db
    }

    private static func ditherFallbackTests() {
        let distinctColors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (0, 0, 0),
        ]
        // 回归背景：FS 抖动的扰动色（原值+扩散误差）不参与第一遍建树，八叉树归约
        // 剪枝后查询会落入空分支（paletteIndex 返回 -1），被钳成索引 0；MedianCut
        // 的扰动色也可能落在所有立方体包围盒之外（返回 0）。表现为大片平滑色区
        // 散布同一杂色斑点。正确行为：回退到调色板最近色。
        SelfTest.register("量化落空回退最近色（Octree 树中不存在的颜色）") {
            let pixels = rgbaPixels(width: 5, height: 1) { x, _ in distinctColors[x] }
            let quantizer = OctreeQuantizer()
            _ = quantizer.quantize(pixels)
            let palette = quantizer.colorTable
            // 索引 0 是黑（childIndex 位序），确保测试查询色的最近色不是索引 0，
            // 修复前的错误行为（钳 0）才能被抓住。
            SelfTest.expectEqual(palette[0], GifColor(0, 0, 0), "前提：调色板 0 号应为黑")

            // (250,5,5)：树中只有 5 条纯色路径，红色分支在第 5 层分岔（r 位不全 1）
            // → 确定落空；最近色是红（索引 3），黑距离远大于红。
            let query = (UInt8(250), UInt8(5), UInt8(5))
            let best = palette.map { squaredDistance($0, r: query.0, g: query.1, b: query.2) }.min()!
            let idx = quantizer.paletteIndex(r: query.0, g: query.1, b: query.2)!
            let got = squaredDistance(palette[Int(idx)], r: query.0, g: query.1, b: query.2)
            SelfTest.expectEqual(got, best,
                "落空色应回退最近色（距离 \(got)，最近 \(best)；修复前钳索引 0 映到黑距离 \(squaredDistance(palette[0], r: query.0, g: query.1, b: query.2))）")
        }

        SelfTest.register("量化落空回退最近色（MedianCut 立方体外）") {
            let pixels = rgbaPixels(width: 5, height: 1) { x, _ in distinctColors[x] }
            let quantizer = MedianCutQuantizer()
            quantizer.maxColors = 8
            _ = quantizer.quantize(pixels)
            let palette = quantizer.colorTable

            // 纯色立方体退化为点，(128,128,128) 必在所有包围盒之外。
            let query = (UInt8(128), UInt8(128), UInt8(128))
            let best = palette.map { squaredDistance($0, r: query.0, g: query.1, b: query.2) }.min()!
            let idx = quantizer.paletteIndex(r: query.0, g: query.1, b: query.2)!
            let got = squaredDistance(palette[Int(idx)], r: query.0, g: query.1, b: query.2)
            SelfTest.expectEqual(got, best, "盒外色应回退最近色（距离 \(got)，最近 \(best)）")
        }

        SelfTest.register("渐变图抖动量化无远距离错映（端到端，Octree）") {
            // 256×64 三通道渐变（≈16K 色）→ 256 色量化 + FS 抖动。
            // 落空错映（钳索引 0 = 黑）时，亮色区大量像素映射色与原色距离 > 90；
            // 正常抖动的扰动幅度远小于此。
            // 仅约束 Octree（ExportManager 默认路径）：MedianCut 的"落盒即映射到
            // 盒平均色"语义（忠实保留 C# 上游行为）在 256 色下盒大、映射距离天然
            // 偏大，是算法质量而非落空 bug，由上面的盒外回退单测覆盖。
            let width = 256, height = 64
            let pixels = rgbaPixels(width: width, height: height) { x, y in
                (UInt8(x), UInt8(y * 4), UInt8((x + y * 2) & 0xFF))
            }

            let quantizer = OctreeQuantizer()
            let indexed = quantizer.quantize(pixels, width: width, height: height, secondPassOnly: false)
            let palette = quantizer.colorTable
            var farCount = 0
            for pixelIndex in 0..<(width * height) {
                let offset = pixelIndex * 4
                let color = palette[Int(indexed[pixelIndex])]
                let distance = squaredDistance(color, r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2])
                if distance > 90 * 90 { farCount += 1 }
            }
            SelfTest.expect(farCount < width * height / 1000,
                            "Octree 远距离错映像素 \(farCount)（修复前 7233；应 < \(width * height / 1000)）")
        }
    }

    // MARK: - LZW

    private static func lzwTests() {
        SelfTest.register("新版 LZW 编码器 roundtrip（含码表重置）") {
            // 确定性伪随机序列：8000 点 × 16 色，足以触发 4093 上限的清除码重置。
            var seed: UInt64 = 20261024
            var indices: [UInt8] = []
            indices.reserveCapacity(8000)
            for _ in 0..<8000 {
                seed = (seed &* 6364136223846793005) &+ 1442695040888963407
                indices.append(UInt8((seed >> 33) % 16))
            }

            var writer = DataWriter()
            LzwEncoder(indexedPixels: indices, colorDepth: 4).encode(to: &writer)
            let bytes = writer.bytes

            SelfTest.expectEqual(bytes.first, UInt8(4), "初始码宽")
            let blocks = concatSubBlocks(bytes, start: 1)
            SelfTest.expect(blocks != nil, "子块链应以 0 终止")
            let decoded = lzwDecode(minCodeSize: 4, blocks: blocks!.payload)
            if let mismatchIndex = decoded.enumerated().first(where: { $0.element != indices[$0.offset] })?.offset {
                SelfTest.expect(false, "解码结果应与输入一致（8000 点），第 \(mismatchIndex) 点：期望 \(indices[mismatchIndex])，实际 \(decoded[mismatchIndex])")
            } else {
                SelfTest.expectEqual(decoded.count, indices.count, "解码长度")
            }

            // 小样例：4 色。
            var smallWriter = DataWriter()
            let small: [UInt8] = [0, 0, 1, 1, 2, 2, 2, 3, 0, 3]
            LzwEncoder(indexedPixels: small, colorDepth: 2).encode(to: &smallWriter)
            let smallBlocks = concatSubBlocks(smallWriter.bytes, start: 1)
            SelfTest.expect(smallBlocks != nil, "小子例子块链")
            SelfTest.expectEqual(lzwDecode(minCodeSize: 2, blocks: smallBlocks!.payload), small, "小样例 roundtrip")
        }
    }

    // MARK: - 未变化像素

    private static func unchangedPixelTests() {
        SelfTest.register("未变化像素涂抹 + 差异包围盒") {
            let width = 4, height = 4
            let previous = rgbaPixels(width: width, height: height) { x, y in
                (UInt8(x * 60), UInt8(y * 60), UInt8((x + y) * 30))
            }
            // 只改 (1,1) 与 (3,2) 两个像素。
            var current = previous
            let writePixel: (Int, Int, (UInt8, UInt8, UInt8)) -> Void = { x, y, c in
                let offset = (y * width + x) * 4
                current[offset] = c.0; current[offset + 1] = c.1; current[offset + 2] = c.2
            }
            writePixel(1, 1, (255, 255, 255))
            writePixel(3, 2, (10, 200, 10))

            let transparent = RgbaColor(255, 0, 255, 255)
            let (changed, painted) = UnchangedPixelCut.paintUnchanged(
                previous: previous, current: current, width: width, height: height, transparent: transparent)

            SelfTest.expect(changed, "两帧存在差异")
            // 未变化位置 (0,0) 与 (2,3) 应被涂抹为透明色。
            let transparentCount = countExactColor(painted, 255, 0, 255, 255)
            SelfTest.expectEqual(transparentCount, width * height - 2, "恰有 14 个像素被涂抹")
            // 变化位置保留当前帧颜色。
            let offset11 = (1 * width + 1) * 4
            SelfTest.expectEqual(Array(painted[offset11..<offset11 + 4]), [255, 255, 255, 255], "(1,1) 保留新颜色")
            let offset32 = (2 * width + 3) * 4
            SelfTest.expectEqual(Array(painted[offset32..<offset32 + 4]), [10, 200, 10, 255], "(3,2) 保留新颜色")

            // 包围盒：x ∈ [1,3]，y ∈ [1,2]。
            let box = UnchangedPixelCut.boundingBoxOfDifference(
                previous: previous, current: current, width: width, height: height)
            SelfTest.expect(box != nil, "应有包围盒")
            if let box = box {
                SelfTest.expectEqual(box, CGRect(x: 1, y: 1, width: 3, height: 2), "差异包围盒")
            }

            // 完全相同的两帧：changed = false，包围盒为 nil。
            let (sameChanged, samePainted) = UnchangedPixelCut.paintUnchanged(
                previous: previous, current: previous, width: width, height: height, transparent: transparent)
            SelfTest.expect(!sameChanged, "相同帧应报告无变化")
            SelfTest.expectEqual(countExactColor(samePainted, 255, 0, 255, 255), width * height, "相同帧全部被涂抹")
            SelfTest.expect(UnchangedPixelCut.boundingBoxOfDifference(
                previous: previous, current: previous, width: width, height: height) == nil, "相同帧包围盒为 nil")
        }

        // ExportManager 的真实编码配置（全局色表 + 透明色洋红 + 未变化像素 a=0 涂抹）。
        // 回归背景：曾因 ExportManager 未设置 transparentColor、且涂抹用不透明洋红，
        // 导致后续帧未变化区域被量化为最近实色（黑）—— GIF 除首帧外大面积黑帧。
        // 注：CoreGraphics 解码 GIF 帧会自动合成（透明透出上一帧、输出无 alpha），
        // 因此透明接线用字节级断言（GCE 透明标志 + 透明索引），合成语义用像素断言。
        SelfTest.register("GIF 未变化像素透明索引（ExportManager 等价配置）") {
            let width = 4, height = 4
            let red = (UInt8(255), UInt8(0), UInt8(0))
            let blue = (UInt8(0), UInt8(0), UInt8(255))
            // 首帧同时含红蓝：全局表覆盖两种颜色，第二帧的变化像素可精确量化。
            let frameA = rgbaPixels(width: width, height: height) { x, _ in x < 2 ? red : blue }
            var frameB = frameA
            let changedOffset = (1 * width + 0) * 4   // (0,1) 红变蓝
            frameB[changedOffset] = blue.0
            frameB[changedOffset + 1] = blue.1
            frameB[changedOffset + 2] = blue.2

            let writer = GifFileWriter(width: width, height: height, loopCount: 0)
            writer.maximumColorCount = 256
            writer.useGlobalColorTable = true
            writer.transparentColor = GifColor(255, 0, 255)
            writer.quantizerFactory = { OctreeQuantizer() }

            try writer.appendFrame(pixels: frameA, delayMs: 66)
            let painted = UnchangedPixelCut.paintUnchanged(
                previous: frameA, current: frameB, width: width, height: height,
                transparent: RgbaColor(255, 0, 255, 0))
            SelfTest.expect(painted.changed, "应检测到差异")
            try writer.appendFrame(pixels: painted.pixels, delayMs: 66)
            let data = Array(writer.finish())

            // ── 字节级：第二个 GCE 必须声明透明标志与洋红透明索引 ──
            // 全局表 = [红, 蓝, 洋红]（首帧两色 + 透明槽），洋红索引 2。
            var gcePositions: [Int] = []
            for index in 0..<(data.count - 2) where data[index] == 0x21 && data[index + 1] == 0xF9 {
                gcePositions.append(index)
            }
            SelfTest.expectEqual(gcePositions.count, 2, "应有 2 个 GCE")
            if gcePositions.count == 2 {
                let gce = gcePositions[1]
                SelfTest.expectEqual(data[gce + 3] & 0x01, 0x01,
                                     "帧 1 GCE 透明标志（修复缺失时为 0）")
                SelfTest.expectEqual(data[gce + 6], 2,
                                     "帧 1 透明索引 = 洋红槽位 2（修复缺失时为 0）")
            }

            // ── 合成级：CoreGraphics 自动合成后，帧 1 = frameA + (0,1) 变蓝 ──
            guard let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
                  let image1 = CGImageSourceCreateImageAtIndex(source, 1, nil) else {
                SelfTest.expect(false, "CGImageSource 解码失败"); return
            }
            SelfTest.expectEqual(CGImageSourceGetCount(source), 2, "帧数")
            let buffer = renderedRGBA(image1)
            SelfTest.expectEqual(countColor(buffer, 0, 0, 255), 8 + 1, "帧 1 蓝：8 原有 + 1 变化")
            SelfTest.expectEqual(countColor(buffer, 255, 0, 0), 8 - 1, "帧 1 红：8 原有 − 1 变化")
        }
    }

    // MARK: - 黄金样例

    private static func goldenTest() {
        SelfTest.register("黄金样例：1×1 白点逐字节比对") {
            // 配置：1×1、无限循环、66ms、默认（局部表 + 八叉树）。
            let gif = GifFileWriter(width: 1, height: 1, loopCount: 0)
            try gif.appendFrame(pixels: [255, 255, 255, 255], delayMs: 66, isLastFrame: true)
            let data = Array(gif.finish())

            var expected: [UInt8] = []
            expected.append(contentsOf: Array("GIF89a".utf8))      // 文件头
            expected.append(contentsOf: [0x01, 0x00, 0x01, 0x00])  // 宽 1 高 1
            expected.append(0x08)                                   // packed：无全局表 | 排序 1
            expected.append(0x00)                                   // 背景色索引
            expected.append(0x00)                                   // 宽高比
            expected.append(contentsOf: [0x21, 0xFF, 0x0B])         // NETSCAPE2.0
            expected.append(contentsOf: Array("NETSCAPE2.0".utf8))
            expected.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00]) // 无限循环
            expected.append(contentsOf: [0x21, 0xF9, 0x04])         // GCE
            expected.append(0x04)                                   // 处置法 1（Leave）
            expected.append(contentsOf: [0x07, 0x00])               // 66ms → 7 tick
            expected.append(contentsOf: [0x00, 0x00])               // 透明索引 0 + 终止符
            expected.append(contentsOf: [0x2C])                     // 图像分隔符
            expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00]) // 矩形
            expected.append(0xA0)                                   // 局部表 + 排序 + 容量码 0
            expected.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00]) // 白 + 填充
            expected.append(0x02)                                   // LZW 初始码宽 = 色表位深（2 色表 → 2）
            // 码流：清除码(4)、像素 0、结束码(5)，3 位打包（LSB first）→ 44 01。
            expected.append(contentsOf: [0x02, 0x44, 0x01])
            expected.append(0x00)                                   // 子块终止符
            expected.append(contentsOf: [0x21, 0xFE, 0x15])         // 注释扩展
            expected.append(contentsOf: Array("Made with ScreenToGif".utf8))
            expected.append(0x00)
            expected.append(0x3B)                                   // 结束符

            SelfTest.expectEqual(data.count, expected.count, "总字节数")
            if data != expected {
                for (index, (a, b)) in zip(data, expected).enumerated() where a != b {
                    SelfTest.expect(false, "第 \(index) 字节：实际 0x\(String(a, radix: 16))，期望 0x\(String(b, radix: 16))")
                }
                if data.count != expected.count {
                    SelfTest.expect(false, "内容不一致且长度不同")
                }
            } else {
                SelfTest.expect(true, "")
            }

            // 顺带验证：该样例可被 ImageIO 解码为单帧白点。
            if let source = CGImageSourceCreateWithData(gif.finish() as CFData, nil) {
                SelfTest.expectEqual(CGImageSourceGetCount(source), 1, "可解码为 1 帧")
                if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    let buffer = renderedRGBA(image)
                    SelfTest.expectEqual(countColor(buffer, 255, 255, 255), 1, "解码为白点")
                }
            } else {
                SelfTest.expect(false, "ImageIO 无法打开黄金样例")
            }
        }
    }

    // MARK: - 测试辅助

    /// 生成 RGBA8 像素缓冲。
    private static func rgbaPixels(width: Int, height: Int,
                                   colorAt: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = colorAt(x, y)
                pixels.append(contentsOf: [color.0, color.1, color.2, 255])
            }
        }
        return pixels
    }

    /// 解析 GIF 子块链：返回拼接后的载荷与终止符之后的位置；格式非法返回 nil。
    private static func concatSubBlocks(_ data: [UInt8], start: Int) -> (payload: [UInt8], endIndex: Int)? {
        var payload: [UInt8] = []
        var index = start
        while index < data.count {
            let length = Int(data[index])
            index += 1
            guard length > 0 else { return (payload, index) }
            guard length <= 255, index + length <= data.count else { return nil }
            payload.append(contentsOf: data[index..<index + length])
            index += length
        }
        return nil
    }

    /// 测试用 GIF LZW 解码器（LSB 优先位流，处理清除码与码宽增长）。
    private static func lzwDecode(minCodeSize: Int, blocks: [UInt8]) -> [UInt8] {
        var bitPosition = 0

        func readCode(_ size: Int) -> Int {
            var code = 0
            for bit in 0..<size {
                let byte = blocks[(bitPosition + bit) >> 3]
                let bitValue = (Int(byte) >> ((bitPosition + bit) & 7)) & 1
                code |= bitValue << bit
            }
            bitPosition += size
            return code
        }

        let clearCode = 1 << minCodeSize
        let endCode = clearCode + 1

        // 字典：单色字面量 + 两个占位（清除码/结束码），使追加条目从 clear+2 起编号，
        // 与编码器的 availableCode 对齐（码宽增长时机才能一致）。
        func resetDictionary() -> [[UInt8]] {
            (0..<clearCode).map { [UInt8($0)] } + [[], []]
        }

        var dictionary = resetDictionary()
        var codeSize = minCodeSize + 1
        var previous: [UInt8]?

        var output: [UInt8] = []
        output.reserveCapacity(blocks.count * 2)

        while bitPosition + codeSize <= blocks.count * 8 {
            let code = readCode(codeSize)
            if code == clearCode {
                dictionary = resetDictionary()
                codeSize = minCodeSize + 1
                previous = nil
                continue
            }
            if code == endCode { break }

            var entry: [UInt8]
            if code < dictionary.count {
                entry = dictionary[code]
            } else if code == dictionary.count, let previous = previous {
                entry = previous + [previous[0]]
            } else {
                break // 数据异常，交由上层比对发现。
            }

            output.append(contentsOf: entry)

            if let previous = previous {
                dictionary.append(previous + [entry[0]])
                if dictionary.count == (1 << codeSize) && codeSize < 12 {
                    codeSize += 1
                }
            }
            previous = entry
        }
        return output
    }

    /// CGImage → RGBA8 缓冲（premultipliedLast 即 RGBA 顺序）。
    private static func renderedRGBA(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { pointer in
            if let context = CGContext(data: pointer.baseAddress, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return buffer
    }

    /// 统计与指定 RGB 相符的像素数（每通道容差 2）。
    private static func countColor(_ buffer: [UInt8], _ r: Int, _ g: Int, _ b: Int) -> Int {
        var count = 0
        var offset = 0
        while offset + 3 < buffer.count {
            if abs(Int(buffer[offset]) - r) <= 2,
               abs(Int(buffer[offset + 1]) - g) <= 2,
               abs(Int(buffer[offset + 2]) - b) <= 2 {
                count += 1
            }
            offset += 4
        }
        return count
    }

    /// 统计 RGBA 四通道全等的像素数。
    private static func countExactColor(_ buffer: [UInt8], _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Int {
        var count = 0
        var offset = 0
        while offset + 3 < buffer.count {
            if buffer[offset] == r, buffer[offset + 1] == g, buffer[offset + 2] == b, buffer[offset + 3] == a {
                count += 1
            }
            offset += 4
        }
        return count
    }

    /// 第 index 帧的未钳制延迟（秒）。
    private static func frameDelay(at index: Int, of source: CGImageSource) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return nil }
        return gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    }

    /// 容器级循环次数（无 NETSCAPE 块时为 nil）。
    private static func containerLoopCount(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return nil }
        return gif[kCGImagePropertyGIFLoopCount] as? Int
    }
}
