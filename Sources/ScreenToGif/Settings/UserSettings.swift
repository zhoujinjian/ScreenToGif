import Foundation
import Observation

/// 用户设置（对标原版 UserSettings；JSON 持久化到 Application Support，原子写）。
@Observable
final class UserSettings {
    static let shared = UserSettings()

    // MARK: 设置项（Phase 1 子集）
    var schemaVersion: Int = 1
    // 应用
    var launchPage: String = "Startup"
    // 录制
    var fps: Int = 15
    var fixedFrameRate: Bool = false
    var captureCursor: Bool = true
    var captureMouseClicks: Bool = true
    var captureKeyStrokes: Bool = false
    var snapToWindow: Bool = true
    var showGuidelinesThirds: Bool = false
    var showGuidelinesCrosshair: Bool = false
    var preStartCountdown: Int = 0
    var discardConfirmation: Bool = true
    // 编辑器
    var undoDepth: Int = Constants.defaultUndoDepth
    var deleteConfirmation: Bool = true
    // 导出
    var exportLoopCount: Int = 0
    var exportMaxColors: Int = 256
    var exportDetectUnchanged: Bool = true
    var exportQuantizer: String = "Octree"
    // 最近工程
    var recentProjects: [String] = []

    private static var fileURL: URL {
        Constants.applicationSupport.appendingPathComponent("Settings.json")
    }

    private init() {
        load()
    }

    // MARK: - 持久化

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        if let mirror = try? decoder.decode(SettingsMirror.self, from: data) {
            self.schemaVersion = mirror.schemaVersion ?? schemaVersion
            self.launchPage = mirror.launchPage ?? launchPage
            self.fps = mirror.fps ?? fps
            self.fixedFrameRate = mirror.fixedFrameRate ?? fixedFrameRate
            self.captureCursor = mirror.captureCursor ?? captureCursor
            self.captureMouseClicks = mirror.captureMouseClicks ?? captureMouseClicks
            self.captureKeyStrokes = mirror.captureKeyStrokes ?? captureKeyStrokes
            self.snapToWindow = mirror.snapToWindow ?? snapToWindow
            self.showGuidelinesThirds = mirror.showGuidelinesThirds ?? showGuidelinesThirds
            self.showGuidelinesCrosshair = mirror.showGuidelinesCrosshair ?? showGuidelinesCrosshair
            self.preStartCountdown = mirror.preStartCountdown ?? preStartCountdown
            self.discardConfirmation = mirror.discardConfirmation ?? discardConfirmation
            self.undoDepth = mirror.undoDepth ?? undoDepth
            self.deleteConfirmation = mirror.deleteConfirmation ?? deleteConfirmation
            self.exportLoopCount = mirror.exportLoopCount ?? exportLoopCount
            self.exportMaxColors = mirror.exportMaxColors ?? exportMaxColors
            self.exportDetectUnchanged = mirror.exportDetectUnchanged ?? exportDetectUnchanged
            self.exportQuantizer = mirror.exportQuantizer ?? exportQuantizer
            self.recentProjects = mirror.recentProjects ?? recentProjects
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(mirror()) else { return }
        // 原子写：先写临时文件再改名。
        let tmp = Self.fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(Self.fileURL, withItemAt: tmp)
        } catch {
            Log.settings.error("设置保存失败: \(error.localizedDescription)")
        }
    }

    private func mirror() -> SettingsMirror {
        SettingsMirror(
            schemaVersion: schemaVersion, launchPage: launchPage,
            fps: fps, fixedFrameRate: fixedFrameRate,
            captureCursor: captureCursor, captureMouseClicks: captureMouseClicks,
            captureKeyStrokes: captureKeyStrokes, snapToWindow: snapToWindow,
            showGuidelinesThirds: showGuidelinesThirds, showGuidelinesCrosshair: showGuidelinesCrosshair,
            preStartCountdown: preStartCountdown, discardConfirmation: discardConfirmation,
            undoDepth: undoDepth, deleteConfirmation: deleteConfirmation,
            exportLoopCount: exportLoopCount, exportMaxColors: exportMaxColors,
            exportDetectUnchanged: exportDetectUnchanged, exportQuantizer: exportQuantizer,
            recentProjects: recentProjects
        )
    }
}

/// 磁盘镜像（全部可选，容忍旧版本字段缺失；绕开 @Observable 手写 Codable）。
private struct SettingsMirror: Codable {
    var schemaVersion: Int?
    var launchPage: String?
    var fps: Int?
    var fixedFrameRate: Bool?
    var captureCursor: Bool?
    var captureMouseClicks: Bool?
    var captureKeyStrokes: Bool?
    var snapToWindow: Bool?
    var showGuidelinesThirds: Bool?
    var showGuidelinesCrosshair: Bool?
    var preStartCountdown: Int?
    var discardConfirmation: Bool?
    var undoDepth: Int?
    var deleteConfirmation: Bool?
    var exportLoopCount: Int?
    var exportMaxColors: Int?
    var exportDetectUnchanged: Bool?
    var exportQuantizer: String?
    var recentProjects: [String]?
}
