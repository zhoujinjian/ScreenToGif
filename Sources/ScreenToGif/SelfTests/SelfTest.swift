import Foundation

/// 轻量自测框架（CLT 无 XCTest/Swift Testing 的替代方案）。
/// 运行：`screentogif --selftest`。装完整 Xcode 后可迁移到 XCTest。
enum SelfTest {
    static var failures: [String] = []
    static var total = 0
    static var passed = 0

    struct TestCase {
        let name: String
        let run: () throws -> Void
    }

    static var registry: [TestCase] = []

    static func register(_ name: String, _ run: @escaping () throws -> Void) {
        registry.append(TestCase(name: name, run: run))
    }

    // MARK: - 断言

    static func expect(_ condition: Bool, _ message: String = "断言失败",
                       file: StaticString = #fileID, line: UInt = #line) {
        total += 1
        if condition { passed += 1 } else {
            failures.append("\(file):\(line) — \(message)")
        }
    }

    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String = "",
                                          file: StaticString = #fileID, line: UInt = #line) {
        expect(a == b, "\(label) 期望 \(b)，实际 \(a)", file: file, line: line)
    }

    static func expectThrows(_ body: () throws -> Void, _ label: String = "",
                             file: StaticString = #fileID, line: UInt = #line) {
        total += 1
        do { try body(); failures.append("\(file):\(line) — \(label) 期望抛错但未抛") }
        catch { passed += 1 }
    }

    // MARK: - 运行

    @discardableResult
    static func runAll() -> Int32 {
        print("▶ 运行 \(registry.count) 组自测…")
        for testCase in registry {
            let start = Date()
            do {
                try testCase.run()
                print("  ✅ \(testCase.name) (\(String(format: "%.2f", Date().timeIntervalSince(start) * 1000))ms)")
            } catch {
                failures.append("\(testCase.name) — 异常: \(error)")
                print("  💥 \(testCase.name) — 异常: \(error)")
            }
        }
        print("────────────────────────")
        print("断言：\(passed)/\(total) 通过")
        if failures.isEmpty {
            print("🎉 全部通过")
            return 0
        } else {
            print("❌ \(failures.count) 项失败：")
            failures.forEach { print("  - \($0)") }
            return 1
        }
    }
}
