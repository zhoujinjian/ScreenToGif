import Foundation

/// 工程（对标原版 ProjectInfo.cs）。
/// 磁盘结构：Recording/{UUID}/ 内含 Project.json + 编号 PNG + ActionStack/Undo|Redo/。
final class Project: Codable {
    /// 目录名（UUID 字符串），对标原版 RelativePath。
    let id: String
    var creationDate: Date
    var frames: [FrameInfo]
    var width: Int
    var height: Int
    var dpi: Double
    /// 32 = BGRA（SCK 原生），24 = BGR。对标原版 BitDepth。
    var bitDepth: Int

    enum CodingKeys: String, CodingKey {
        case id = "RelativePath"
        case creationDate = "CreationDate"
        case frames = "Frames"
        case width = "Width"
        case height = "Height"
        case dpi = "Dpi"
        case bitDepth = "BitDepth"
    }

    init(width: Int, height: Int, dpi: Double = 72, bitDepth: Int = 32) {
        id = UUID().uuidString
        creationDate = Date()
        frames = []
        self.width = width
        self.height = height
        self.dpi = dpi
        self.bitDepth = bitDepth
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        creationDate = try c.decode(Date.self, forKey: .creationDate)
        frames = try c.decode([FrameInfo].self, forKey: .frames)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        dpi = (try? c.decodeIfPresent(Double.self, forKey: .dpi)) ?? 72
        bitDepth = (try? c.decodeIfPresent(Int.self, forKey: .bitDepth)) ?? 32
        reindex()
    }

    // MARK: - 路径

    /// 工程目录。
    var url: URL {
        Constants.recordingRoot.appendingPathComponent(id, isDirectory: true)
    }

    var jsonUrl: URL { url.appendingPathComponent("Project.json") }
    var undoRoot: URL { url.appendingPathComponent("ActionStack").appendingPathComponent("Undo", isDirectory: true) }
    var redoRoot: URL { url.appendingPathComponent("ActionStack").appendingPathComponent("Redo", isDirectory: true) }
    var frameCount: Int { frames.count }
    var totalDurationMs: Int { frames.reduce(0) { $0 + $1.delay } }

    /// 重算所有帧的运行时索引。
    func reindex() {
        for i in frames.indices { frames[i].index = i }
    }

    // MARK: - 读写

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 原版 DataContractJsonSerializer 输出 ISO 风格时间；此处保持 ISO8601 便于互通。
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: jsonUrl, options: .atomic)
    }

    static func load(from url: URL) throws -> Project {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: try Data(contentsOf: url.appendingPathComponent("Project.json")))
        project.reindex()
        return project
    }

    /// 删除工程目录（丢弃）。
    func deleteFromDisk() {
        try? FileManager.default.removeItem(at: url)
    }
}
