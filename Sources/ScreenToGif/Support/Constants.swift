import Foundation

/// 全局常量。
enum Constants {
    static let bundleIdentifier = "com.screentogif.mac"
    static let appName = "ScreenToGif"

    /// 录制工程的根目录（与原版 %TEMP%\ScreenToGif\Recording 同构）。
    static var recordingRoot: URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScreenToGif", isDirectory: true)
            .appendingPathComponent("Recording", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 应用设置目录。
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ScreenToGif", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 撤销栈默认深度（原版默认 50）。
    static let defaultUndoDepth = 50

    /// GIF 最小帧延迟（毫秒），防浏览器 0 延迟崩坏。
    static let minimumGifFrameDelayMs = 20
}
