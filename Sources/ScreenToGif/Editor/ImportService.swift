import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 媒体导入：GIF / PNG / JPEG → 临时工程（帧序列）。
enum ImportService {
    /// 导入任意支持的媒体文件；失败返回 nil。
    @MainActor
    static func importMedia(_ url: URL) async -> Project? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "gif":
            return importGif(url)
        case "png", "jpg", "jpeg", "bmp", "tiff", "webp":
            return importImage(url)
        default:
            // 尝试按 GIF 打开（某些来源无扩展名）
            if importGif(url) != nil { return importGif(url) }
            return importImage(url)
        }
    }

    // MARK: - GIF

    static func importGif(_ url: URL) -> Project? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }

        // 先取第一帧尺寸
        guard let firstProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = firstProps[kCGImagePropertyPixelWidth] as? Int,
              let h = firstProps[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let project = Project(width: w, height: h)
        try? FileManager.default.createDirectory(at: project.url, withIntermediateDirectories: true)

        let writeOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            // GIF 帧可能只含局部更新：与前一帧合成完整帧
            let composited = compositeIfNeeded(image, previousFullSize: (w, h))
            let name = "\(i).png"
            let dstURL = project.url.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(dstURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, composited, writeOpts as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }

            // 每帧延迟（Unclamped 优先；0 兜底 100ms，与浏览器一致）
            var delayMs = 100
            if let frameProps = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               let gifProps = frameProps[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                if let unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
                    delayMs = Int((unclamped * 1000).rounded())
                } else if let clamped = gifProps[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
                    delayMs = Int((clamped * 1000).rounded())
                }
            }
            delayMs = max(delayMs, 20)
            project.frames.append(FrameInfo(path: name, delay: delayMs))
        }

        guard !project.frames.isEmpty else {
            project.deleteFromDisk()
            return nil
        }
        project.reindex()
        try? project.save()
        return project
    }

    /// GIF 局部帧补全：小于画布的帧绘制到全尺寸透明画布（局部更新帧需底图，P1 用透明底，浏览器多为全帧）。
    private static func compositeIfNeeded(_ image: CGImage, previousFullSize: (Int, Int)) -> CGImage {
        guard image.width != previousFullSize.0 || image.height != previousFullSize.1 else { return image }
        guard let ctx = CGContext(
            data: nil, width: previousFullSize.0, height: previousFullSize.1,
            bitsPerComponent: 8, bytesPerRow: previousFullSize.0 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: previousFullSize.0, height: previousFullSize.1))
        return ctx.makeImage() ?? image
    }

    // MARK: - 静态图

    static func importImage(_ url: URL) -> Project? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let project = Project(width: image.width, height: image.height)
        try? FileManager.default.createDirectory(at: project.url, withIntermediateDirectories: true)
        let name = "0.png"
        guard let dest = CGImageDestinationCreateWithURL(
            project.url.appendingPathComponent(name) as CFURL,
            UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        project.frames = [FrameInfo(path: name, delay: 500)]
        project.reindex()
        try? project.save()
        return project
    }
}
