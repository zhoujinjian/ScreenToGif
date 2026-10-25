import Foundation

// MARK: - 位打包器

/// 变长码位打包器（移植自 C# Encoder/BitEncoder.cs）：LSB 优先累积成字节。
final class BitEncoder {
    /// 输出字节集合（对应 C# OutList；编码器会直接读写以复刻 C# 的中段冲刷逻辑）。
    var outList: [UInt8] = []

    /// 当前输出长度。
    var length: Int { outList.count }

    /// 每个码的位宽（随 LZW 码表增长调整；对应 C# InBit）。
    var inBit: Int

    /// 剩余未凑满 8 位的位数（C# _currentBit）。
    private var currentBit = 0
    /// 未输出完的累积值（C# _currentVal）。
    private var currentVal = 0

    init(initBit: Int = 8) {
        inBit = initBit
    }

    /// 追加一个码（C# Add）：低位对齐拼接，凑满 8 位即输出。
    func add(_ code: Int) {
        currentVal |= code << currentBit
        currentBit += inBit

        // 输出恒为 8 位一组，即使码宽 3–12 位。
        while currentBit >= 8 {
            outList.append(UInt8(currentVal & 0xFF))
            currentVal >>= 8
            currentBit -= 8
        }
    }

    /// 收尾：不足 8 位的余量也输出（C# End）。
    func end() {
        while currentBit > 0 {
            outList.append(UInt8(currentVal & 0xFF))
            currentVal >>= 8
            currentBit -= 8
        }
    }
}

// MARK: - 新版 LZW（字典法）

/// GIF LZW 变长码压缩器（移植自 C# Encoder/LzwEncoder.cs，ScreenToGif 2019 新版）。
///
/// 输出格式：初始码宽字节 + 若干 ≤255 字节子块 + 0 终止符。
///
/// 注意：C# GifFile.WriteImage 实际固定调用的是下方的 LegacyLzwEncoder（初始码宽 8）；
/// 本类为原样移植，供低色深编码与测试使用。
///
/// 与 C# 的一处修正：C# 在收尾子块超过 255 字节时只写出 255 之后的剩余字节，
/// 前 255 字节被丢弃（产生损坏的 GIF，且与其自身的中段冲刷逻辑不一致）；
/// 移植版按中段冲刷的同一模式补齐 —— 先写满块再写余量块。
final class LzwEncoder {
    /// GIF LZW 最大 12 位，码表容量 4096。
    private static let maxStackSize = 4096

    /// 待编码的索引像素（每像素一个调色板下标）。
    let indexedPixels: [UInt8]

    /// 初始色深（位），最小 2（C# ColorDepth）。
    private(set) var colorDepth: Int

    /// 初始色深备份（码表重置时恢复，C# InitDataSize）。
    private let initDataSize: Int

    init(indexedPixels: [UInt8], colorDepth: Int) {
        self.indexedPixels = indexedPixels
        self.colorDepth = max(2, colorDepth)
        initDataSize = self.colorDepth
    }

