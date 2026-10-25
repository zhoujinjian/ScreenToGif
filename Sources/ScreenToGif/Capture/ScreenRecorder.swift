import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

/// SCK 流式屏幕录制器：管理 SCStream 生命周期，帧 → 深拷贝 → FramePipeline。
/// 对标原版 BaseCapture 家族（本机统一走 SCK，等效 Desktop Duplication 路线）。
final class ScreenRecorder: NSObject, SCStreamOutput {
    let region: CaptureRegion
    let fps: Int
    let captureCursor: Bool
    let fixedRate: Bool

    private var stream: SCStream?
    private let pipeline: FramePipeline
    private let writer: FrameWriter
    private let eventRecorder = EventRecorder()
    private var frameClock: FrameClock
    private let captureQueue = DispatchQueue(label: "com.screentogif.capture", qos: .userInitiated)
    private var startedAtMs: Int = 0
    private var pausedAtMs: Int?
    private var pausedAccumMs = 0
    private(set) var frameCount = 0
    /// 每帧回调（主线程，UI 刷新用）。
    var onFrame: ((Int) -> Void)?
    var onError: ((String) -> Void)?

    init(region: CaptureRegion, fps: Int, captureCursor: Bool, fixedRate: Bool) {
        self.region = region
        self.fps = fps
        self.captureCursor = captureCursor
        self.fixedRate = fixedRate
        self.pipeline = FramePipeline(capacity: 200)
        self.frameClock = FrameClock(fixedRate: fixedRate, fps: fps)
        self.writer = FrameWriter(pipeline: pipeline, region: region)
        super.init()
    }

    /// 当前已录时长（ms，不含暂停）。
    var elapsedMs: Int {
        guard startedAtMs > 0 else { return 0 }
        let now = pausedAtMs ?? nowMs()
        return max(0, now - startedAtMs - pausedAccumMs)
    }

    var actualFps: Double {
        guard elapsedMs > 300 else { return 0 }
        return Double(frameCount) / (Double(elapsedMs) / 1000.0)
    }

    // MARK: - 生命周期

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
            ?? content.displays.first
        else { throw RecorderError.noDisplay }

        guard let displayInfo = DisplayInfo.all().first(where: { $0.displayID == display.displayID }) else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        let local = ScreenMath.sckLocalRect(fromAppKitGlobal: region.rect, display: displayInfo)
        config.sourceRect = local
        config.width = Int(region.rect.width)
        config.height = Int(region.rect.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.queueDepth = 5
        config.showsCursor = captureCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream

        writer.begin()
        if UserSettings.shared.captureMouseClicks || UserSettings.shared.captureKeyStrokes {
            eventRecorder.start()
        }
        startedAtMs = nowMs()
        try await stream.startCapture()
        let rectDesc = String(describing: region.rect)
        let fpsValue = fps
        Log.capture.notice("录制开始 region=\(rectDesc, privacy: .public) fps=\(fpsValue, privacy: .public)")
    }

    func pause() {
        guard pausedAtMs == nil else { return }
        pausedAtMs = nowMs()
        let count = frameCount
        Log.capture.notice("录制暂停 frames=\(count, privacy: .public)")
    }

    func resume() {
        guard let at = pausedAtMs else { return }
        pausedAccumMs += nowMs() - at
        pausedAtMs = nil
        let count = frameCount
        Log.capture.notice("录制继续 frames=\(count, privacy: .public)")
    }

    var isPaused: Bool { pausedAtMs != nil }

    /// 手动快照（Manual 模式 / 快门按钮）：立即抓一帧入队。
    func snapshot() async throws {
        guard !isPaused else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { return }
        let displayInfo = DisplayInfo.all().first { $0.displayID == display.displayID }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        if let displayInfo {
            config.sourceRect = ScreenMath.sckLocalRect(fromAppKitGlobal: region.rect, display: displayInfo)
        }
        config.width = Int(region.rect.width)
        config.height = Int(region.rect.height)
        config.showsCursor = captureCursor
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // 快照走 SCScreenshotManager（CGImage），直接交给 writer。
        writer.appendSnapshot(image: image, timestampMs: nowMs() - startedAtMs - pausedAccumMs,
                              cursor: localCursor(), events: eventRecorder.drainEvents())
        frameCount += 1
        onFrame?(frameCount)
    }

    /// 停止并产出工程。返回写入的帧数。
    func stop() async throws -> Project {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        eventRecorder.stop()
        pipeline.close()
        let total = elapsedMs
        let count = frameCount
        let dropped = pipeline.droppedCount
        Log.capture.notice("录制停止 frames=\(count, privacy: .public) elapsed=\(total, privacy: .public)ms dropped=\(dropped, privacy: .public)")

        let project = try writer.finish(
            fps: fps, fixedRate: fixedRate,
            elapsedMs: total, dropped: pipeline.droppedCount
        )
        return project
    }

    /// 丢弃：停流 + 删项目目录。
    func discard() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        eventRecorder.stop()
        pipeline.close()
        writer.discard()
    }

    // MARK: - SCStreamOutput（captureQueue 线程）

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isPaused else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ts = nowMs() - startedAtMs - pausedAccumMs
        // 立即深拷贝（IOSurface 下帧失效）
        guard let copy = CVPixelBuffer.deepCopy(from: pixelBuffer) else { return }

        let cursor = localCursor()
        let events = eventRecorder.drainEvents()
        let ok = pipeline.enqueue(FramePipeline.PendingFrame(
            pixelBuffer: copy, timestampMs: ts,
            cursorX: cursor?.x ?? -1, cursorY: cursor?.y ?? -1,
            buttonClicked: events.button, keys: events.keys
        ))
        if ok {
            frameCount += 1
            let count = frameCount
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(count)
            }
        }
    }

    // MARK: - 工具

    private func nowMs() -> Int {
        Int(ProcessInfo.processInfo.systemUptime * 1000)
    }

    /// 当前光标在录制区内的本地坐标（无需权限的 NSEvent.mouseLocation；无障碍模式由 EventRecorder 提供更精确值）。
    private func localCursor() -> (x: Int, y: Int)? {
        let global = NSEvent.mouseLocation   // AppKit 全局
        let local = CGPoint(
            x: global.x - region.rect.minX,
            y: global.y - region.rect.minY
        )
        guard local.x >= 0, local.y >= 0,
              local.x < region.rect.width, local.y < region.rect.height else { return nil }
        return (Int(local.x), Int(region.rect.height - local.y))   // 转 GIF 图像坐标（左上原点）
    }
}

enum RecorderError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "未找到目标显示器"
        }
    }
}
