import SwiftUI
import AppKit

/// 复刻原版 Dark.xaml 的色板常量与通用控件样式。
enum Theme {
    // MARK: - 色板（自原版 Dark 主题提取）
    static let background = Color(hex: 0x202020)      // 窗体底
    static let panel2 = Color(hex: 0x262626)          // 二级面板
    static let panel3 = Color(hex: 0x2A2A2A)          // 三级面板
    static let control = Color(hex: 0x323232)         // 控件底
    static let hover = Color(hex: 0x333337)           // 悬停
    static let border = Color(hex: 0x545454)          // 边框
    static let borderLight = Color(hex: 0x444C55)     // 亮边框
    static let foreground = Color(hex: 0xE8E8E8)      // 主前景
    static let foreground2 = Color(hex: 0xBBBBBB)     // 次级前景
    static let watermark = Color(hex: 0x666666)       // 弱化前景
    static let accent = Color(hex: 0x005394)          // 选中强调

    /// 录制边框蓝（原版选区高亮）。
    static let selectionBorder = Color(hex: 0x0066CC)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - 通用按钮样式（深色扁平，复刻原版观感）

struct ThemeButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isPressed ? Theme.hover : (emphasized ? Theme.accent : Theme.control))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .foregroundStyle(Theme.foreground)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 大图标+文字的启动器按钮（复刻原版 Startup 四大按钮）。
struct LauncherBigButton: View {
    let titleKey: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(disabled ? Theme.watermark : Theme.foreground2)
                    .frame(height: 36)
                Text(titleKey)
                    .font(.system(size: 13))
                    .foregroundStyle(disabled ? Theme.watermark : Theme.foreground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovered && !disabled ? Theme.panel3 : Theme.background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
    }
}
