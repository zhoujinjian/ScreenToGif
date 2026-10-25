import SwiftUI

/// 启动器窗口（复刻原版 Startup.xaml：500×230 深色，顶栏标题+选项，四等分大按钮）。
struct LauncherView: View {
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏 45pt：标题 + 选项按钮
            HStack {
                Text("ScreenToGif")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.foreground2)
                    .padding(.leading, 14)

                Spacer()

                Button {
                    WindowManager.shared.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.foreground2)
                }
                .buttonStyle(.plain)
                .help("选项 (⌥⌘O)")
                .padding(.trailing, 12)
            }
            .frame(height: 45)
            .background(Theme.panel2)

            // 四等分大按钮
            HStack(spacing: 1) {
                LauncherBigButton(titleKey: "录屏", systemImage: "viewfinder") {
                    WindowManager.shared.launcherRequestScreenRecorder()
                }
                LauncherBigButton(titleKey: "摄像头", systemImage: "video", disabled: true) {
                    WindowManager.shared.launchWebcamRecorder()
                }
                LauncherBigButton(titleKey: "画板", systemImage: "square.and.pencil", disabled: true) {
                    WindowManager.shared.launchBoardRecorder()
                }
                LauncherBigButton(titleKey: "编辑器", systemImage: "film") {
                    WindowManager.shared.showEditor(with: nil)
                }
            }
            .padding(.top, 1)
        }
        .background(Theme.background)
        .frame(minWidth: 500, minHeight: 230)
        .overlay(
            // 键盘快捷键（复刻原版 ⌘N/⌘W/⌘B/⌘E）
            Group {
                Button("录屏") { WindowManager.shared.launcherRequestScreenRecorder() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("摄像头") { WindowManager.shared.launchWebcamRecorder() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("画板") { WindowManager.shared.launchBoardRecorder() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("编辑器") { WindowManager.shared.showEditor(with: nil) }
                    .keyboardShortcut("e", modifiers: .command)
                Button("选项") { WindowManager.shared.showSettings() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
            }
            .opacity(0)
        )
        .preferredColorScheme(.dark)
    }
}
