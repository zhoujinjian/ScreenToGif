import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// GIF 导出编排：帧序列 → RGBA 像素 → 量化/LZW（GifFileWriter）→ 文件。
/// 支持进度回调与协作取消。
enum ExportManager {
    struct Options {
        var loopCount: Int = 0          // 0 = 无限
        var maxColors: Int = 256
        var quantizerName: String = "Octree"   // Octree / MedianCut / Grayscale
        var detectUnchanged: Bool = true
        var openInFinder: Bool = true
        var copyToClipboard: Bool = false
    }

    struct Progress {
        var frameIndex = 0
        var frameCount = 0
        var message = ""
        var isDone = false
        var outputURL: URL?
    }

    /// 执行导出（后台线程）。onProgress 主线程回调。
    static func export(
        project: Project,
        to url: URL,
        options: Options,
        onProgress: @escaping (Progress) -> Void
    ) async throws {
        guard !project.frames.isEmpty else {
            throw ExportError.noFrames
        }

        let frames = project.frames
        let total = frames.count

        try? FileManager.default.removeItem(at: url)

        let writer = GifFileWriter(width: project.width, height: project.height, loopCount: options.loopCount)
        writer.maximumColorCount = options.maxColors
        // 每帧独立量化（局部色表，原版 C# GifFile 默认）：全局表模式下后续帧只能
        // 就近映射首帧没有的颜色，录制中后段出现的新颜色（弹窗/高亮）会明显失真。
        writer.transparentColor = options.detectUnchanged ? GifColor(255, 0, 255) : nil
        switch options.quantizerName {
        case "MedianCut":
            writer.quantizerFactory = { MedianCutQuantizer() }
        default:
            writer.quantizerFactory = { OctreeQuantizer() }
        }

        var previousPixels: [UInt8]? = nil
        // 与前一帧完全相同的帧不单独写出，其延迟累积给下一变化帧（原版语义，
        // 减少空帧并让播放节奏与真实时间一致）。
        var carriedDelayMs = 0

        for (i, frame) in frames.enumerated() {
            try Task.checkCancellation()

            let fileURL = project.url.appendingPathComponent(frame.path)
            guard let image = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: frame.path),
                  let pixels = rgbaPixels(from: image)
            else {
                throw ExportError.frameReadFailed(path: fileURL.lastPathComponent)
            }

            let frameDelay = max(frame.delay, Constants.minimumGifFrameDelayMs) + carriedDelayMs

            if options.detectUnchanged, let prev = previousPixels {
                // 未变更像素 → 透明（alpha=0：量化器把透明像素映射到色表末位洋红槽；
                // 若用不透明洋红，洋红会作为实色参与量化并污染统计）
                let result = try UnchangedPixelCut.paintUnchanged(
                    previous: prev, current: pixels,
                    width: image.width, height: image.height,
                    transparent: RgbaColor(255, 0, 255, 0)
                )
                guard result.changed else {
                    // 完全相同帧：并入延迟，不写出
                    carriedDelayMs = frameDelay
                    previousPixels = pixels
                    continue
                }
                try writer.appendFrame(pixels: result.pixels, delayMs: frameDelay)
            } else {
                try writer.appendFrame(pixels: pixels, delayMs: frameDelay)
            }
            carriedDelayMs = 0
            previousPixels = pixels

            await MainActor.run {
                onProgress(Progress(frameIndex: i + 1, frameCount: total, message: "编码帧 \(i+1)/\(total)"))
            }
        }

        let data = try writer.finish()
        try data.write(to: url, options: .atomic)

        await MainActor.run {
            onProgress(Progress(frameIndex: total, frameCount: total,
                                message: "完成", isDone: true, outputURL: url))
        }

        // 导出后动作
        if options.openInFinder {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        if options.copyToClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        }
        Log.export.info("GIF 导出完成 frames=\(total) size=\(data.count)B → \(url.path)")
    }

    /// CGImage → RGBA8 字节（预乘解除）。
    static func rgbaPixels(from image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
}

enum ExportError: LocalizedError {
    case noFrames
    case frameReadFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .noFrames: return "没有可导出的帧"
        case .frameReadFailed(let path): return "帧读取失败：\(path)"
        }
    }
}
