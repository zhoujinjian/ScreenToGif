#!/bin/zsh
# ScreenToGif macOS — 把 build/ScreenToGif.app 打成安装 dmg
# 用法: Scripts/make-dmg.sh [--version x.y.z]
#
# 产物: build/ScreenToGif-<version>-<arch>.dmg（arch 取自二进制 lipo 架构）
# 安装界面：左侧 App 图标 + 右侧 Applications 快捷方式（拖拽安装）。
# 说明：Finder 窗口布局通过 AppleScript 设置（本机首次可能弹「自动化」授权）；
#       无 GUI/CI 环境下自动退化为普通布局（仍含 Applications 快捷方式）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ScreenToGif"
APP="build/${APP_NAME}.app"
VERSION="0.1.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ -d "$APP" ]] || { echo "❌ 未找到 $APP，先运行 Scripts/make-app.sh"; exit 1; }

# 架构标识（universal / arm64 / x86_64）
ARCHS=$(lipo -archs "$APP/Contents/MacOS/${APP_NAME}" 2>/dev/null || echo "unknown")
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ARCH_TAG="universal" ;;
  *arm64*) ARCH_TAG="arm64" ;;
  *x86_64*) ARCH_TAG="x86_64" ;;
 *) ARCH_TAG="unknown" ;;
esac

DMG="build/${APP_NAME}-${VERSION}-${ARCH_TAG}.dmg"
VOLNAME="${APP_NAME}"

echo "📦 打包 ${DMG}（二进制架构: ${ARCHS}）"

# 1. 工作目录与源目录分离：源目录（srcfolder）只放 App 与 Applications 快捷方式，
#    输出 dmg 必须在源目录之外——放进去会被打包器递归包含自身，镜像无限增长撑爆磁盘。
WORK=$(mktemp -d)
STAGING="$WORK/staging"
mkdir -p "$STAGING"
trap '[[ -n "${MOUNT:-}" ]] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
cp -R "$APP" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"

# 2. 可读写 dmg → 挂载 → Finder 布局 → 分离 → 压缩
RW_DMG="$WORK/rw.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG" -quiet

MOUNT=$(hdiutil attach "$RW_DMG" -mountpoint "$WORK/vol" -nobrowse >/dev/null 2>&1; echo "$WORK/vol")

# Finder 图标布局（宽 560 高 320：App 居左、Applications 居右）。
# 失败（无 GUI / 自动化权限被拒）不阻塞——产物仍可用，只是默认视图。
osascript >/dev/null 2>&1 <<OSA || echo "⚠️ Finder 布局设置跳过（无 GUI 或未授权自动化），dmg 仍可用"
tell application "Finder"
  tell disk "${VOLNAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 160, 760, 480}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "${APP_NAME}" of container window to {160, 160}
    set position of item "Applications" of container window to {400, 160}
    set background color of theViewOptions to {65536, 65536, 65536}
    close
  end tell
end tell
OSA

# 给布局落盘一点时间，再分离
sleep 1
hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1
MOUNT=""

# 3. 压缩为分发格式（UDZO + zlib 最大压缩）
hdiutil convert "$RW_DMG" -ov -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet >/dev/null

echo "✅ 完成: ${DMG} ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "   校验: hdiutil verify \"${DMG}\" && hdiutil attach \"${DMG}\""
