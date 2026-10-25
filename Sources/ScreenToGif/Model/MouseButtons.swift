import Foundation

/// 鼠标按键（raw 值与原版 MouseButtons 枚举一致，保 Project.json 兼容）。
enum MouseButtons: String, Codable, Hashable {
    case none = "None"
    case left = "Left"
    case right = "Right"
    case middle = "Middle"
    case xButton1 = "XButton1"
    case xButton2 = "XButton2"
}