    /// 编码并写出（C# Encode）。
    func encode(to writer: inout DataWriter) {
        var isFirst = true

        let clearCode = 1 << colorDepth
        let endOfFileCode = clearCode + 1

        // 键 "prefix,suffix" → 码表值。
        var codeTable: [String: Int] = [:]

        // 已消费的索引数（C# releaseCount）。
        var releaseCount = 0
        var codeSize = colorDepth + 1
        var availableCode = endOfFileCode + 1

        let bitEncoder = BitEncoder(initBit: codeSize)

        // 初始码宽。
        writer.put(UInt8(colorDepth))

        // 首个输出：清除码。
        bitEncoder.add(clearCode)

        var suffix = 0

        while releaseCount < indexedPixels.count {
            // 首字节：读入第一个索引。
            if isFirst {
                suffix = Int(indexedPixels[releaseCount])
                releaseCount += 1

                if releaseCount == indexedPixels.count {
                    bitEncoder.add(suffix)
                    bitEncoder.add(endOfFileCode)
                    bitEncoder.end()

                    writer.put(UInt8(bitEncoder.length))
                    writer.put(bitEncoder.outList)
                    bitEncoder.outList.removeAll()
                    break
                }

                isFirst = false
                continue
            }

            let prefix = suffix
            suffix = Int(indexedPixels[releaseCount])
            releaseCount += 1
            let entry = "\(prefix),\(suffix)"

            if codeTable[entry] == nil {
                // 未知实体：输出前缀，并把该实体登记进码表。
                bitEncoder.add(prefix)
                codeTable[entry] = availableCode
                availableCode += 1

                if availableCode > Self.maxStackSize - 3 {
                    // 码表将满：输出清除码并重建。
                    codeTable.removeAll()
                    colorDepth = initDataSize
                    codeSize = colorDepth + 1
                    availableCode = endOfFileCode + 1

                    bitEncoder.add(clearCode)
                    bitEncoder.inBit = codeSize
                } else if availableCode > (1 << codeSize) {
                    // 码值超出当前码宽可表示范围：码宽 +1。
                    colorDepth += 1
                    codeSize = colorDepth + 1
                    bitEncoder.inBit = codeSize
                }

                // 超过 255 字节即切出一块。
                if bitEncoder.length >= 255 {
                    writer.put(UInt8(255))
                    writer.put(Array(bitEncoder.outList[0..<255]))

                    if bitEncoder.length > 255 {
                        bitEncoder.outList = Array(bitEncoder.outList[255...])
                    } else {
                        bitEncoder.outList.removeAll()
                    }
                }
            } else {
                // 已知实体：前缀扩展为该实体的码值。
                suffix = codeTable[entry]!
            }

            // 到达末尾：输出余下的码并收尾。
            if releaseCount == indexedPixels.count {
                bitEncoder.add(suffix)
                bitEncoder.add(endOfFileCode)
                bitEncoder.end()

                if bitEncoder.length > 255 {
                    // 修正点（见类头注释）：C# 此处丢弃前 255 字节。
                    var rest = Array(bitEncoder.outList[255...])
                    writer.put(UInt8(255))
                    writer.put(Array(bitEncoder.outList[0..<255]))
                    while rest.count > 255 {
                        writer.put(UInt8(255))
                        writer.put(Array(rest[0..<255]))
                        rest = Array(rest[255...])
                    }
                    writer.put(UInt8(rest.count))
                    writer.put(rest)
                } else {
                    writer.put(UInt8(bitEncoder.length))
                    writer.put(bitEncoder.outList)
                }
                break
            }
        }

        // 子块链终止符（C# 原注释：忘了加这个导致 GIF 损坏）。
        writer.put(UInt8(0))
    }
}

// MARK: - 经典 LZW（哈希法）

/// 经典 GIF LZW 压缩器（移植自 C# LegacyEncoder/LzwEncoder.cs，
/// 谱系：Jef Poskanzer 的 Java 版 ← mgardi 的 GIFCOMPR.C）。
///
/// C# GifFile.WriteImage 固定以 colorDepth = 8 调用本编码器
/// （即使实际颜色数更少，子块也以 254 字节冲刷）。
final class LegacyLzwEncoder {
    private static let bits = 12
    private static let maxBits = 12
    /// 80% 占用率的哈希表容量。
    private static let hSize = 5003
    private static let maxMaxCode = 1 << 12

    private let masks = [0x0000, 0x0001, 0x0003, 0x0007, 0x000F, 0x001F, 0x003F, 0x007F, 0x00FF,
                         0x01FF, 0x03FF, 0x07FF, 0x0FFF, 0x1FFF, 0x3FFF, 0x7FFF, 0xFFFF]

    private let pixAry: [UInt8]
    private let initCodeSize: Int
    private var curPixel = 0

    private var numBits = 0
    private var maxCode = 0
    private var htab: [Int]
    private var codeTab: [Int]
    private var hSizeRegister = LegacyLzwEncoder.hSize
    private var freeEntry = 0
    private var clearFlg = false
    private var gInitBits = 0
    private var clearCode = 0
    private var eofCode = 0
    private var curAccum = 0
    private var curBits = 0

    /// 当前子块已积累的字符数。
    private var charCount = 0
    /// 子块积累缓冲（256 字节）。
    private var accumulator: [UInt8]

    /// - Parameters:
    ///   - width: 图像宽（C# 保留参数，未参与计算）。
    ///   - height: 图像高（同上）。
    ///   - pixels: 索引像素。
    ///   - colorDepth: 色深（位），内部最小取 2。
    init(width: Int, height: Int, pixels: [UInt8], colorDepth: Int) {
        pixAry = pixels
        initCodeSize = max(2, colorDepth)
        htab = [Int](repeating: -1, count: LegacyLzwEncoder.hSize)
        codeTab = [Int](repeating: 0, count: LegacyLzwEncoder.hSize)
        accumulator = [UInt8](repeating: 0, count: 256)
    }

