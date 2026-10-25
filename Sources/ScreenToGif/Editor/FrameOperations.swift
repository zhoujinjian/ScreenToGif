import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// 帧操作（对标原版编辑器 Edit 菜单全组）。全部通过 EditorViewModel 的 undo 检查点包裹。
enum FrameOperations {

    // MARK: - 删除族

    /// 删除选中帧（无选中 = 当前帧）。
    static func deleteSelected(_ vm: EditorViewModel) {
        let indices = vm.effectiveSelection
        guard !indices.isEmpty, let project = vm.project else { return }
        vm.pushUndoCheckpoint()
        project.frames = project.frames.enumerated()
            .filter { !indices.contains($0.offset) }
            .map(\.element)
        project.reindex()
        vm.afterMutation()
    }

    /// 删除指定帧之前的所有帧。
    static func deleteBefore(_ vm: EditorViewModel) {
        guard let project = vm.project, vm.currentIndex > 0 else { return }
        vm.pushUndoCheckpoint()
        project.frames.removeFirst(vm.currentIndex)
        project.reindex()
        vm.afterMutation()
    }

    /// 删除指定帧之后的所有帧。
    static func deleteAfter(_ vm: EditorViewModel) {
        guard let project = vm.project, vm.currentIndex < project.frames.count - 1 else { return }
        vm.pushUndoCheckpoint()
        project.frames.removeLast(project.frames.count - 1 - vm.currentIndex)
        project.reindex()
        vm.afterMutation()
    }

    // MARK: - 剪贴板

    /// 应用内剪贴板目录（全局，支持跨项目粘贴）。
    static var clipboardDir: URL {
        let dir = Constants.recordingRoot.appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 复制选中帧到应用内剪贴板（文件级拷贝到全局 Clipboard 目录）。
    static func copy(_ vm: EditorViewModel) -> [FrameInfo] {
        let indices = vm.effectiveSelection
        guard let project = vm.project else { return [] }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var copied: [FrameInfo] = []
        for (i, idx) in indices.enumerated() {
            var frame = project.frames[idx]
            let newName = "clip_\(stamp)_\(i).png"
            let src = project.url.appendingPathComponent(frame.path)
            let dst = clipboardDir.appendingPathComponent(newName)
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                frame.path = newName
                copied.append(frame)
            }
        }
        return copied
    }

