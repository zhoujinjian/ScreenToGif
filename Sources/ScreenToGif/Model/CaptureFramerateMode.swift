import Foundation

/// 采集频率模式（对标原版 CaptureFrequencies）。
/// Phase 1 启用 perSecond；其余占位。
enum CaptureFramerateMode: String, Codable, CaseIterable {
    case perSecond
    case perMinute
    case perHour
    case manual
    case interaction

    var displayName: String {
        switch self {
        case .perSecond: return "每秒（FPS）"
        case .perMinute: return "每分钟"
        case .perHour: return "每小时"
        case .manual: return "手动（快照）"
        case .interaction: return "交互触发"
        }
    }
}

/// 延迟编辑模式（对标原版 DelayUpdateModes：覆盖/增减/缩放）。
enum DelayEditMode: String, Codable, CaseIterable {
    case override    // 设定新值
    case increaseDecrease
    case scale       // 百分比缩放

    var displayName: String {
        switch self {
        case .override: return "覆盖"
        case .increaseDecrease: return "增加/减少"
        case .scale: return "按比例缩放"
        }
    }
}
