import Foundation
import AppKit
import Observation
import CoreGraphics

/// 编辑器视图模型：选区/播放/操作分发/撤销入口。
@Observable
final class EditorViewModel {
    var project: Project?
    private(set) var selection: Set<Int> = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying = false
    var loopPlayback = true

    private(set) var undoStack: UndoStack?
    /// 应用内剪贴板（帧组）。
    private(set) var clipboardFrames: [FrameInfo] = []
    private(set) var statusText = ""

    /// 预览当前帧图像（当前索引变化时刷新）。
    private(set) var currentImage: CGImage?

    var isEmpty: Bool { project?.frames.isEmpty ?? true }

    private var playbackTicker: Timer?

    // MARK: - 装载

    func load(project newProject: Project) {
        stopPlayback()
        project = newProject
        selection = []
        currentIndex = 0
        undoStack = UndoStack(project: newProject, maxDepth: UserSettings.shared.undoDepth)
        FrameThumbnailProvider.shared.clearCaches()
        refreshCurrentImage()
        AppState.shared.pushRecent(newProject.id)
        statusText = "已载入 \(newProject.frameCount) 帧 · \(newProject.width)×\(newProject.height)"
    }

    // MARK: - 选区

    /// 点击帧条：设置当前帧；按住 ⌘/⇧ 加入多选。
    func selectFrame(_ index: Int, addToSelection: Bool) {
        guard let project, index >= 0, index < project.frames.count else { return }
        if addToSelection {
            if selection.contains(index) {
                selection.remove(index)
            } else {
                selection.insert(index)
            }
        } else {
            selection = []
        }
        currentIndex = index
        if !isPlaying { refreshCurrentImage() }
    }

    func selectAll() {
        guard let project else { return }
        selection = Set(0..<project.frames.count)
    }

    func deselectAll() {
        selection = []
    }

    /// 操作内部替换选区（FrameOperations 用）。
    func replaceSelection(_ newSelection: Set<Int>) {
        selection = newSelection
    }

    func invertSelection() {
        guard let project else { return }
        selection = Set(0..<project.frames.count).subtracting(selection)
    }

    /// 有效选区（无多选时 = [currentIndex]）。
    var effectiveSelection: [Int] {
        guard let project else { return [] }
        if selection.count >= 1 {
            return selection.sorted().filter { $0 < project.frames.count }
        }
        return currentIndex >= 0 && currentIndex < project.frames.count ? [currentIndex] : []
    }

    // MARK: - 播放（Timer 简化实现：CADisplayLink 版本见 PlaybackEngine，测试环境用之）

    func togglePlayback() {
        guard let project, project.frames.count > 1 else { return }
        isPlaying.toggle()
        if isPlaying {
            scheduleNextFrame()
        }
    }

    func stopPlayback() {
        isPlaying = false
        playbackTicker?.invalidate()
        playbackTicker = nil
    }

    private func scheduleNextFrame() {
        playbackTicker?.invalidate()
        guard isPlaying, let project, !project.frames.isEmpty else { return }
        let delayMs = project.frames[currentIndex].delay
        let interval = max(Double(delayMs) / 1000.0, 0.01)
        playbackTicker = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        guard let project else { return }
        let next = currentIndex + 1
        if next >= project.frames.count {
            if loopPlayback {
                currentIndex = 0
            } else {
                stopPlayback()
                refreshCurrentImage()
                return
            }
        } else {
            currentIndex = next
        }
        refreshCurrentImage()
        scheduleNextFrame()
    }

    func stepForward() {
        stopPlayback()
        guard let project else { return }
        currentIndex = min(currentIndex + 1, project.frames.count - 1)
        refreshCurrentImage()
    }

    func stepBackward() {
        stopPlayback()
        currentIndex = max(currentIndex - 1, 0)
        refreshCurrentImage()
    }

    func jumpToFirst() {
        stopPlayback()
        currentIndex = 0
        refreshCurrentImage()
    }

    func jumpToLast() {
        stopPlayback()
        guard let project else { return }
        currentIndex = project.frames.count - 1
        refreshCurrentImage()
    }