    /// 编码并写出：初始码宽字节 + 子块链 + 0 终止符（C# Encode）。
    func encode(to writer: inout DataWriter) {
        writer.put(UInt8(initCodeSize))
        curPixel = 0
        compress(initBits: initCodeSize + 1, to: &writer)
        writer.put(UInt8(0))
    }

    // MARK: - 压缩主体

    /// 开放寻址双散列的 LZW 压缩（C# Compress；C# 的 goto outer_loop 以标签 continue 表达）。
    private func compress(initBits: Int, to writer: inout DataWriter) {
        gInitBits = initBits
        clearFlg = false
        numBits = gInitBits
        maxCode = Self.maxCode(of: numBits)

        clearCode = 1 << (initBits - 1)
        eofCode = clearCode + 1
        freeEntry = clearCode + 2

        charCount = 0

        var ent = nextPixel() ?? -1

        var hshift = 0
        var fcode = hSizeRegister
        while fcode < 65536 {
            hshift += 1
            fcode *= 2
        }
        hshift = 8 - hshift

        let hsizeReg = hSizeRegister
        resetCodeTable(hsizeReg)

        output(clearCode, to: &writer)

        outerLoop: while let c = nextPixel() {
            var i = (c << hshift) ^ ent
            fcode = (c << Self.bits) + ent

            if htab[i] == fcode {
                ent = codeTab[i]
                continue
            }

            if htab[i] >= 0 {
                // 非空槽：按 G. Knott 素数步长反向探测。
                var disp = hsizeReg - i
                if i == 0 { disp = 1 }
                while true {
                    i -= disp
                    if i < 0 { i += hsizeReg }

                    if htab[i] == fcode {
                        ent = codeTab[i]
                        continue outerLoop
                    }
                    if htab[i] < 0 { break }
                }
            }

            output(ent, to: &writer)
            ent = c

            if freeEntry < Self.maxMaxCode {
                codeTab[i] = freeEntry
                freeEntry += 1
                htab[i] = fcode
            } else {
                clearTable(to: &writer)
            }
        }

        // 输出最后一个码与结束码。
        output(ent, to: &writer)
        output(eofCode, to: &writer)
    }

    // MARK: - 输出

    /// 输出一个码并维护码宽增长（C# Output）。
    private func output(_ code: Int, to writer: inout DataWriter) {
        curAccum &= masks[curBits]

        if curBits > 0 {
            curAccum |= code << curBits
        } else {
            curAccum = code
        }

        curBits += numBits

        while curBits >= 8 {
            add(UInt8(curAccum & 0xFF), to: &writer)
            curAccum >>= 8
            curBits -= 8
        }

        // 下一个码放不下时增加码宽（自适应重置时恢复初始码宽）。
        if freeEntry > maxCode || clearFlg {
            if clearFlg {
                numBits = gInitBits
                maxCode = Self.maxCode(of: numBits)
                clearFlg = false
            } else {
                numBits += 1
                maxCode = numBits == Self.maxBits ? Self.maxMaxCode : Self.maxCode(of: numBits)
            }
        }

        if code == eofCode {
            // EOF：把余下的缓冲按 8 位逐个输出并冲刷子块。
            while curBits > 0 {
                add(UInt8(curAccum & 0xFF), to: &writer)
                curAccum >>= 8
                curBits -= 8
            }
            flush(to: &writer)
        }
    }

    /// 追加一个字符，满 254 即冲刷子块（C# Add）。
    private func add(_ c: UInt8, to writer: inout DataWriter) {
        accumulator[charCount] = c
        charCount += 1
        if charCount >= 254 {
            flush(to: &writer)
        }
    }

    /// 冲刷子块（C# Flush）。
    private func flush(to writer: inout DataWriter) {
        if charCount > 0 {
            writer.put(UInt8(charCount))
            writer.put(Array(accumulator[0..<charCount]))
            charCount = 0
        }
    }

    /// 清空码表并输出清除码（C# ClearTable）。
    private func clearTable(to writer: inout DataWriter) {
        resetCodeTable(hSizeRegister)
        freeEntry = clearCode + 2
        clearFlg = true
        output(clearCode, to: &writer)
    }

    private func resetCodeTable(_ hsize: Int) {
        for i in 0..<hsize {
            htab[i] = -1
        }
    }

    /// 下一个索引像素；耗尽返回 nil（C# Eof = -1）。
    private func nextPixel() -> Int? {
        if curPixel < pixAry.count {
            let pix = Int(pixAry[curPixel])
            curPixel += 1
            return pix
        }
        return nil
    }

    private static func maxCode(of numBits: Int) -> Int {
        (1 << numBits) - 1
    }
}
