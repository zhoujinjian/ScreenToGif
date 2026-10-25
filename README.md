# ScreenToGif for macOS 🎬

> A native macOS screen-to-GIF recorder, rebuilt in Swift from the open-source Windows classic.

基于开源项目 [ScreenToGif](https://github.com/NickeManarin/ScreenToGif)（Windows）打造的 **macOS 原生** 录屏转 GIF 工具。Swift / SwiftUI / AppKit / ScreenCaptureKit。

## 系统要求

- macOS 14 Sonoma 或更高
- Xcode Command Line Tools（**无需完整 Xcode**，纯 SwiftPM + 脚本组装 .app）

## 功能（Phase 1）

- **屏幕录制**：区域拖选 / 窗口吸附 / 多显示器覆盖层；FPS 1–60（固定/可变帧率）；光标捕获；暂停/继续/快照/停止/丢弃；帧数·时长·实测帧率显示
- **帧编辑器**：帧缩略图条（多选）、缩放平移预览（⌘+滚轮缩放）、播放（空格，逐帧延迟感知）、删除/删前/删后、复制/粘贴、反转/Yoyo、去重、减帧、延迟编辑（覆盖/增减/缩放）、裁剪、缩放、翻转/旋转、撤销/重做（快照式）
- **GIF 导出**：自研 GIF89a 编码器（Octree/中位切分量化、LZW、NETSCAPE 循环、未变更像素检测优化）；进度/取消；Finder 显示/剪贴板
- **导入**：GIF / PNG / JPEG
- 深色主题复刻原版；托盘常驻；设置持久化；Project.json 与原版字段兼容

## 构建与运行

```bash
git clone https://github.com/zhoujinjian/ScreenToGif.git
cd ScreenToGif

Scripts/build.sh            # swift build -c release
Scripts/make-app.sh         # 组装 build/ScreenToGif.app + 稳定自签名（TCC 权限可跨编译保持）
Scripts/make-app.sh --open  # 组装并启动
```

无 Xcode 环境下的测试与诊断（内置自测框架，无需 XCTest）：

```bash
.build/release/ScreenToGif --selftest      # 全量自测（模型 / GIF 编码器 / LZW / 回归用例）
.build/release/ScreenToGif --sck-spike     # ScreenCaptureKit 尖刺验证
.build/release/ScreenToGif --record-spike  # 端到端无人值守：录制 → 工程 → GIF
.build/release/ScreenToGif --export-spike  # 加载最近工程真实导出 + 颜色保真验证
```

首次使用需授予「屏幕录制」权限（系统设置 → 隐私与安全性）；记录点击/按键需「辅助功能」权限（可选，拒绝自动降级）。

## 架构

```
Sources/ScreenToGif/
├── App/          入口 / 委托 / 窗口管理 / 全局状态
├── Model/        FrameInfo·Project（原版字段兼容）/ 选区 / 枚举
├── Capture/      ScreenRecorder(SCK) / FramePipeline(有界队列) / FrameWriter / FrameClock / EventRecorder(CGEventTap) / WindowLister / 权限 / 坐标转换
├── RecorderUI/   选区覆盖窗（每显示器）/ 录制控制条(NSPanel) / 录制边框 / 状态机
├── Editor/       编辑器窗口 / 播放 / 帧操作 / 撤销栈 / 缩略图 / 预览 / 导入
├── Export/       GIF 编码器（移植原版）/ 导出编排 / 对话框
├── Settings/     用户设置（JSON 原子写）
├── Shell/        启动器 / 托盘 / 主题
└── SelfTests/    内置自测（--selftest）
```

帧存储与原版同构：`$TMPDIR/ScreenToGif/Recording/{UUID}/` 内含编号 PNG + `Project.json` + `ActionStack/Undo|Redo/`。

## 路线图

- **P2**：编辑覆盖层全家族（字幕/涂鸦/按键/鼠标事件/水印/遮挡/进度条…）、FFmpeg 视频导出、APNG、Gifski、`.stg` 工程互通、导出预设/队列
- **P3**：摄像头/画板录制器、光标跟随、交互触发、全局热键、CLI、多语言、更新检查
- **P4**：上传（Imgur）、疑难解答、分发公证

## 许可证

[MS-PL](LICENSE)（Microsoft Public License），与上游 [ScreenToGif](https://github.com/NickeManarin/ScreenToGif) 保持一致——GIF 编码器移植自其 MS-PL 授权代码，本仓库整体采用同一协议。

## 致谢

- [ScreenToGif](https://github.com/NickeManarin/ScreenToGif) by Nicke Manarin — 功能蓝本与 GIF 编码器算法来源（MS-PL）
