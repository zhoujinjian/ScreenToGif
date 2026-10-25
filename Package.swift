// swift-tools-version: 5.9
// ScreenToGif for macOS — Swift Package 清单（无 Xcode 构建路线）
import PackageDescription

let package = Package(
    name: "ScreenToGif",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ScreenToGif", targets: ["ScreenToGif"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenToGif",
            path: "Sources/ScreenToGif"
        )
        // XCTest 需完整 Xcode（本机仅 CLT）；测试走内置 --selftest 模式，
        // Sources/ScreenToGif/SelfTests/ 下按模块注册。装 Xcode 后可恢复 testTarget。
    ],
    swiftLanguageVersions: [.v5]
)
