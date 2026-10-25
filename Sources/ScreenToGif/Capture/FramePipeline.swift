import Foundation
import CoreVideo

/// 帧管线：sampleHandler 立即入队（有界），后台消费写盘。
/// 对标原版 BlockingCollection 生产者-消费者 + 背压丢帧（FrameSkipped）。
final class FramePipeline {
    struct PendingFrame {
        let pixelBuffer: CVPixelBuffer   // 已深拷贝
        let timestampMs: Int
        let cursorX: Int                 // 区域本地坐标（-1 = 未记录）
        let cursorY: Int
        let buttonClicked: MouseButtons
        let keys: [KeyGesture]
    }

    private var buffer: [PendingFrame] = []
    private let lock = NSLock()
    private let condition = NSCondition()
    /// 队列上限（背压：超出丢帧，调用方记录 droppedCount）。
    let capacity: Int
    private(set) var droppedCount = 0
    private var closed = false

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    /// 入队（capture 队列调用）。返回 false = 已满被丢。
    func enqueue(_ frame: PendingFrame) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return false }
        guard buffer.count < capacity else {
            droppedCount += 1
            return false
        }
        buffer.append(frame)
        condition.signal()
        return true
    }

    /// 阻塞取帧（writer 线程调用）；closed 且空时返回 nil。
    func dequeue() -> PendingFrame? {
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty && !closed {
            condition.wait()
        }
        guard !buffer.isEmpty else { return nil }
        return buffer.removeFirst()
    }

    /// 关闭（停止采集后调用）：唤醒消费者，排空余量。
    func close() {
        condition.lock()
        closed = true
        condition.unlock()
        condition.broadcast()
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    var pendingCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return buffer.count
    }
}
