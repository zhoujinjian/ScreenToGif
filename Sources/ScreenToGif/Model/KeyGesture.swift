import Foundation
import AppKit

/// 录制时按下的按键（对标原版 SimpleKeyGesture）。
/// key 存显示名（"A" / "⏎" / "Space"），modifiers 存 NSEvent.ModifierFlags rawValue。
struct KeyGesture: Codable, Hashable {
    var key: String
    var modifiersRaw: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiersRaw = modifiers.rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRaw)
    }
}
