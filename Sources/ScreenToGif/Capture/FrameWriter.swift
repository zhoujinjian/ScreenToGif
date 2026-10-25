import AppKit
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// 帧写盘器：串行队列消费 FramePipeline，PNG 编码落盘 + FrameInfo 累积。
/// 完成时产出 Project（含 Project.json）。
final class FrameWriter {
    private let pipeline: FramePipeline
    private let region: CaptureRegion
    private let queue = DispatchQueue(label: "com.screentogif.writer", qos: .userInitiated)
    private var project: Project?
    private var frameInfos: [FrameInfo] = []
    private var clock: FrameClock
    private var thread: Thread?
    private var running = false
    /// 消费线程结束信号（Darwin 的 Thread 无 join，用信号量等待）。
    private let doneSemaphore = DispatchSemaphore(value: 0)

    init(pipeline: FramePipeline, region: CaptureRegion) {
        self.pipeline = pipeline
        self.region = region
        self.clock = FrameClock(fixedRate: false, fps: 15)   // delay 由 ScreenRecorder 传入时间戳计算
    }

    /// 开始：建工程目录，启动消费线程。
    func begin(fps: Int = 15, fixedRate: Bool = false) {
        let project = Project(
            width: Int(region.rect.width),
            height: Int(region.rect.height),
            dpi: 72,
            bitDepth: 32
        )
        try? FileManager.default.createDirectory(at: project.url, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: project.undoRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: project.redoRoot, withIntermediateDirectories: true)
        self.project = project
        self.clock = FrameClock(fixedRate: fixedRate, fps: fps)
        frameInfos = []

        running = true
        let thread = Thread { [weak self] in
            self?.consumeLoop()
        }
        thread.name = "ScreenToGif.FrameWriter"
        thread.start()
        self.thread = thread
    }

    /// 快照路径（SCScreenshotManager 的 CGImage 直接写入）。
    func appendSnapshot(image: CGImage, timestampMs: Int, cursor: (x: Int, y: Int)?, events: EventRecorder.Drained) {
        queue.async { [self] in
            guard let project else { return }
            let index = frameInfos.count
            let name = "\(index).png"
            let url = project.url.appendingPathComponent(name)
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
            let delay = clock.delay(forTimestampMs: timestampMs)
            frameInfos.append(FrameInfo(
                path: name, delay: delay,
                cursorX: cursor?.x ?? Int.min, cursorY: cursor?.y ?? Int.min,
                buttonClicked: events.button, keyList: events.keys
            ))
        }
    }

    /// 停止采集后收尾：等待队列排空 → 组装 Project 并写 Project.json。
    func finish(fps: Int, fixedRate: Bool, elapsedMs: Int, dropped: Int) throws -> Project {
        guard let project else { throw WriterError.notStarted }
        // pipeline.close() 已由调用方执行；等消费线程退出。
        if thread != nil {
            doneSemaphore.wait()
            thread = nil
        }

        project.frames = frameInfos
        project.reindex()
        if project.frames.isEmpty {
            // 空录制（如静止 + variable 且只采到 0 帧）：补 1 张当前截图由调用方处理，这里抛出让 UI 提示。
            throw WriterError.noFrames
        }
        try project.save()
        Log.capture.info("工程写入完成 frames=\(project.frameCount) dropped=\(dropped) elapsed=\(elapsedMs)ms")
        return project
    }

    /// 丢弃：停线程 + 删目录。
    func discard() {
        running = false
        pipeline.close()
        if thread != nil {
            doneSemaphore.wait()
            thread = nil
        }
        project?.deleteFromDisk()
    }

    // MARK: - 消费循环（writer 线程）

    private func consumeLoop() {
        defer { doneSemaphore.signal() }
        while running {
            guard let frame = pipeline.dequeue() else { break }   // closed 且空 → nil
            guard let project else { break }
            let index = frameInfos.count
            let name = "\(index).png"
            let url = project.url.appendingPathComponent(name)
            do {
                try frame.pixelBuffer.writePNG(to: url)
                let delay = clock.delay(forTimestampMs: frame.timestampMs)
                frameInfos.append(FrameInfo(
                    path: name, delay: delay,
                    cursorX: frame.cursorX >= 0 ? frame.cursorX : Int.min,
                    cursorY: frame.cursorY >= 0 ? frame.cursorY : Int.min,
                    buttonClicked: frame.buttonClicked, keyList: frame.keys
                ))
            } catch {
                Log.capture.error("帧写入失败 #\(index): \(error.localizedDescription)")
            }
        }
    }
}

enum WriterError: LocalizedError {
    case notStarted
    case noFrames

    var errorDescription: String? {
        switch self {
        case .notStarted: return "写入器未启动"
        case .noFrames: return "未捕获到任何帧（画面静止且为可变帧率时可尝试固定帧率）"
        }
    }
}
