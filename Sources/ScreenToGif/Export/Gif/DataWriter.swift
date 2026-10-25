import Foundation

/// 小端字节写入器。
/// GIF 的所有整数字段均为 little-endian（如宽度 100 写作 64 00），
/// 对应 C# GifFile 的 WriteByte / WriteShort / WriteString 私有辅助方法。
struct DataWriter {
    /// 已写出的字节。
    private(set) var bytes: [UInt8] = []

    /// 已写出的字节数。
    var count: Int { bytes.count }

    init() {}

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: - 基础写入

    /// 写入单字节。
    mutating func put(_ value: UInt8) {
        bytes.append(value)
    }

    /// 以小端写入 16 位整数（C# WriteShort：100 → 64 00）。
    mutating func put(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    /// 以小端写入 32 位整数。
    mutating func put(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    /// 追加一段字节。
    mutating func put(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }

    /// 写入 ASCII 字符串（"GIF89a"、"NETSCAPE2.0" 等）。
    /// C# 逐字符强转 byte；ASCII 输入下与 UTF-8 编码逐字节等价。
    mutating func put(ascii string: String) {
        bytes.append(contentsOf: string.utf8)
    }

    // MARK: - 子块

    /// 按 GIF 数据子块格式写出：每块 ≤ maxBlockSize 字节、前置 1 字节长度，末尾补 0 终止符。
    mutating func putSubBlocks(_ data: [UInt8], maxBlockSize: Int = 255) {
        var start = 0
        while start < data.count {
            let end = min(start + maxBlockSize, data.count)
            put(UInt8(end - start))
            put(Array(data[start..<end]))
            start = end
        }
        put(UInt8(0))
    }
}
