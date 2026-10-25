import Foundation
import Observation

/// 全局可观察状态。
@Observable
final class AppState {
    static let shared = AppState()

    /// 最近打开的工程（路径，新的在前），持久化到设置。
    var recentProjects: [String] = [] {
        didSet { UserSettings.shared.recentProjects = recentProjects }
    }

    /// 权限状态。
    var hasScreenRecordingPermission = false
    var hasAccessibilityPermission = false

    /// 当前是否正有录制进行（用于互斥）。
    var isRecordingActive = false

    private init() {
        recentProjects = UserSettings.shared.recentProjects
    }

    func pushRecent(_ path: String) {
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        recentProjects = Array(list.prefix(10))
    }
}