    func jump(to index: Int) {
        stopPlayback()
        guard let project else { return }
        currentIndex = min(max(0, index), project.frames.count - 1)
        refreshCurrentImage()
    }

    private func refreshCurrentImage() {
        guard let project, !project.frames.isEmpty, currentIndex < project.frames.count,
              let img = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: project.frames[currentIndex].path)
        else {
            currentImage = nil
            return
        }
        currentImage = img
    }

    // MARK: - 撤销

    var canUndo: Bool { undoStack?.canUndo ?? false }
    var canRedo: Bool { undoStack?.canRedo ?? false }

    func pushUndoCheckpoint() {
        undoStack?.pushCheckpoint()
    }

    func undo() {
        undoStack?.undo()
        clampIndices()
        refreshCurrentImage()
        statusText = "已撤销（剩余 \(undoStack?.undoCount ?? 0) 步）"
    }

    func redo() {
        undoStack?.redo()
        clampIndices()
        refreshCurrentImage()
        statusText = "已重做"
    }

    private func clampIndices() {
        guard let project else { return }
        currentIndex = min(currentIndex, max(0, project.frames.count - 1))
        selection = Set(selection.filter { $0 < project.frames.count })
    }

    /// 操作后统一收尾：保存 + 清预览缓存 + 状态栏刷新。
    func afterMutation() {
        try? project?.save()
        FrameThumbnailProvider.shared.clearCaches()
        clampIndices()
        refreshCurrentImage()
        statusText = "\(project?.frameCount ?? 0) 帧 · \(project?.width ?? 0)×\(project?.height ?? 0)"
    }

    // MARK: - 操作分发（工具栏调用）

    func deleteFrames() {
        guard !effectiveSelection.isEmpty else { return }
        if UserSettings.shared.deleteConfirmation {
            let alert = NSAlert()
            alert.messageText = "删除 \(effectiveSelection.count) 帧？"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        FrameOperations.deleteSelected(self)
        statusText = "已删除帧"
    }

    func copyFrames() {
        clipboardFrames = FrameOperations.copy(self)
        statusText = "已复制 \(clipboardFrames.count) 帧"
    }

    func pasteFrames() {
        guard !clipboardFrames.isEmpty else { return }
        FrameOperations.paste(self, frames: clipboardFrames)
        statusText = "已粘贴 \(clipboardFrames.count) 帧"
    }

    func reverseFrames() {
        FrameOperations.reverse(self)
        statusText = "已反转"
    }

    func yoyoFrames() {
        FrameOperations.yoyo(self)
        statusText = "已应用 Yoyo"
    }

    func removeDuplicates() {
        FrameOperations.removeDuplicates(self, thresholdPercent: 90)
        statusText = "已去重"
    }

    func reduceFrames(factor: Int) {
        FrameOperations.reduce(self, keepEvery: factor, applyToAll: selection.count > 1)
        statusText = "已减帧（每 \(factor) 帧保留 1）"
    }

    func editDelays(mode: DelayEditMode, value: Int, percent: Double, applyToAll: Bool) {
        FrameOperations.editDelays(self, mode: mode, value: value, percent: percent, applyToAll: applyToAll)
        statusText = "已调整延迟"
    }

    func crop(to rect: CGRect) {
        FrameOperations.crop(self, to: rect)
        statusText = "已裁剪"
    }

    func resize(scale: Double) {
        FrameOperations.resize(self, scale: scale)
        statusText = "已缩放 \(Int(scale * 100))%"
    }

    func flipRotate(kind: FrameOperations.FlipRotateKind) {
        FrameOperations.flipRotate(self, kind: kind)
        statusText = "已翻转/旋转"
    }

    // MARK: - 展示

    func thumbnail(for index: Int) -> NSImage? {
        guard let project, index >= 0, index < project.frames.count else { return nil }
        return FrameThumbnailProvider.shared.thumbnail(projectURL: project.url, framePath: project.frames[index].path)
    }

    var totalDurationText: String {
        guard let project else { return "0.0s" }
        return String(format: "%.1fs", Double(project.totalDurationMs) / 1000)
    }
}
