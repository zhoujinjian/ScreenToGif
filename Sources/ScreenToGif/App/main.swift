import AppKit

// SwiftPM 可执行入口：手动装配 NSApplication（无 Info.plist 主 storyboard 场景）。
// 强制深色外观，复刻原版默认 Dark 主题。

// --selftest：CLT 环境无 XCTest，内置自测模式（纯逻辑测试）。
if CommandLine.arguments.contains("--selftest") {
    ModelTests.register()
    GifTests.register()
    let exitCode = SelfTest.runAll()
    exit(exitCode)
}

// --sck-spike：里程碑 C 尖刺验证（SCK 坐标校准 + 流吞吐压测）。
if CommandLine.arguments.contains("--sck-spike") {
    exit(SckSpike.run())
}

// --record-spike [秒]：端到端无人值守验证（录制 → 工程 → GIF 导出）。
if CommandLine.arguments.contains("--record-spike") {
    exit(RecordSpike.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if let dark = NSAppearance(named: .darkAqua) {
    app.appearance = dark
}
app.run()
