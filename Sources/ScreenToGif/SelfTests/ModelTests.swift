import Foundation

/// 模型序列化自测。
enum ModelTests {
    static func register() {
        SelfTest.register("FrameInfo JSON roundtrip + 原版字段名") {
            let frame = FrameInfo(path: "12.png", delay: 66, cursorX: 100, cursorY: 200,
                                  buttonClicked: .left, keyList: [KeyGesture(key: "A", modifiers: .command)])
            let data = try JSONEncoder().encode(frame)
            let json = String(data: data, encoding: .utf8) ?? ""
            for key in ["\"Path\"", "\"Name\"", "\"Delay\"", "\"CursorX\"", "\"CursorY\"", "\"ButtonClicked\"", "\"Keys\""] {
                SelfTest.expect(json.contains(key), "缺少原版兼容键 \(key)")
            }
            let back = try JSONDecoder().decode(FrameInfo.self, from: data)
            SelfTest.expectEqual(back.path, "12.png")
            SelfTest.expectEqual(back.delay, 66)
            SelfTest.expectEqual(back.cursorX, 100)
            SelfTest.expectEqual(back.buttonClicked, .left)
            SelfTest.expectEqual(back.keyList.count, 1)
        }

        SelfTest.register("FrameInfo 兼容原版绝对路径 + 字段缺失") {
            let json = #"{"Path":"/tmp/ScreenToGif/Recording/x/7.png","Delay":50,"CursorX":3}"#
            let frame = try JSONDecoder().decode(FrameInfo.self, from: Data(json.utf8))
            SelfTest.expectEqual(frame.path, "7.png", "绝对路径应收敛为文件名")
            SelfTest.expectEqual(frame.delay, 50)
            SelfTest.expectEqual(frame.cursorX, 3)
            SelfTest.expectEqual(frame.cursorY, Int.min, "缺失光标 Y 应为哨兵值")
        }

        SelfTest.register("Project JSON roundtrip") {
            let project = Project(width: 800, height: 600)
            project.frames = [FrameInfo(path: "0.png", delay: 50), FrameInfo(path: "1.png", delay: 100)]
            project.reindex()
            let data = try JSONEncoder().encode(project)
            let json = String(data: data, encoding: .utf8) ?? ""
            for key in ["\"RelativePath\"", "\"Frames\"", "\"Width\"", "\"Height\"", "\"Dpi\"", "\"BitDepth\""] {
                SelfTest.expect(json.contains(key), "缺少原版兼容键 \(key)")
            }
            let back = try JSONDecoder().decode(Project.self, from: data)
            SelfTest.expectEqual(back.frameCount, 2)
            SelfTest.expectEqual(back.totalDurationMs, 150)
            SelfTest.expectEqual(back.frames[1].index, 1)
        }

        SelfTest.register("SCK sourceRect 坐标转换（AppKit 左下原点 → SCK 左上原点）") {
            let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

            // 屏幕中部选区：AppKit (100,382,300,200) 距顶 400 → SCK y=400
            let mid = ScreenMath.sckLocalRect(fromAppKitGlobal: CGRect(x: 100, y: 382, width: 300, height: 200), displayFrame: main)
            SelfTest.expectEqual(mid, CGRect(x: 100, y: 400, width: 300, height: 200), "中部选区 y 应翻转为距顶距离")

            // 贴底：AppKit y=0 → SCK y=H-h
            let bottom = ScreenMath.sckLocalRect(fromAppKitGlobal: CGRect(x: 50, y: 0, width: 100, height: 100), displayFrame: main)
            SelfTest.expectEqual(bottom, CGRect(x: 50, y: 882, width: 100, height: 100), "贴底选区")

            // 贴顶：AppKit maxY=H → SCK y=0
            let top = ScreenMath.sckLocalRect(fromAppKitGlobal: CGRect(x: 50, y: 882, width: 100, height: 100), displayFrame: main)
            SelfTest.expectEqual(top, CGRect(x: 50, y: 0, width: 100, height: 100), "贴顶选区")

            // 副屏（负坐标）：frame(-1440,0,1440,900)，选区 (-1400,500,200,150)
            let side = CGRect(x: -1440, y: 0, width: 1440, height: 900)
            let sub = ScreenMath.sckLocalRect(fromAppKitGlobal: CGRect(x: -1400, y: 500, width: 200, height: 150), displayFrame: side)
            SelfTest.expectEqual(sub, CGRect(x: 40, y: 250, width: 200, height: 150), "副屏本地坐标")

            // roundtrip：正逆变换互逆
            let probe = CGRect(x: 313, y: 377, width: 424, height: 268)
            let round = ScreenMath.appKitGlobalRect(fromSckLocal: ScreenMath.sckLocalRect(fromAppKitGlobal: probe, displayFrame: main), displayFrame: main)
            SelfTest.expectEqual(round, probe, "正逆变换应互逆")
        }
    }
}
