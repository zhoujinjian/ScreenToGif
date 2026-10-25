import AppKit
import CoreGraphics
import ImageIO

/// 帧缩略图提供器：ImageIO 直接从 PNG 降采样解码 + NSCache LRU。
final class FrameThumbnailProvider {
    static let shared = FrameThumbnailProvider()

    private let cache: NSCache<NSString, NSImage>
    /// 最大缓存缩略图数。
    private let capacity = 500
    private var sizeCache: [String: CGSize] = [:]   // 相对路径 → 帧原始尺寸

    init() {
        cache = NSCache()
        cache.countLimit = capacity
    }

    /// 获取缩略图（项目目录 + 帧文件名 → 降采样 NSImage）。
    func thumbnail(projectURL: URL, framePath: String, maxPixel: CGFloat = 80) -> NSImage? {
        let key = "\(projectURL.path)/\(framePath)@\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let fileURL = projectURL.appendingPathComponent(framePath)
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// 帧原始尺寸（带缓存；读 PNG 头不解码全图）。
    func imageSize(projectURL: URL, framePath: String) -> CGSize? {
        if let hit = sizeCache[framePath] { return hit }
        let fileURL = projectURL.appendingPathComponent(framePath)
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let size = CGSize(width: w, height: h)
        sizeCache[framePath] = size
        return size
    }

    /// 全尺寸帧（预览用；直接解码）。
    func fullImage(projectURL: URL, framePath: String) -> CGImage? {
        let fileURL = projectURL.appendingPathComponent(framePath)
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func clearCaches() {
        cache.removeAllObjects()
        sizeCache.removeAll()
    }
}
