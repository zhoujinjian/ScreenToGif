import SwiftUI
import AppKit

/// GIF 导出对话框（复刻原版另存为面板子集：循环/色数/量化器/差分 + 位置）。
struct ExportDialogView: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var loopCount: Int
    @State private var maxColors: Int
    @State private var quantizerName: String
    @State private var detectUnchanged: Bool
    @State private var openInFinder = true
    @State private var copyToClipboard = false
    @State private var isExporting = false
    @State private var progress = ExportManager.Progress()
    @State private var exportTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        _loopCount = State(initialValue: UserSettings.shared.exportLoopCount)
        _maxColors = State(initialValue: UserSettings.shared.exportMaxColors)
        _quantizerName = State(initialValue: UserSettings.shared.exportQuantizer)
        _detectUnchanged = State(initialValue: UserSettings.shared.exportDetectUnchanged)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isExporting {
                progressView
            } else {
                optionsView
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.panel2)
        .preferredColorScheme(.dark)
        .onDisappear {
            exportTask?.cancel()
        }
    }

    // MARK: - 选项

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出 GIF")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.foreground)

            if let project = viewModel.project {
                Text("\(project.frameCount) 帧 · \(project.width)×\(project.height) · \(viewModel.totalDurationText)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.watermark)
            }

            Divider().overlay(Theme.border)

            HStack {
                Text("循环次数").foregroundStyle(Theme.foreground2).frame(width: 90, alignment: .leading)
                Stepper(value: $loopCount, in: 0...100) {
                    Text(loopCount == 0 ? "无限" : "\(loopCount) 次")
                        .foregroundStyle(Theme.foreground)
                        .frame(width: 90, alignment: .leading)
                }
            }

            HStack {
                Text("最大颜色数").foregroundStyle(Theme.foreground2).frame(width: 90, alignment: .leading)
                Picker("", selection: $maxColors) {
                    ForEach([2, 4, 8, 16, 32, 64, 128, 256], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }

            HStack {
                Text("量化器").foregroundStyle(Theme.foreground2).frame(width: 90, alignment: .leading)
                Picker("", selection: $quantizerName) {
                    Text("Octree").tag("Octree")
                    Text("中位切分").tag("MedianCut")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            Toggle("检测未变更像素（更小的文件）", isOn: $detectUnchanged)
                .foregroundStyle(Theme.foreground)

            Divider().overlay(Theme.border)

            Toggle("完成后在 Finder 中显示", isOn: $openInFinder)
                .foregroundStyle(Theme.foreground)
            Toggle("复制到剪贴板", isOn: $copyToClipboard)
                .foregroundStyle(Theme.foreground)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("导出…") { beginExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isEmpty)
            }
        }
    }

    // MARK: - 进度

    private var progressView: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(progress.frameIndex), total: Double(max(1, progress.frameCount)))
            Text(progress.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.foreground2)
            HStack {
                Spacer()
                Button("取消") {
                    exportTask?.cancel()
                    isExporting = false
                }
            }
        }
    }

    // MARK: - 导出

    private func beginExport() {
        guard let project = viewModel.project else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "Animation \(project.id.prefix(8)).gif"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 记忆设置
        UserSettings.shared.exportLoopCount = loopCount
        UserSettings.shared.exportMaxColors = maxColors
        UserSettings.shared.exportQuantizer = quantizerName
        UserSettings.shared.exportDetectUnchanged = detectUnchanged
        UserSettings.shared.save()

        isExporting = true
        errorMessage = nil
        progress = ExportManager.Progress(frameCount: project.frameCount)

        exportTask = Task { @MainActor in
            do {
                try await ExportManager.export(
                    project: project, to: url,
                    options: .init(
                        loopCount: loopCount, maxColors: maxColors,
                        quantizerName: quantizerName, detectUnchanged: detectUnchanged,
                        openInFinder: openInFinder, copyToClipboard: copyToClipboard
                    )
                ) { p in
                    progress = p
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                dismiss()
            } catch is CancellationError {
                isExporting = false
            } catch {
                errorMessage = error.localizedDescription
                isExporting = false
            }
        }
    }
}
