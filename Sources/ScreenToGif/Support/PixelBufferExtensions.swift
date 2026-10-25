import CoreGraphics
import CoreVideo
import ImageIO

extension CVPixelBuffer {
    /// 深拷贝像素（IOSurface 在下一帧到来前失效，sampleHandler 内必须立即拷贝）。
    static func deepCopy(from source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)

        var copy: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format,
            nil, &copy
        )
        guard status == kCVReturnSuccess, let dest = copy else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dest)
        else { return nil }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dest)
        let bytesPerPixel = 4
        let heightInPixels = CVPixelBufferGetHeight(source)

        if srcBytesPerRow == dstBytesPerRow {
            memcpy(dstBase, srcBase, srcBytesPerRow * heightInPixels)
        } else {
            for row in 0..<heightInPixels {
                let src = srcBase.advanced(by: row * srcBytesPerRow)
                let dst = dstBase.advanced(by: row * dstBytesPerRow)
                memcpy(dst, src, width * bytesPerPixel)
            }
        }
        return dest
    }

    /// 转为 CGImage（BGRA → CGContext 位图）。
    var cgImage: CGImage? {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)

        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(self) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(self)
        let context = CGContext(
            data: base,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return context?.makeImage()
    }

    /// 写 PNG 到指定 URL。
    func writePNG(to url: URL) throws {
        guard let image = cgImage else {
            throw NSError(domain: "ScreenToGif.CVPixelBuffer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "像素缓冲转 CGImage 失败"])
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "ScreenToGif.CVPixelBuffer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "创建 PNG 目的地失败"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ScreenToGif.CVPixelBuffer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PNG 写入失败"])
        }
    }
}
