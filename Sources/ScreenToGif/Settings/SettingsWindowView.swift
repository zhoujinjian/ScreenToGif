import SwiftUI

/// 选项窗口（四页骨架：应用程序 / 录制 / 编辑器 / 导出）。
struct SettingsWindowView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            ApplicationSettingsPage().tabItem { Label("应用程序", systemImage: "app") }.tag(0)
            RecorderSettingsPage().tabItem { Label("录制", systemImage: "record.circle") }.tag(1)
            EditorSettingsPage().tabItem { Label("编辑器", systemImage: "film") }.tag(2)
            ExportSettingsPage().tabItem { Label("导出", systemImage: "square.and.arrow.up") }.tag(3)
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 460)
        .preferredColorScheme(.dark)
        .onDisappear { UserSettings.shared.save() }
    }
}

private struct ApplicationSettingsPage: View {
    var body: some View {
        SettingsForm {
            SettingsRow(label: "启动页面") {
                Picker("", selection: Binding(
                    get: { UserSettings.shared.launchPage },
                    set: { UserSettings.shared.launchPage = $0; UserSettings.shared.save() }
                )) {
                    Text("启动器").tag("Startup")
                    Text("编辑器").tag("Editor")
                }.pickerStyle(.radioGroup)
            }
        }
    }
}

private struct RecorderSettingsPage: View {
    var body: some View {
        SettingsForm {
            SettingsNumberRow(label: "帧率（FPS，1–60）", value: UserSettings.shared.fps, range: 1...60) {
                UserSettings.shared.fps = $0; UserSettings.shared.save()
            }
            SettingsToggleRow(label: "固定帧率（否则按实际耗时）", value: UserSettings.shared.fixedFrameRate) {
                UserSettings.shared.fixedFrameRate = $0; UserSettings.shared.save()
            }
            SettingsToggleRow(label: "捕获光标（绘制进画面）", value: UserSettings.shared.captureCursor) {
                UserSettings.shared.captureCursor = $0; UserSettings.shared.save()
            }
            SettingsToggleRow(label: "记录鼠标点击（供后期高亮）", value: UserSettings.shared.captureMouseClicks) {
                UserSettings.shared.captureMouseClicks = $0; UserSettings.shared.save()
            }
            SettingsToggleRow(label: "记录按键（供按键字幕）", value: UserSettings.shared.captureKeyStrokes) {
                UserSettings.shared.captureKeyStrokes = $0; UserSettings.shared.save()
            }
            SettingsToggleRow(label: "选区吸附到窗口", value: UserSettings.shared.snapToWindow) {
                UserSettings.shared.snapToWindow = $0; UserSettings.shared.save()
            }
            SettingsNumberRow(label: "开始前倒计时（秒，0 = 关）", value: UserSettings.shared.preStartCountdown, range: 0...10) {
                UserSettings.shared.preStartCountdown = $0; UserSettings.shared.save()
            }
        }
    }
}

private struct EditorSettingsPage: View {
    var body: some View {
        SettingsForm {
            SettingsNumberRow(label: "撤销历史步数上限", value: UserSettings.shared.undoDepth, range: 1...500) {
                UserSettings.shared.undoDepth = $0; UserSettings.shared.save()
            }
            SettingsToggleRow(label: "删除帧前确认", value: UserSettings.shared.deleteConfirmation) {
                UserSettings.shared.deleteConfirmation = $0; UserSettings.shared.save()
            }
        }
    }
}

private struct ExportSettingsPage: View {
    var body: some View {
        SettingsForm {
            SettingsNumberRow(label: "GIF 循环次数（0 = 无限）", value: UserSettings.shared.exportLoopCount, range: 0...100) {
                UserSettings.shared.exportLoopCount = $0; UserSettings.shared.save()
            }
            SettingsNumberRow(label: "最大颜色数（2–256）", value: UserSettings.shared.exportMaxColors, range: 2...256) {
                UserSettings.shared.exportMaxColors = $0; UserSettings.shared.save()
            }
            SettingsToggleRow(label: "检测未变更像素（更小的 GIF）", value: UserSettings.shared.exportDetectUnchanged) {
                UserSettings.shared.exportDetectUnchanged = $0; UserSettings.shared.save()
            }
            SettingsRow(label: "量化器") {
                Picker("", selection: Binding(
                    get: { UserSettings.shared.exportQuantizer },
                    set: { UserSettings.shared.exportQuantizer = $0; UserSettings.shared.save() }
                )) {
                    Text("Octree（默认）").tag("Octree")
                    Text("中位切分").tag("MedianCut")
                }
            }
        }
    }
}

// MARK: - 深色设置行组件

struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.foreground)
            Spacer()
            content
        }
        .padding(8)
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
    }
}

struct SettingsToggleRow: View {
    let label: String
    @State var value: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        SettingsRow(label: label) {
            Toggle("", isOn: Binding(get: { value }, set: { value = $0; onChange($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

struct SettingsNumberRow: View {
    let label: String
    @State var value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        SettingsRow(label: label) {
            Stepper(value: Binding(get: { value }, set: { value = $0; onChange($0) }), in: range) {
                Text("\(value)").foregroundStyle(Theme.foreground2).frame(width: 44, alignment: .trailing)
            }
        }
    }
}
