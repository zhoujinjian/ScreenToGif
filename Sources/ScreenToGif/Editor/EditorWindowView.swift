import SwiftUI
import AppKit

/// 编辑器主窗口（复刻原版布局）：
/// 顶栏工具组两行 → 播放控制条 → 预览区(ZoomBox) → 帧缩略图条 → 状态栏。
struct EditorWindowView: View {
    @Bindable var viewModel: EditorViewModel
    @State private var zoomCommand: ZoomableImagePane.ZoomCommand?
    @State private var showDelayDialog = false
    @State private var showResizeDialog = false
    @State private var showCropMode = false
    @State private var showExportDialog = false
    @State private var showGoTo = false
    @State private var goToText = ""

    var body: some View {
        Group {
            if viewModel.isEmpty {
                welcomeView
            } else {
                editorLayout
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDelayDialog) { DelayEditDialog(viewModel: viewModel) }
        .sheet(isPresented: $showResizeDialog) { ResizeDialog(viewModel: viewModel) }
        .sheet(isPresented: $showExportDialog) { ExportDialogView(viewModel: viewModel) }
        .sheet(isPresented: $showGoTo) { goToDialog }
        .overlay(alignment: .center) {
            if showCropMode { cropOverlay }
        }
    }

    // MARK: - 编辑器主体

    private var editorLayout: some View {
        VStack(spacing: 0) {
            EditorToolbarView(
                viewModel: viewModel,
                onZoom: { kind in zoomCommand = .init(kind: kind) },
                onDelay: { showDelayDialog = true },
                onResize: { showResizeDialog = true },
                onCrop: { showCropMode.toggle() },
                onExport: { showExportDialog = true },
                onGoTo: { showGoTo = true }
            )
            Divider().overlay(Theme.border)

            PlaybackBarView(viewModel: viewModel)
            Divider().overlay(Theme.border)

            // 预览（水平+垂直都要撑满：NSViewRepresentable 无内在尺寸，
            // 缺 maxWidth 时会水平塌缩成小块，图像 fit 随之变小）
            ZStack {
                ZoomableImagePane(image: viewModel.currentImage, zoomCommand: zoomCommand)
                if showCropMode { Color.black.opacity(0.001) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.border)
            FrameStripView(viewModel: viewModel)
            Divider().overlay(Theme.border)

            // 状态栏
            EditorStatusView(viewModel: viewModel)
        }
        .background(
            // 快捷键
            Group {
                Button("播放") { viewModel.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("上一帧") { viewModel.stepBackward() }
                    .keyboardShortcut(.pageUp, modifiers: [])
                Button("下一帧") { viewModel.stepForward() }
                    .keyboardShortcut(.pageDown, modifiers: [])
                Button("首帧") { viewModel.jumpToFirst() }
                    .keyboardShortcut(.home, modifiers: [])
                Button("末帧") { viewModel.jumpToLast() }
                    .keyboardShortcut(.end, modifiers: [])
                Button("删除") { viewModel.deleteFrames() }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("复制") { viewModel.copyFrames() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("粘贴") { viewModel.pasteFrames() }
                    .keyboardShortcut("v", modifiers: .command)
                Button("全选") { viewModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("反选") { viewModel.invertSelection() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("取消选择") { viewModel.deselectAll() }
                    .keyboardShortcut("u", modifiers: .command)
                Button("撤销") { viewModel.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("重做") { viewModel.redo() }
                    .keyboardShortcut("y", modifiers: .command)
                Button("适应") { zoomCommand = .init(kind: .fit) }
                    .keyboardShortcut("1", modifiers: .option)
                Button("实际") { zoomCommand = .init(kind: .actual) }
                    .keyboardShortcut("0", modifiers: .option)
            }
            .opacity(0)
        )
    }

    /// 裁剪交互层（P1 简化：输入四边数值对话框；交互式手柄 Phase 2）。
    private var cropOverlay: some View {
        CropDialog(viewModel: viewModel) {
            showCropMode = false
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2))
        .shadow(radius: 8)
    }

    private var goToDialog: some View {
        VStack(spacing: 12) {
            Text("跳转到帧").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.foreground)
            TextField("帧号", text: $goToText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            HStack {
                Button("取消") { showGoTo = false }
                Button("跳转") {
                    if let n = Int(goToText), n >= 1 {
                        viewModel.jump(to: n - 1)
                    }
                    showGoTo = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 240)
    }

    // MARK: - 欢迎页

    private var welcomeView: some View {
        VStack(spacing: 18) {
            Image(systemName: "film")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.watermark)
            Text("欢迎使用编辑器")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.foreground)
            Text("录制完成后自动进入，或点击下方导入")
                .font(.system(size: 12))
                .foregroundStyle(Theme.foreground2)

            HStack(spacing: 10) {
                Button {
                    WindowManager.shared.launcherRequestScreenRecorder()
                } label: {
                    Label("新建录制", systemImage: "viewfinder")
                }
                .buttonStyle(ThemeButtonStyle())

                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg, .gif]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        Task { @MainActor in
                            if let project = await ImportService.importMedia(url) {
                                viewModel.load(project: project)
                            }
                        }
                    }
                } label: {
                    Label("导入 GIF / 图片", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(ThemeButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 工具栏（复刻原版 Ribbon 精简为分组工具条）

struct EditorToolbarView: View {
    @Bindable var viewModel: EditorViewModel
    let onZoom: (ZoomableImagePane.ZoomCommand.Kind) -> Void
    let onDelay: () -> Void
    let onResize: () -> Void
    let onCrop: () -> Void
    let onExport: () -> Void
    let onGoTo: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            // 第一行：文件 + 撤销组
            HStack(spacing: 12) {
                ToolGroup(label: "文件") {
                    ToolbarIconButton("新建", "viewfinder") { WindowManager.shared.launcherRequestScreenRecorder() }
                    ToolbarIconButton("导入", "square.and.arrow.down") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.png, .jpeg, .gif]
                        if panel.runModal() == .OK, let url = panel.url {
                            Task { @MainActor in
                                if let project = await ImportService.importMedia(url) {
                                    viewModel.load(project: project)
                                }
                            }
                        }
                    }
                    ToolbarIconButton("导出 GIF", "square.and.arrow.up", prominent: true) { onExport() }
                }

                ToolGroup(label: "操作栈") {
                    ToolbarIconButton("撤销", "arrow.uturn.backward") { viewModel.undo() }
                        .disabled(!viewModel.canUndo)
                    ToolbarIconButton("重做", "arrow.uturn.forward") { viewModel.redo() }
                        .disabled(!viewModel.canRedo)
                }

                ToolGroup(label: "帧") {
                    ToolbarIconButton("复制", "doc.on.doc") { viewModel.copyFrames() }
                    ToolbarIconButton("粘贴", "doc.on.clipboard") { viewModel.pasteFrames() }
                    ToolbarIconButton("删除", "trash") { viewModel.deleteFrames() }
                    ToolbarIconButton("删除之前", "arrow.left.to.line") {
                        FrameOperations.deleteBefore(viewModel)
                    }
                    ToolbarIconButton("删除之后", "arrow.right.to.line") {
                        FrameOperations.deleteAfter(viewModel)
                    }
                }

                Spacer()

                ToolGroup(label: "缩放") {
                    ToolbarIconButton("缩小", "minus.magnifyingglass") { onZoom(.out) }
                    ToolbarIconButton("放大", "plus.magnifyingglass") { onZoom(.in_) }
                    ToolbarIconButton("100%", "1.magnifyingglass") { onZoom(.actual) }
                    ToolbarIconButton("适应", "arrow.up.left.and.down.right.magnifyingglass") { onZoom(.fit) }
                }
            }

            // 第二行：编辑组
            HStack(spacing: 12) {
                ToolGroup(label: "编辑") {
                    ToolbarIconButton("反转", "arrow.left.arrow.right") { viewModel.reverseFrames() }
                    ToolbarIconButton("Yoyo", "arrow.uturn.left.circle") { viewModel.yoyoFrames() }
                    ToolbarIconButton("去重", "square.3.layers.3d") { viewModel.removeDuplicates() }
                    Menu("减帧") {
                        Button("每 2 帧保留 1") { viewModel.reduceFrames(factor: 2) }
                        Button("每 3 帧保留 1") { viewModel.reduceFrames(factor: 3) }
                        Button("每 5 帧保留 1") { viewModel.reduceFrames(factor: 5) }
                    }
                    .frame(width: 58)
                    .foregroundStyle(Theme.foreground)
                    ToolbarIconButton("延迟…", "timer") { onDelay() }
                    ToolbarIconButton("跳转…", "scope") { onGoTo() }
                }

                ToolGroup(label: "图像") {
                    ToolbarIconButton("裁剪…", "crop") { onCrop() }
                    ToolbarIconButton("缩放…", "arrow.up.left.and.arrow.down.right") { onResize() }
                    Menu("翻转/旋转") {
                        Button("水平翻转") { viewModel.flipRotate(kind: .horizontal) }
                        Button("垂直翻转") { viewModel.flipRotate(kind: .vertical) }
                        Button("左转 90°") { viewModel.flipRotate(kind: .rotateLeft) }
                        Button("右转 90°") { viewModel.flipRotate(kind: .rotateRight) }
                    }
                    .frame(width: 76)
                    .foregroundStyle(Theme.foreground)
                }

                ToolGroup(label: "选择") {
                    ToolbarIconButton("全选", "checkmark.circle.fill") { viewModel.selectAll() }
                    ToolbarIconButton("反选", "circle.lefthalf.filled") { viewModel.invertSelection() }
                    ToolbarIconButton("取消", "circle") { viewModel.deselectAll() }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.panel2)
    }
}

/// 工具栏分组（带组标签）。
struct ToolGroup<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) { content }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.watermark)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.panel3))
    }
}

struct ToolbarIconButton: View {
    let title: String
    let systemName: String
    var prominent = false
    let action: () -> Void

    @State private var hovered = false

    init(_ title: String, _ systemName: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemName = systemName
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemName)
                    .font(.system(size: 14))
                    .foregroundStyle(prominent ? .white : Theme.foreground2)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(prominent ? .white : Theme.foreground2)
            }
            .frame(width: 44, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(hovered ? Theme.hover : (prominent ? Theme.accent : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
    }
}

// MARK: - 播放条

struct PlaybackBarView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button { viewModel.jumpToFirst() } label: {
                Image(systemName: "backward.end.fill")
            }
            Button { viewModel.stepBackward() } label: {
                Image(systemName: "chevron.left")
            }
            Button { viewModel.togglePlayback() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { viewModel.stepForward() } label: {
                Image(systemName: "chevron.right")
            }
            Button { viewModel.jumpToLast() } label: {
                Image(systemName: "forward.end.fill")
            }

            Toggle("循环", isOn: $viewModel.loopPlayback)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            Spacer()

            Text("帧 \(viewModel.currentIndex + 1) / \(viewModel.project?.frameCount ?? 0)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.foreground2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Theme.panel2)
    }
}

// MARK: - 状态栏

struct EditorStatusView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 16) {
            Text(viewModel.statusText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.foreground2)
            Spacer()
            if let project = viewModel.project {
                Text("\(project.width)×\(project.height)")
                Text("选中 \(viewModel.effectiveSelection.count) 帧")
                Text("时长 \(viewModel.totalDurationText)")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.watermark)
        .padding(.horizontal, 12)
        .frame(height: 20)
        .background(Theme.panel2)
    }
}

// MARK: - 对话框

struct DelayEditDialog: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: DelayEditMode = .override
    @State private var valueText = "66"
    @State private var percentText = "100"
    @State private var applyToAll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("延迟设置").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.foreground)

            Picker("模式", selection: $mode) {
                ForEach(DelayEditMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.radioGroup)

            if mode == .scale {
                HStack {
                    Text("百分比").foregroundStyle(Theme.foreground2)
                    TextField("", text: $percentText).frame(width: 60)
                    Text("%").foregroundStyle(Theme.foreground2)
                }
            } else {
                HStack {
                    Text(mode == .override ? "延迟 (ms)" : "增减 (ms，负数减少)")
                        .foregroundStyle(Theme.foreground2)
                    TextField("", text: $valueText).frame(width: 70)
                }
            }

            Toggle("应用到所有帧（否则仅选中帧）", isOn: $applyToAll)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("应用") {
                    let value = Int(valueText) ?? 66
                    let percent = Double(percentText) ?? 100
                    viewModel.editDelays(mode: mode, value: value, percent: percent, applyToAll: applyToAll)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 330)
    }
}

