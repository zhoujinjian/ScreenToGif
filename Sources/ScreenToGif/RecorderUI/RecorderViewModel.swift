import Foundation
import Observation
import AppKit

/// 录制流程状态机（启动器点「录屏」→ 选区 → armed → recording ⇄ paused → editor/discarded）。
@Observable
final class RecorderViewModel {
    enum State: Equatable {
        case idle
        case selecting
        case armed
        case recording
        case paused
        case processing
    }

    private(set) var state: State = .idle
    private(set) var frameCount = 0
    private(set) var elapsedMs = 0
    private(set) var actualFps: Double = 0
    private(set) var regionSize: CGSize = .zero
    var fps: Int = UserSettings.shared.fps {
        didSet { if fps != oldValue { applyFps() } }
    }

    private var recorder: ScreenRecorder?
    private var panel: RecorderPanel?
    private let border = RecordingBorder()
    private var ticker: Timer?

    // MARK: - 流程入口

    func beginFlow() {
        guard state == .idle else { return }
        state = .selecting
        AppState.shared.isRecordingActive = true
        // 录屏期间隐藏启动器，避免录进画面（取消/丢弃后由 reset 恢复）
        WindowManager.shared.hideLauncher()

        RegionSelectController.shared.begin { [weak self] region in
            guard let self else { return }
            guard let region else {
                self.reset()
                return
            }
            self.start(region: region)
        }
    }

    private func start(region: CaptureRegion) {
        Log.app.notice("录制启动：region=(\(Int(region.rect.minX)),\(Int(region.rect.minY)),\(Int(region.rect.width))×\(Int(region.rect.height))) display=\(region.displayID) fps=\(self.fps)")
        regionSize = region.size
        frameCount = 0
        elapsedMs = 0
        actualFps = 0
        state = .armed

        let recorder = ScreenRecorder(
            region: region,
            fps: fps,
            captureCursor: UserSettings.shared.captureCursor,
            fixedRate: UserSettings.shared.fixedFrameRate
        )
        recorder.onFrame = { [weak self] count in
            self?.frameCount = count
        }
        recorder.onError = { [weak self] message in
            self?.fail(message: message)
        }
        self.recorder = recorder

        // 倒计时（原版 Pre-Start）
        let countdown = UserSettings.shared.preStartCountdown
        Task { @MainActor in
            var remaining = countdown
            while remaining > 0 {
                // 倒计时期间显示边框提示（简化：不做大数字覆盖）
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
            }
            do {
                try await recorder.start()
                Log.app.notice("录制已开始（倒计时 \(countdown)s 后）")
                self.state = .recording
                self.showPanel(region: region)
                self.border.show(region: region)
                self.startTicker()
            } catch {
                Log.app.error("录制启动失败：\(error.localizedDescription, privacy: .public)")
                self.fail(message: error.localizedDescription)
            }
        }
    }

    // MARK: - 控制

    func togglePauseResume() {
        guard let recorder else { return }
        switch state {
        case .recording:
            recorder.pause()
            state = .paused
        case .paused:
            recorder.resume()
            state = .recording
        case .armed:
            // armed 下点录制：立即开始（倒计时被跳过由 start 的 Task 处理，这里不重复）
            break
        default:
            break
        }
    }

    func stop() {
        guard state == .recording || state == .paused, let recorder else { return }
        state = .processing
        stopTicker()
        Task { @MainActor in
            do {
                let project = try await recorder.stop()
                self.teardownUI()
                self.state = .idle
                AppState.shared.isRecordingActive = false
                WindowManager.shared.showEditor(with: project)
            } catch {
                self.teardownUI()
                self.fail(message: error.localizedDescription, resetIdle: true)
            }
        }
    }

    func discard() {
        guard state != .idle, state != .processing else { return }
        if UserSettings.shared.discardConfirmation, state == .recording || state == .paused {
            let alert = NSAlert()
            alert.messageText = "丢弃录制？"
            alert.informativeText = "本次录制的内容将被删除。"
            alert.addButton(withTitle: "丢弃")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        stopTicker()
        let recorder = self.recorder
        panel?.orderOut(nil)
        border.remove()
        state = .processing
        Task { @MainActor in
            await recorder?.discard()
            self.reset()
        }
    }

    func snapshot() async throws {
        try await recorder?.snapshot()
    }

    func applyFps() {
        fps = min(max(1, fps), 60)
        UserSettings.shared.fps = fps
        UserSettings.shared.save()
        // 运行中改 FPS：P1 不支持热切换（需停止重开）；写设置供下次使用。
    }

    // MARK: - UI 刷新

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder, self.state == .recording || self.state == .paused else { return }
                self.elapsedMs = recorder.elapsedMs
                self.actualFps = recorder.actualFps
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func showPanel(region: CaptureRegion) {
        let panel = RecorderPanel(region: region, viewModel: self)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func teardownUI() {
        stopTicker()
        panel?.orderOut(nil)
        panel = nil
        border.remove()
    }

    private func reset() {
        teardownUI()
        recorder = nil
        state = .idle
        AppState.shared.isRecordingActive = false
        // 取消/丢弃：回到启动器
        WindowManager.shared.showLauncher()
    }

    private func fail(message: String, resetIdle: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "录制失败"
        alert.informativeText = message
        alert.runModal()
        if resetIdle {
            reset()
        } else {
            teardownUI()
            state = .idle
            AppState.shared.isRecordingActive = false
        }
    }

    // MARK: - 展示

    var elapsedText: String {
        let s = elapsedMs / 1000
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var actualFpsText: String {
        actualFps > 0 ? String(format: "%.1f", actualFps) : "—"
    }
}