    /// 粘贴到当前帧之后。
    static func paste(_ vm: EditorViewModel, frames: [FrameInfo]) {
        guard !frames.isEmpty, let project = vm.project else { return }
        vm.pushUndoCheckpoint()
        var newFrames: [FrameInfo] = []
        for (i, var frame) in frames.enumerated() {
            let newName = "paste_\(Int(Date().timeIntervalSince1970 * 1000))_\(i).png"
            let src = clipboardDir.appendingPathComponent(frame.path)
            let dst = project.url.appendingPathComponent(newName)
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                frame.path = newName
                newFrames.append(frame)
            }
        }
        project.frames.insert(contentsOf: newFrames, at: vm.currentIndex + 1)
        project.reindex()
        vm.afterMutation()
    }

    // MARK: - 重排

    /// 反转（全部或选中段）。
    static func reverse(_ vm: EditorViewModel) {
        guard let project = vm.project, !project.frames.isEmpty else { return }
        vm.pushUndoCheckpoint()
        let indices = vm.effectiveSelection
        if indices.count >= 2 {
            // 反转选中段（保持选中帧的整体顺序反转，落位在原区间）
            let lo = indices.first!, hi = indices.last!
            let slice = project.frames[lo...hi]
            project.frames.replaceSubrange(lo...hi, with: slice.reversed())
        } else {
            project.frames.reverse()
        }
        project.reindex()
        vm.afterMutation()
    }

    /// Yoyo：正放 + 倒放（不含首帧重复）。
    static func yoyo(_ vm: EditorViewModel) {
        guard let project = vm.project, project.frames.count >= 2 else { return }
        vm.pushUndoCheckpoint()
        let original = project.frames
        var result = original
        let reversed = original.dropLast().dropFirst().reversed()
        // 复制倒放部分的文件
        let clipDir = project.url.appendingPathComponent("Yoyo", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
        for (i, var frame) in Array(reversed).enumerated() {
            let newName = "yoyo_\(i).png"
            let src = project.url.appendingPathComponent(frame.path)
            let dst = project.url.appendingPathComponent(newName)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            frame.path = newName
            result.append(frame)
        }
        project.frames = result
        project.reindex()
        vm.afterMutation()
    }

    /// 左移/右移选中帧一位。
    static func shift(_ vm: EditorViewModel, by offset: Int) {
        guard let project = vm.project else { return }
        let indices = vm.effectiveSelection
        guard !indices.isEmpty else { return }
        let lo = indices.first!, hi = indices.last!
        let target = lo + offset
        guard target >= 0, hi + offset < project.frames.count else { return }
        vm.pushUndoCheckpoint()
        let slice = project.frames[lo...hi]
        project.frames.removeSubrange(lo...hi)
        project.frames.insert(contentsOf: slice, at: target)
        project.reindex()
        vm.replaceSelection(Set((target...(target + hi - lo))))
        vm.afterMutation()
    }

    // MARK: - 延迟

    /// 批量延迟编辑（四模式，作用于全部或选中帧）。
    static func editDelays(_ vm: EditorViewModel, mode: DelayEditMode, value: Int, percent: Double = 100, applyToAll: Bool) {
        guard let project = vm.project else { return }
        vm.pushUndoCheckpoint()
        let indices = applyToAll ? Array(0..<project.frames.count) : vm.effectiveSelection
        for i in indices where i < project.frames.count {
            switch mode {
            case .override:
                project.frames[i].delay = max(10, value)
            case .increaseDecrease:
                project.frames[i].delay = max(10, project.frames[i].delay + value)
            case .scale:
                project.frames[i].delay = max(10, Int((Double(project.frames[i].delay) * percent / 100).rounded()))
            }
        }
        project.reindex()
        vm.afterMutation()
    }

    // MARK: - 减帧

    /// 减少帧数：每 factor 帧保留 1；被删帧延迟累给前一保留帧（原版语义）。
    static func reduce(_ vm: EditorViewModel, keepEvery factor: Int, applyToAll: Bool) {
        guard let project = vm.project, factor >= 2 else { return }
        vm.pushUndoCheckpoint()
        let indices = Set(applyToAll ? Array(0..<project.frames.count) : vm.effectiveSelection)
        var kept: [FrameInfo] = []
        var runIndex = -1
        for (i, frame) in project.frames.enumerated() {
            if !indices.contains(i) {
                kept.append(frame)   // 选中范围外的帧原样保留
                continue
            }
            runIndex += 1
            if runIndex % factor == 0 {
                kept.append(frame)
            } else if var last = kept.last {
                // 被删帧的延迟累给前一保留帧
                last.delay += frame.delay
                kept[kept.count - 1] = last
            }
        }
        project.frames = kept
        project.reindex()
        vm.afterMutation()
    }

    /// 删除重复帧（相似度阈值 0–100；P1 用相邻帧 PNG 字节相等 + 采样像素 MAE 近似）。
    static func removeDuplicates(_ vm: EditorViewModel, thresholdPercent: Int) {
        guard let project = vm.project, project.frames.count >= 2 else { return }
        vm.pushUndoCheckpoint()
        let tolerance = thresholdPercent * 255 / 100
        var kept: [FrameInfo] = []
        var removed = 0
        for frame in project.frames {
            if var last = kept.last,
               framesSimilar(project: project, a: last.path, b: frame.path, tolerance: tolerance) {
                last.delay += frame.delay
                kept[kept.count - 1] = last
                removed += 1
            } else {
                kept.append(frame)
            }
        }
        project.frames = kept
        project.reindex()
        vm.afterMutation()
        Log.editor.info("去重完成 removed=\(removed)")
    }

    private static func framesSimilar(project: Project, a: String, b: String, tolerance: Int) -> Bool {
        guard let imgA = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: a),
              let imgB = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: b)
        else { return false }
        // 下采样到 32×32 比较（快速近似）
        guard let dA = downsample(imgA), let dB = downsample(imgB) else { return false }
        let maxDiff = dA.enumerated().map { i, v in abs(Int(v) - Int(dB[i])) }.max() ?? 255
        return maxDiff <= tolerance
    }

    private static func downsample(_ image: CGImage) -> [UInt8]? {
        let size = 32
        var data = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(
            data: &data, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return data
    }

    // MARK: - 裁剪 / 缩放（vImage 重采样写回）

    /// 裁剪全部帧到指定矩形（图像坐标，左上原点，px）。
    static func crop(_ vm: EditorViewModel, to rect: CGRect) {
        guard let project = vm.project,
              rect.width >= 10, rect.height >= 10,
              let first = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: project.frames[0].path)
        else { return }
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: first.width, height: first.height))
        guard !clamped.isNull, clamped.width >= 10, clamped.height >= 10 else { return }

        vm.pushUndoCheckpoint()
        var newFrames: [FrameInfo] = []
        for (i, var frame) in project.frames.enumerated() {
            let newName = "crop_\(i).png"
            let dst = project.url.appendingPathComponent(newName)
            if let img = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: frame.path),
               let cropped = img.cropping(to: clamped),
               writeCGImage(cropped, to: dst) {
                frame.path = newName
                newFrames.append(frame)
            } else {
                newFrames.append(frame)
            }
        }
        project.frames = newFrames
        project.width = Int(clamped.width)
        project.height = Int(clamped.height)
        project.reindex()
        vm.afterMutation()
    }

    /// 调整大小（百分比，双线性）。
    static func resize(_ vm: EditorViewModel, scale: Double) {
        guard let project = vm.project, scale > 0.05, scale < 10 else { return }
        vm.pushUndoCheckpoint()
        var newW = 0, newH = 0
        for (i, var frame) in project.frames.enumerated() {
            guard let img = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: frame.path) else { continue }
            let w = max(8, Int((Double(img.width) * scale).rounded()))
            let h = max(8, Int((Double(img.height) * scale).rounded()))
            guard let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            ctx.interpolationQuality = scale < 1 ? .high : .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let out = ctx.makeImage() else { continue }
            let newName = "resize_\(i).png"
            let dst = project.url.appendingPathComponent(newName)
            if writeCGImage(out, to: dst) {
                frame.path = newName
                project.frames[i] = frame
            }
            newW = w; newH = h
        }
        project.width = newW
        project.height = newH
        project.reindex()
        vm.afterMutation()
    }

    /// 翻转/旋转（水平/垂直/90°）。
    static func flipRotate(_ vm: EditorViewModel, kind: FlipRotateKind) {
        guard let project = vm.project else { return }
        vm.pushUndoCheckpoint()
        for (i, var frame) in project.frames.enumerated() {
            guard let img = FrameThumbnailProvider.shared.fullImage(projectURL: project.url, framePath: frame.path) else { continue }
            guard let out = transform(img, kind: kind) else { continue }
            let newName = "flip_\(i).png"
            let dst = project.url.appendingPathComponent(newName)
            if writeCGImage(out, to: dst) {
                frame.path = newName
                project.frames[i] = frame
            }
        }
        if kind == .rotateLeft || kind == .rotateRight {
            let w = project.width
            project.width = project.height
            project.height = w
        }
        project.reindex()
        vm.afterMutation()
    }

    enum FlipRotateKind {
        case horizontal, vertical, rotateLeft, rotateRight
    }

    private static func transform(_ image: CGImage, kind: FlipRotateKind) -> CGImage? {
        let w = image.width, h = image.height
        let (ow, oh) = (kind == .rotateLeft || kind == .rotateRight) ? (h, w) : (w, h)
        guard let ctx = CGContext(
            data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        switch kind {
        case .horizontal:
            ctx.scaleBy(x: -1, y: 1)
        case .vertical:
            ctx.scaleBy(x: 1, y: -1)
        case .rotateLeft:
            ctx.rotate(by: .pi / 2)
        case .rotateRight:
            ctx.rotate(by: -.pi / 2)
        }
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    private static func writeCGImage(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