struct ResizeDialog: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var percentText = "50"
    @State private var keepAspect = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("调整大小").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.foreground)
            HStack {
                Text("缩放").foregroundStyle(Theme.foreground2)
                TextField("", text: $percentText).frame(width: 60)
                Text("%").foregroundStyle(Theme.foreground2)
                if let p = viewModel.project {
                    Text("(→ \(Int(Double(p.width) * (Double(percentText) ?? 100) / 100))×\(Int(Double(p.height) * (Double(percentText) ?? 100) / 100)))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.watermark)
                }
            }
            Toggle("保持宽高比", isOn: $keepAspect)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("应用") {
                    if let percent = Double(percentText), percent > 0 {
                        viewModel.resize(scale: keepAspect ? percent / 100 : percent / 100)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 330)
    }
}

/// 裁剪对话框（P1：四边数值输入）。
struct CropDialog: View {
    @Bindable var viewModel: EditorViewModel
    let onDone: () -> Void
    @State private var leftText = "0"
    @State private var topText = "0"
    @State private var rightText = "0"
    @State private var bottomText = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("裁剪（从四边裁去像素）")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.foreground)
            if let p = viewModel.project {
                Text("当前 \(p.width)×\(p.height)")
                    .font(.system(size: 11)).foregroundStyle(Theme.watermark)
            }
            HStack(spacing: 10) {
                cropField("左", $leftText)
                cropField("上", $topText)
                cropField("右", $rightText)
                cropField("下", $bottomText)
            }
            HStack {
                Spacer()
                Button("取消") { onDone() }
                Button("裁剪") {
                    guard let p = viewModel.project else { return }
                    let l = Int(leftText) ?? 0
                    let t = Int(topText) ?? 0
                    let r = Int(rightText) ?? 0
                    let b = Int(bottomText) ?? 0
                    let rect = CGRect(x: l, y: t, width: p.width - l - r, height: p.height - t - b)
                    viewModel.crop(to: rect)
                    onDone()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func cropField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.watermark)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 54)
        }
    }
}
