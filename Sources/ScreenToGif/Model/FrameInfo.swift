import Foundation

/// 单帧模型（对标原版 ScreenToGif/Model/FrameInfo.cs，JSON 键名保持 DataContract PascalCase 兼容）。
struct FrameInfo: Codable, Identifiable, Hashable {
    /// 内存态标识（不入 JSON）。
    var id = UUID()

    /// PNG 文件名（相对工程目录），如 "0.png"。
    var path: String
    /// 帧延迟（毫秒）。
    var delay: Int
    /// 光标 X（录制区坐标系）；Int.min = 未记录（沿用原版哨兵值）。
    var cursorX: Int = Int.min
    /// 光标 Y；Int.min = 未记录。
    var cursorY: Int = Int.min
    /// 本帧期间点击的鼠标键。
    var buttonClicked: MouseButtons = .none
    /// 本帧期间按下的按键。
    var keyList: [KeyGesture] = []

    /// 运行时索引（重算，不入 JSON）。
    var index: Int = 0

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case name = "Name"
        case delay = "Delay"
        case cursorX = "CursorX"
        case cursorY = "CursorY"
        case buttonClicked = "ButtonClicked"
        case keyList = "Keys"
    }

    init(path: String, delay: Int, cursorX: Int = Int.min, cursorY: Int = Int.min,
         buttonClicked: MouseButtons = .none, keyList: [KeyGesture] = []) {
        self.path = path
        self.delay = delay
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.buttonClicked = buttonClicked
        self.keyList = keyList
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 兼容原版存绝对路径：只取文件名。
        let rawPath = try c.decode(String.self, forKey: .path)
        path = (rawPath as NSString).lastPathComponent
        delay = try c.decode(Int.self, forKey: .delay)
        cursorX = (try? c.decodeIfPresent(Int.self, forKey: .cursorX)) ?? Int.min
        cursorY = (try? c.decodeIfPresent(Int.self, forKey: .cursorY)) ?? Int.min
        buttonClicked = (try? c.decodeIfPresent(MouseButtons.self, forKey: .buttonClicked)) ?? .none
        keyList = (try? c.decodeIfPresent([KeyGesture].self, forKey: .keyList)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode((path as NSString).lastPathComponent, forKey: .name)
        try c.encode(delay, forKey: .delay)
        if cursorX != Int.min { try c.encode(cursorX, forKey: .cursorX) }
        if cursorY != Int.min { try c.encode(cursorY, forKey: .cursorY) }
        if buttonClicked != .none { try c.encode(buttonClicked, forKey: .buttonClicked) }
        if !keyList.isEmpty { try c.encode(keyList, forKey: .keyList) }
    }
}
