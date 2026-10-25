import Foundation
import AppKit
import QuartzCore

/// 播放引擎：CADisplayLink 驱动，按每帧 Delay 推进 + 落后丢帧补偿（复刻原版 PreviewLoop 语义）。
/// 时钟可注入（自测用）。
@Observable
final class PlaybackEngine {
    /// 每帧 Delay 提供器（ms）。
    private let delayProvider: (Int) -> Int
    private let frameCount: () -> Int
    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    var loop = true

    /// 到点回调（主线程）：通知 UI 切帧。
    var onFrame: ((Int) -> Void)?
    var onEnd: (() -> Void)?

    /// 剩余延迟（ms，本帧尚未播完的部分）。
    private var remainingDelayMs = 0
    private var lastTickMs = 0
    private var displayLinkTimer: Timer?
    private let clock: () -> Int

    init(frameCount: @escaping () -> Int, delayProvider: @escaping (Int) -> Int, clock: @escaping () -> Int = { Int(ProcessInfo.processInfo.systemUptime * 1000) }) {
        self.frameCount = frameCount
        self.delayProvider = delayProvider
        self.clock = clock
    }

    // MARK: - 控制

    func play() {
        guard !isPlaying, frameCount() > 1 else { return }
        isPlaying = true
        if remainingDelayMs <= 0 {
            remainingDelayMs = max(delayProvider(currentIndex), 1)
        }
        lastTickMs = clock()
        installDisplayLink()
    }

    func pause() {
        isPlaying = false
        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    /// 跳到指定帧（重置本帧延迟）。
    func seek(to index: Int) {
        currentIndex = min(max(0, index), max(0, frameCount() - 1))
        remainingDelayMs = max(delayProvider(currentIndex), 1)
        onFrame?(currentIndex)
    }

    func stepForward() {
        pause()
        seek(to: currentIndex + 1)
    }

    func stepBackward() {
        pause()
        seek(to: currentIndex - 1)
    }

    /// 重播（回第一帧）。
    func rewind() {
        seek(to: 0)
    }

    // MARK: - 驱动（macOS 无 CADisplayLink，用主线程 30Hz Timer + 注入时钟推进）

    private func installDisplayLink() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayLinkTimer = timer
    }

    private func tick() {
        guard isPlaying else { return }
        let now = clock()
        let elapsed = now - lastTickMs
        lastTickMs = now
        remainingDelayMs -= elapsed

        // 落后超过一个帧间隔：跳帧补偿（不追赶渲染）
        while remainingDelayMs <= 0 {
            let next = currentIndex + 1
            if next >= frameCount() {
                if loop {
                    currentIndex = 0
                    onFrame?(0)
                    remainingDelayMs = max(delayProvider(0), 1)
                    break
                } else {
                    pause()
                    onEnd?()
                    return
                }
            }
            currentIndex = next
            remainingDelayMs += max(delayProvider(next), 1)
            onFrame?(next)
        }
    }
}
