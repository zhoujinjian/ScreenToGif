import Foundation
import CoreMedia

/// 帧时钟：按时间戳计算每帧 Delay（固定/可变模式），复刻原版 Framerate 语义。
struct FrameClock {
    let fixedRate: Bool
    let fps: Int
    /// 固定模式下的帧间隔（ms）。
    let fixedIntervalMs: Int
    private(set) var lastTimestampMs: Int?

    init(fixedRate: Bool, fps: Int) {
        self.fixedRate = fixedRate
        self.fps = fps
        self.fixedIntervalMs = Int((1000.0 / Double(max(1, fps))).rounded())
    }

    /// 输入帧时间戳（ms，monotonic），输出该帧的 Delay（ms）。
    /// 固定模式：恒定 1000/fps（首帧同样）。
    /// 可变模式：真实流逝时间，clamp [10, 60000]（原版亦有最小延迟）。
    mutating func delay(forTimestampMs ts: Int) -> Int {
        defer { lastTimestampMs = ts }
        guard !fixedRate, let prev = lastTimestampMs else {
            return fixedIntervalMs
        }
        let elapsed = ts - prev
        return min(max(elapsed, 10), 60_000)
    }
}
