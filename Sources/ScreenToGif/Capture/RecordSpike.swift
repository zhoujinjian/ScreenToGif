import Foundation
import AppKit

/// 端到端无人值守验证（里程碑 D–G 闭环）：
/// 固定区域录制 N 秒 → 产出工程 → 直接导出 GIF。
/// 用法：ScreenToGif --record-spike [秒数=3]
enum RecordSpike {
    static func run() -> Int32 {
        let seconds: Int
        if let idx = CommandLine.arguments.firstIndex(of: "--record-spike"),
           idx + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[idx + 1]) {
            seconds = min(max(n, 1), 30)
        } else {
            seconds = 3
        }

        print("════ 端到端录制验证（\(seconds)s）════")

        guard PermissionManager.hasScreenCapture() else {
            print("❌ 无屏幕录制权限")
            return 2
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task { @MainActor in
            do {
                guard let display = DisplayInfo.all().first else {
                    print("❌ 无显示器"); exitCode = 1; semaphore.signal(); return
                }
                // 屏幕中央 640×400 区域
                let size = CGSize(width: 640, height: 400)
                let rect = CGRect(
                    x: display.appKitFrame.midX - size.width / 2,
                    y: display.appKitFrame.midY - size.height / 2,
                    width: size.width, height: size.height
                )
                let region = CaptureRegion(rect: rect, displayID: display.displayID)
                print("区域: \(rect)")

                let recorder = ScreenRecorder(region: region, fps: 15, captureCursor: true, fixedRate: false)
                recorder.onFrame = { count in
                    print("  帧 #\(count)")
                }
                try await recorder.start()
                print("▶ 录制中（画面请变化：拖动鼠标/切窗口）…")

                // 用 RunLoop 泵送等待
                let deadline = Date().addingTimeInterval(TimeInterval(seconds))
                while Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
                }

                let project = try await recorder.stop()
                print("✅ 工程：\(project.frameCount) 帧，\(project.width)×\(project.height)，\(project.totalDurationMs)ms")
                print("   目录：\(project.url.path)")

                guard project.frameCount > 0 else {
                    print("❌ 0 帧（画面静止）"); exitCode = 3; semaphore.signal(); return
                }

                // 抽查首帧 PNG 有效
                let firstPng = project.url.appendingPathComponent(project.frames[0].path)
                let size1 = (try? FileManager.default.attributesOfItem(atPath: firstPng.path)[.size] as? Int) ?? 0
                print("✅ 首帧 PNG: \(firstPng.lastPathComponent) \(size1 ?? 0) 字节")
                if (size1 ?? 0) < 1000 { exitCode = 4 }

                // 导出 GIF
                let outURL = URL(fileURLWithPath: "/tmp/e2e-test.gif")
                try await ExportManager.export(project: project, to: outURL, options: .init()) { p in
                    if p.isDone { print("✅ GIF 导出完成: \(p.outputURL?.path ?? "")") }
                }
                let gifSize = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
                print("✅ GIF 大小: \(gifSize ?? 0) 字节")
                if (gifSize ?? 0) < 500 { exitCode = 5 }

                semaphore.signal()
            } catch {
                print("❌ 失败: \(error)")
                exitCode = 1
                semaphore.signal()
            }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(seconds + 30))
        while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return exitCode
    }
}
