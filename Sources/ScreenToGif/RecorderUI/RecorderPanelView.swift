import SwiftUI

/// 录制控制条（复刻原版 Recorder 底栏：关闭 | 帧数/时长 | 快照 | 选项 | FPS | 宽×高 | 丢弃 | 录/停）。
struct RecorderPanelView: View {
    @Bindable var viewModel: RecorderViewModel

    var body: some View {
        HStack(spacing: 8) {
            // 关闭（取消本次录制）
            PanelIconButton(systemName: "xmark", help: "取消") {
                viewModel.discard()
            }

            Divider().frame(height: 18)

            // 帧数 + 时长
            VStack(alignment: .leading, spacing: 0) {
                Text("\(viewModel.frameCount) 帧")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.foreground)
                Text(viewModel.elapsedText)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.foreground2)
            }
            .frame(minWidth: 56, alignment: .leading)

            Divider().frame(height: 18)

            // 快照（手动模式 = 拍一帧）
            PanelIconButton(systemName: "camera", help: "快照") {
                Task { try? await viewModel.snapshot() }
            }
            .disabled(viewModel.state != .recording)

            // 选项
            PanelIconButton(systemName: "slider.horizontal.3", help: "选项") {
                WindowManager.shared.showSettings()
            }

            Divider().frame(height: 18)

            // FPS
            HStack(spacing: 3) {
                Text("FPS").font(.system(size: 10)).foregroundStyle(Theme.foreground2)
                TextField("", value: $viewModel.fps, formatter: NumberFormatter())
                    .textFieldStyle(.plain)
                    .frame(width: 26)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.foreground)
                    .background(Theme.control)
                    .onSubmit { viewModel.applyFps() }
                Text(viewModel.actualFpsText)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.watermark)
                    .frame(minWidth: 34)
            }

            // 宽 × 高
            Text("\(Int(viewModel.regionSize.width)) × \(Int(viewModel.regionSize.height))")
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(Theme.foreground2)

            Spacer(minLength: 4)

            // 丢弃
            PanelIconButton(systemName: "trash", help: "丢弃") {
                viewModel.discard()
            }

            // 录制 / 暂停 / 继续
            PanelIconButton(
                systemName: viewModel.state == .recording ? "pause.fill" : "record.circle",
                help: viewModel.state == .recording ? "暂停" : "录制",
                tint: viewModel.state == .recording ? Theme.foreground2 : Color(hex: 0xE05252)
            ) {
                viewModel.togglePauseResume()
            }

            // 停止
            PanelIconButton(systemName: "stop.fill", help: "停止并编辑", tint: Color(hex: 0xE05252)) {
                viewModel.stop()
            }
            .disabled(viewModel.state != .recording && viewModel.state != .paused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 430)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.panel2)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
        )
        .preferredColorScheme(.dark)
    }
}

/// 控制条小图标按钮。
struct PanelIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = Theme.foreground2
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .background(hovered ? Theme.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
    }
}
