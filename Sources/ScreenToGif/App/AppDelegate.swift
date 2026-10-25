import AppKit
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("启动完成 version=0.1.0")

        // 单实例自检：同 bundle ID 已在运行时激活旧实例并退出（LaunchServices 一般已阻止双开，兜底）。
        if let current = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: current)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let first = others.first {
                Log.app.info("已有实例运行 pid=\(first.processIdentifier)，激活并退出")
                first.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
        }

        // --selection-spike：无人值守选区链路验证（弹覆盖窗 → 外部注入 Esc → 应取消退出）。
        // 8 秒兜底自杀，验证过程绝不锁屏。
        if CommandLine.arguments.contains("--selection-spike") {
            runSelectionSpike()
            return
        }

        // --export-spike：加载最近工程真实导出 GIF，机器验证帧数/延迟/颜色保真。
        // 结果写 /tmp/screentogif-export-spike.log，产物 /tmp/export-spike.gif。
        if CommandLine.arguments.contains("--export-spike") {
            runExportSpike()
            return
        }

        // --reopen-spike：窗口关闭→重开回归（修复 releasedWhenClosed 过度释放僵尸窗口）。
        // 修复前该序列在第二次 showLauncher 处 SIGSEGV。
        if CommandLine.arguments.contains("--reopen-spike") {
            runReopenSpike()
            return
        }

        // --coords-spike：无 UI 坐标校验（探针区域截图 vs 全屏裁剪 MAE），结果写
        // /tmp/screentogif-coords-spike.log。
        if CommandLine.arguments.contains("--coords-spike") {
            FileManager.default.createFile(atPath: "/tmp/screentogif-coords-spike.log", contents: nil)
            Task { @MainActor in
                let mae = await Self.verifySourceRectMath()
                let line = "COORDS_MAE=\(mae.map { String(format: "%.2f", $0) } ?? "验证失败")"
                print("COORDS_SPIKE " + line)
                let url = URL(fileURLWithPath: "/tmp/screentogif-coords-spike.log")
                if let handle = try? FileHandle(forWritingTo: url),
                   let data = (line + "\n").data(using: .utf8) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
                exit(mae != nil && mae! < 2.0 ? 0 : 5)
            }
            return
        }

        statusItem.activate()
        WindowManager.shared.showLauncher()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 复刻原版：关窗驻留托盘。
        false
    }

    // MARK: - 导出质量验证

    private func runExportSpike() {
        let logURL = URL(fileURLWithPath: "/tmp/screentogif-export-spike.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        func log(_ line: String) {
            print("EXPORT_SPIKE " + line)
            if let handle = try? FileHandle(forWritingTo: logURL),
               let data = (line + "\n").data(using: .utf8) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
        Task { @MainActor in
            defer { exit(0) }
            // 最近修改的工程目录
            let root = Constants.recordingRoot
            guard let dirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { log("RESULT=fail 工程根目录读取失败"); return }
            let sorted = dirs
                .filter { $0.hasDirectoryPath }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
            guard let recent = sorted.first,
                  let project = try? Project.load(from: recent) else {
                log("RESULT=fail 无可加载工程"); return
            }
            log("PROJECT frames=\(project.frameCount) size=\(project.width)×\(project.height)")

            let out = URL(fileURLWithPath: "/tmp/export-spike.gif")
            do {
                try await ExportManager.export(
                    project: project, to: out,
                    options: .init(openInFinder: false, copyToClipboard: false)
                ) { _ in }
            } catch {
                log("RESULT=fail 导出异常：\(error.localizedDescription)"); return
            }

            // 机器验证
            guard let data = try? Data(contentsOf: out),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                log("RESULT=fail 产物读取失败"); return
            }
            let gifFrames = CGImageSourceGetCount(source)
            log("GIF frames=\(gifFrames) bytes=\(data.count)")

            // 首帧颜色保真：GIF 帧 0 vs 工程 0.png 的 MAE（量化有损但应小）
            if let gif0 = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let png0 = CGImageSourceCreateWithURL(project.url.appendingPathComponent("0.png") as CFURL, nil),
               let png0Img = CGImageSourceCreateImageAtIndex(png0, 0, nil) {
                if let mae = SckSpike.mae(gif0, png0Img) {
                    log("FIRST_FRAME_MAE=\(String(format: "%.2f", mae))（≤8 为颜色保真良好）")
                }
            }

            // 中段帧保真（有新内容变化的位置更能暴露全局表色偏）。
            // 相同帧合并会错位 GIF 与工程的帧索引，仅未合并（帧数相等）时对比。
            let midIndex = project.frameCount / 2
            if midIndex > 0, gifFrames == project.frameCount,
               let gifMid = CGImageSourceCreateImageAtIndex(source, min(midIndex, gifFrames - 1), nil),
               let pngSrc = CGImageSourceCreateWithURL(project.url.appendingPathComponent(project.frames[midIndex].path) as CFURL, nil),
               let pngMid = CGImageSourceCreateImageAtIndex(pngSrc, 0, nil) {
                if let mae = SckSpike.mae(gifMid, pngMid) {
                    log("MID_FRAME(\(midIndex))_MAE=\(String(format: "%.2f", mae))（≤8 为颜色保真良好）")
                }
            }
            log("RESULT=done")
        }
    }

    // MARK: - 窗口重开回归验证

    /// 复现用户点 X 关窗 → 再点 Dock/状态栏重开的序列（窗口闪现两下后自动退出）。
    private func runReopenSpike() {
        let url = URL(fileURLWithPath: "/tmp/screentogif-reopen-spike.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        func log(_ line: String) {
            print("REOPEN_SPIKE " + line)
            if let handle = try? FileHandle(forWritingTo: url),
               let data = (line + "\n").data(using: .utf8) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
        log("STARTED")
        WindowManager.shared.showLauncher()
        log("LAUNCHER_SHOWN_1")
        WindowManager.shared.debugCloseAllWindows()
        log("CLOSED")
        WindowManager.shared.showLauncher()          // 修复前：僵尸窗口 → SIGSEGV
        log("LAUNCHER_SHOWN_2")
        WindowManager.shared.showEditor(with: nil)
        WindowManager.shared.debugCloseAllWindows()
        WindowManager.shared.showEditor(with: nil)
        log("EDITOR_REOPEN_OK")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WindowManager.shared.debugCloseAllWindows()
            log("RESULT=pass")
            exit(0)
        }
    }

    // MARK: - 选区链路无人值守验证

    /// 确认选区后直接驱动 ScreenRecorder（复现用户 Enter → 录制启动链路）。
    private func runRecordingSpike(region: CaptureRegion) {
        Task { @MainActor in
            let mae = await Self.verifySourceRectMath()
            spikeLog("COORDS_MAE=\(mae.map { String(format: "%.2f", $0) } ?? "验证失败")")
        }
        let recorder = ScreenRecorder(
            region: region, fps: 15,
            captureCursor: UserSettings.shared.captureCursor,
            fixedRate: UserSettings.shared.fixedFrameRate
        )
        recorder.onFrame = { count in
            self.spikeLog("FRAME count=\(count)")
        }
        recorder.onError = { message in
            self.spikeLog("REC_ERROR \(message)")
        }
        Task { @MainActor in
            do {
                try await recorder.start()
                self.spikeLog("REC_STARTED")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let project = try await recorder.stop()
                self.spikeLog("REC_STOPPED frames=\(project.frameCount)")
                exit(0)
            } catch {
                self.spikeLog("REC_FAILED \(error.localizedDescription)")
                exit(4)
            }
        }
    }

    /// 坐标校验：探针区域（AppKit 偏上位置）经 sckLocalRect 转换后截图，
    /// 与全屏图按"左上原点"裁剪对比 MAE（≈0 = sourceRect 语义正确）。
    static func verifySourceRectMath() async -> Double? {
        func diag(_ step: String) {
            Log.app.error("coords-spike 诊断：\(step, privacy: .public)")
            let url = URL(fileURLWithPath: "/tmp/screentogif-coords-spike.log")
            if let handle = try? FileHandle(forWritingTo: url),
               let data = ("STEP " + step + "\n").data(using: .utf8) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            diag("SCShareableContent 抛错：\(error.localizedDescription)"); return nil
        }
        guard let display = content.displays.first else {
            diag("displays 为空（count=\(content.displays.count)）"); return nil
        }
        guard let info = DisplayInfo.all().first(where: { $0.displayID == display.displayID }) else {
            diag("NSScreen 与 SCDisplay 无法对齐 displayID=\(display.displayID)"); return nil
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        var fullCfg = SCStreamConfiguration()
        fullCfg.width = Int(info.appKitFrame.width)
        fullCfg.height = Int(info.appKitFrame.height)
        let full: CGImage
        do {
            full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: fullCfg)
        } catch {
            diag("全屏截图失败：\(error.localizedDescription)"); return nil
        }

        let probe = CGRect(
            x: info.appKitFrame.minX + 150,
            y: info.appKitFrame.minY + info.appKitFrame.height * 0.6,   // 偏上（AppKit 大 y），非对称可区分两种假设
            width: 400, height: 300
        )
        let local = ScreenMath.sckLocalRect(fromAppKitGlobal: probe, display: info)
        var rectCfg = SCStreamConfiguration()
        rectCfg.sourceRect = local
        rectCfg.width = 400
        rectCfg.height = 300
        let rectImg: CGImage
        do {
            rectImg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: rectCfg)
        } catch {
            diag("探针区域截图失败：\(error.localizedDescription) local=\(local)"); return nil
        }
        guard let crop = full.cropping(to: local) else {
            diag("全屏图裁剪失败 local=\(local) 全屏=\(full.width)×\(full.height)"); return nil
        }
        guard let value = SckSpike.mae(crop, rectImg) else {
            diag("MAE 计算失败 尺寸 crop=\(crop.width)×\(crop.height) rect=\(rectImg.width)×\(rectImg.height)"); return nil
        }
        diag("MAE=\(value)")
        return value
    }

    /// 结果追加写入 /tmp/screentogif-selection-spike.log（open 启动无法捕获 stdout，走文件通道）。
    private func spikeLog(_ line: String) {
        print("SELECTION_SPIKE " + line)
        let url = URL(fileURLWithPath: "/tmp/screentogif-selection-spike.log")
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func runSelectionSpike() {
        FileManager.default.createFile(
            atPath: "/tmp/screentogif-selection-spike.log",
            contents: nil
        )
        spikeLog("STARTED")

        RegionSelectController.shared.begin { region in
            guard let region else {
                self.spikeLog("RESULT=cancelled appActive=\(NSApp.isActive)")
                exit(0)
            }
            self.spikeLog("RESULT=confirmed — 进入真实录制链路")
            self.runRecordingSpike(region: region)
        }

        // 覆盖窗弹出稳定后记录 key window 状态（根修验证点）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let key = RegionSelectController.shared.debugOverlayIsKeyWindow
            self.spikeLog("KEYWINDOW=\(key.map(String.init) ?? "nil")")
        }
        // 全链路验证：合成拖拽选区 → 合成 Enter（走完整 AppKit 分发）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let ok = RegionSelectController.shared.debugSynthesizeDragSelection()
            self.spikeLog("SYNTH_DRAG hasValidSelection=\(ok)")
            // 转换链交叉验证：view 的 convertToGlobal vs 独立数学
            let mathOK = RegionSelectController.shared.debugVerifyConversionMath()
            self.spikeLog("GLOBAL_MATH=\(mathOK ? "pass" : "FAIL")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            self.spikeLog("SYNTH_ENTER")
            RegionSelectController.shared.debugSendEnterKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Enter 后覆盖窗应已撤掉（completion 已触发）
                let gone = RegionSelectController.shared.debugOverlayIsKeyWindow == nil
                    || RegionSelectController.shared.debugOverlayIsKeyWindow == false
                self.spikeLog("POST_ENTER overlaysGone=\(gone)")
            }
        }
        // 兜底：任何异常 8 秒自动退出，验证流程绝不锁屏
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            self.spikeLog("RESULT=timeout")
            exit(3)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点 Dock 图标重新显示启动器。
        WindowManager.shared.showLauncher()
        return true
    }
}
