import AppKit
import CoreGraphics

/// 全局输入事件记录（对标原版 InputHook WH_MOUSE_LL/WH_KEYBOARD_LL）。
/// 基于 CGEventTap（需辅助功能权限）；无权限时点击/按键不记录，光标轨迹仍可用 NSEvent.mouseLocation。
final class EventRecorder {
    struct Drained {
        var button: MouseButtons = .none
        var keys: [KeyGesture] = []
    }

    private var tap: CFMachPort?
    private var buttonBuffer: MouseButtons = .none
    private var keysBuffer: [KeyGesture] = []
    private let lock = NSLock()
    private var lastMouseGlobal: CGPoint?

    private(set) var isActive = false

    /// 启动监听（无权限时静默不启动）。
    func start() {
        guard PermissionManager.hasAccessibility() else {
            Log.capture.info("无辅助功能权限：点击/按键记录降级关闭")
            return
        }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)

        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<EventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
                recorder.record(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.capture.error("CGEventTap 创建失败")
            return
        }

        tap = newTap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0), .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        isActive = true
        Log.capture.info("输入事件记录已启动（CGEventTap）")
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        isActive = false
    }

    /// 取走自上次 drain 以来累积的点击/按键（帧归属）。
    func drainEvents() -> Drained {
        lock.lock()
        defer { lock.unlock() }
        let result = Drained(button: buttonBuffer, keys: keysBuffer)
        buttonBuffer = .none
        keysBuffer = []
        return result
    }

    /// 最近一次鼠标全局位置（AppKit 坐标；无 tap 时为 nil）。
    var lastMouseLocation: CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return lastMouseGlobal
    }

    // MARK: - 回调（tap 线程）

    private func record(type: CGEventType, event: CGEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch type {
        case .leftMouseDown:
            buttonBuffer = .left
        case .rightMouseDown:
            buttonBuffer = .right
        case .otherMouseDown:
            buttonBuffer = .middle
        case .keyDown:
            if UserSettings.shared.captureKeyStrokes {
                if let gesture = readableKeyGesture(from: event) {
                    keysBuffer.append(gesture)
                }
            }
        case .mouseMoved:
            let loc = event.location
            lastMouseGlobal = CGPoint(x: loc.x, y: ScreenMath.appKitGlobalY(fromCGY: loc.y))
        default:
            break
        }
    }

    /// CGEvent → 可读按键（Unicode 字符 + 修饰键，避开虚拟键码布局差异）。
    private func readableKeyGesture(from event: CGEvent) -> KeyGesture? {
        var flags: NSEvent.ModifierFlags = []
        let rawFlags = event.flags
        if rawFlags.contains(.maskCommand) { flags.insert(.command) }
        if rawFlags.contains(.maskShift) { flags.insert(.shift) }
        if rawFlags.contains(.maskAlternate) { flags.insert(.option) }
        if rawFlags.contains(.maskControl) { flags.insert(.control) }

        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        var key = ""
        if length > 0, let scalar = Unicode.Scalar(chars[0]) {
            key = String(Character(scalar))
            if flags.isDisjoint(with: [.shift]) {
                key = key.lowercased()   // 无 Shift 时统一小写（与原版一致）
            }
        } else {
            key = keyCodeName(event.getIntegerValueField(.keyboardEventKeycode))
        }
        if key.isEmpty { return nil }
        return KeyGesture(key: key, modifiers: flags.subtracting(.shift))
    }
}

/// 常见功能键名（对标原版 KeyInterop 命名习惯）。
private func keyCodeName(_ code: Int64) -> String {
    switch code {
    case 36: return "↩"        // Return
    case 48: return "⇥"        // Tab
    case 49: return "Space"
    case 51: return "⌫"        // Delete
    case 53: return "Esc"
    case 76: return "↩"        // 小回车
    case 96, 97, 98, 99: return "F\(code - 93)"
    case 100: return "F7"
    case 101: return "F8"
    case 109: return "F9"
    case 103: return "F10"
    case 111: return "F11"
    case 105: return "F12"
    case 122: return "F5"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default: return ""
    }
}
