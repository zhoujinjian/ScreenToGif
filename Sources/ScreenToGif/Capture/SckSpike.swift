import AppKit
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 里程碑 C 尖刺验证：
/// 1) SCScreenshotManager 单帧截图（全屏 + sourceRect 区域）→ 校准坐标语义
/// 2) SCStream 流式采集 5 秒 → 写 PNG 压测吞吐
/// 返回退出码。用法：ScreenToGif --sck-spike
enum SckSpike {
    static func run() -> Int32 {
        print("════ SCK 尖刺验证 ════")

        guard PermissionManager.hasScreenCapture() || PermissionManager.requestScreenCapture() else {
            // CLI 模式：不弹模态窗，打印指引退出（授予后需重启应用生效）。
            print("⏳ 已请求屏幕录制权限（系统弹窗）。")
            print("   请在 系统设置 → 隐私与安全性 → 屏幕录制 勾选 ScreenToGif，")
            print("   然后重新运行 --sck-spike。")
            return 2
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        // 注意：Task { @MainActor } 需要主线程跑 RunLoop，不能直接 semaphore.wait 阻塞（会死锁）。
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    print("❌ 未发现显示器")
                    exitCode = 1
                    semaphore.signal()
                    return
                }
                guard let displayInfo = DisplayInfo.all().first(where: { $0.displayID == display.displayID }) else {
                    print("❌ NSScreen 与 SCDisplay 无法对齐 displayID=\(display.displayID)")
                    exitCode = 1
                    semaphore.signal()
                    return
                }
                print("显示器: \(display.displayID) CG frame=\(displayInfo.cgFrame) scale=\(displayInfo.scale)")

                // ── 1. 全屏单帧 ──
                let fullFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                var fullConfig = SCStreamConfiguration()
                fullConfig.width = Int(displayInfo.appKitFrame.width)
                fullConfig.height = Int(displayInfo.appKitFrame.height)
                fullConfig.showsCursor = true
                let t0 = Date()
                let fullImage = try await SCScreenshotManager.captureImage(contentFilter: fullFilter, configuration: fullConfig)
                let fullUrl = URL(fileURLWithPath: "/tmp/sck-full.png")
                saveCGImage(fullImage, to: fullUrl)
                print("✅ 全屏截图 \(fullImage.width)×\(fullImage.height) → /tmp/sck-full.png (\(ms(t0))ms)")

                // ── 2. 区域单帧（sourceRect 语义自动校准）──
                // 探针取屏幕偏上位置（非对称，避免两种坐标假设在屏幕中心巧合等值）：
                // AppKit 全局 rect → sckLocalRect → captureImage → 与全屏图两种假设裁剪各算 MAE。
                let dFrame = displayInfo.appKitFrame
                let probe = CGRect(
                    x: dFrame.minX + 150,
                    y: dFrame.minY + dFrame.height * 0.6,
                    width: 400, height: 300
                )
                let local = ScreenMath.sckLocalRect(fromAppKitGlobal: probe, display: displayInfo)
                var rectConfig = SCStreamConfiguration()
                rectConfig.sourceRect = local
                rectConfig.width = 400
                rectConfig.height = 300
                rectConfig.showsCursor = false
                let t1 = Date()
                let rectImage = try await SCScreenshotManager.captureImage(contentFilter: fullFilter, configuration: rectConfig)
                let rectUrl = URL(fileURLWithPath: "/tmp/sck-rect.png")
                saveCGImage(rectImage, to: rectUrl)
                print("✅ 区域截图 sourceRect=\(local) → \(rectImage.width)×\(rectImage.height) → /tmp/sck-rect.png (\(ms(t1))ms)")

                // 自动校验：全屏图按"左上原点"假设裁剪应与区域图几乎一致（MAE≈0）
                if let cropTopLeft = fullImage.cropping(to: local),
                   let maeTopLeft = mae(cropTopLeft, rectImage) {
                    let legacy = CGRect(x: local.minX, y: dFrame.height - local.maxY, width: 400, height: 300)
                    let maeLegacyStr: String
                    if let cropLegacy = fullImage.cropping(to: legacy), let m = mae(cropLegacy, rectImage) {
                        maeLegacyStr = String(format: "%.2f", m)
                    } else {
                        maeLegacyStr = "裁剪越界"
                    }
                    print("   坐标校验 MAE：左上原点=\(String(format: "%.2f", maeTopLeft))（应为≈0）  旧左下假设=\(maeLegacyStr)（应显著大）")
                    if maeTopLeft > 2.0 { exitCode = 4 }
                } else {
                    print("⚠️ 坐标校验跳过：图像尺寸不匹配")
                }

                // ── 3. 流式采集 5 秒（15fps 目标）写 PNG ──
                let framesDir = URL(fileURLWithPath: "/tmp/sck-spike-frames", isDirectory: true)
                try? FileManager.default.removeItem(at: framesDir)
                try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
                let stream = SCStream(filter: fullFilter, configuration: rectStreamConfig(for: local), delegate: nil)
                let collector = SpikeFrameCollector(output: framesDir)
                try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: nil)
                try await stream.startCapture()
                print("▶ 流采集 5s @ 目标15fps（区域 \(local)）…")

