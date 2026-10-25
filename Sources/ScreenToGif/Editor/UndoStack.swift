import Foundation

/// 撤销/重做（快照式，复刻原版 ActionStack）：
/// 每次变更前把受影响帧 PNG 复制到 ActionStack/Undo/{n}/ + 全量 FrameInfo 列表 JSON 入栈；
/// 重做镜像。新操作清空重做栈。
final class UndoStack {
    private let project: Project
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private let maxDepth: Int

    struct Entry {
        let frames: [FrameInfo]
        let savedFileNames: [String]   // 已备份到快照目录的帧文件名
        let snapshotDir: URL
    }

    init(project: Project, maxDepth: Int = Constants.defaultUndoDepth) {
        self.project = project
        self.maxDepth = maxDepth
    }

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoCount: Int { undoEntries.count }
    var redoCount: Int { redoEntries.count }

    /// 操作前调用：快照当前状态。
    func pushCheckpoint() {
        let dir = project.undoRoot.appendingPathComponent("\(undoEntries.count)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 备份所有帧文件（简单起见全量备份文件名清单；物理文件在删除时才真正复制——这里先记录，
        // 但为了正确性，直接全量复制当前存在的帧文件）。
        var copied: [String] = []
        for frame in project.frames {
            let src = project.url.appendingPathComponent(frame.path)
            let dst = dir.appendingPathComponent(frame.path)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: dst)
                copied.append(frame.path)
            }
        }

        undoEntries.append(Entry(frames: project.frames, savedFileNames: copied, snapshotDir: dir))
        // 新操作：清空重做（原版语义）
        redoEntries.forEach { try? FileManager.default.removeItem(at: $0.snapshotDir) }
        redoEntries.removeAll()

        // 深度限制：丢最老
        if undoEntries.count > maxDepth, let oldest = undoEntries.first {
            try? FileManager.default.removeItem(at: oldest.snapshotDir)
            undoEntries.removeFirst()
        }
    }

    /// 撤销：当前状态存入重做栈，恢复上一快照。
    func undo() {
        guard let entry = undoEntries.popLast() else { return }
        pushRedoCheckpoint()
        restore(entry)
    }

    /// 重做。
    func redo() {
        guard let entry = redoEntries.popLast() else { return }
        // 当前状态推回撤销栈（不触发清空）
        let dir = project.undoRoot.appendingPathComponent("\(undoEntries.count)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var copied: [String] = []
        for frame in project.frames {
            let src = project.url.appendingPathComponent(frame.path)
            let dst = dir.appendingPathComponent(frame.path)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: dst)
                copied.append(frame.path)
            }
        }
        undoEntries.append(Entry(frames: project.frames, savedFileNames: copied, snapshotDir: dir))
        restore(entry)
    }

    private func pushRedoCheckpoint() {
        let dir = project.redoRoot.appendingPathComponent("\(redoEntries.count)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var copied: [String] = []
        for frame in project.frames {
            let src = project.url.appendingPathComponent(frame.path)
            let dst = dir.appendingPathComponent(frame.path)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: dst)
                copied.append(frame.path)
            }
        }
        redoEntries.append(Entry(frames: project.frames, savedFileNames: copied, snapshotDir: dir))
    }

    /// 恢复快照：从快照目录把帧文件复制回工程根，并重设 frames 列表。
    private func restore(_ entry: Entry) {
        for name in entry.savedFileNames {
            let src = entry.snapshotDir.appendingPathComponent(name)
            let dst = project.url.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
        project.frames = entry.frames
        project.reindex()
        try? project.save()
    }
}