                var frameCount = 0
                for _ in 0..<50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    frameCount = collector.count
                }
                try await stream.stopCapture()
                let stats = collector.stats
                print("✅ 流采集完成：\(collector.count) 帧，PNG 落盘 \(stats.succeeded) 张，失败 \(stats.failed) 张")
                print("   帧目录: /tmp/sck-spike-frames")
                if stats.failed > 0 { exitCode = 3 }
                semaphore.signal()
            } catch {
                print("❌ 尖刺失败: \(error)")
                exitCode = 1
                semaphore.signal()
            }
        }
        // 泵送主 RunLoop 直至 Task 完成（超时 120s）
        let deadline = Date().addingTimeInterval(120)
        while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return exitCode
    }

    private static func ms(_ since: Date) -> Int {
        Int(Date().timeIntervalSince(since) * 1000)
    }

    /// 两幅同尺寸图像的平均绝对误差（RGB 通道，0=逐字节相同）。
    /// 先统一绘制到 RGBA8 上下文，避免原始字节 bytesPerRow 对齐差异干扰。
    static func mae(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        func pixels(_ img: CGImage) -> [UInt8]? {
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(
                data: &buf, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return nil }
        var total = 0.0
        var n = 0
        for i in stride(from: 0, to: pa.count - 3, by: 4) {
            total += abs(Double(pa[i]) - Double(pb[i]))
            total += abs(Double(pa[i + 1]) - Double(pb[i + 1]))
            total += abs(Double(pa[i + 2]) - Double(pb[i + 2]))
            n += 3
        }
        return n > 0 ? total / Double(n) : nil
    }

    private static func rectStreamConfig(for local: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int(local.width)
        config.height = Int(local.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 5
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    private static func saveCGImage(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// 流帧收集器：立即深拷贝像素 → 后台写 PNG。
private final class SpikeFrameCollector: NSObject, SCStreamOutput {
    let output: URL
    private(set) var count = 0
    private let queue = DispatchQueue(label: "spike.io", qos: .userInitiated)
    private var succeededCount = 0
    private var failedCount = 0

    init(output: URL) {
        self.output = output
        super.init()
    }

    /// 读取最终统计（主线程调用；阻塞到队列排空）。
    var stats: (succeeded: Int, failed: Int) {
        queue.sync { (succeededCount, failedCount) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        count += 1
        // 立即深拷贝（IOSurface 下帧失效）
        guard let copy = CVPixelBuffer.deepCopy(from: pixelBuffer) else { return }
        let index = count
        queue.async { [self] in
            // 已在 spike.io 串行队列上，直接改计数（勿对本队列再 queue.sync —— libdispatch 禁止）
            let url = output.appendingPathComponent("\(String(format: "%04d", index)).png")
            do {
                try copy.writePNG(to: url)
                succeededCount += 1
            } catch {
                failedCount += 1
            }
        }
    }
}
