#!/bin/zsh
# ScreenToGif macOS — 组装 .app 包 + 稳定自签名 + （可选）启动
# 用法: Scripts/make-app.sh [--open] [--version x.y.z] [--bin <可执行文件路径>]
#   --version  写入 CFBundleShortVersionString（默认 0.1.0）
#   --bin      可执行文件路径（默认 .build/release/ScreenToGif；
#              CI 双架构构建产物在 .build/apple/Products/Release/ 下）
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.screentogif.mac"
APP_NAME="ScreenToGif"
APP="build/${APP_NAME}.app"
BIN=".build/release/${APP_NAME}"
VERSION="0.1.0"
OPEN_AFTER=0
ADHOC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --bin) BIN="$2"; shift 2 ;;
    --open) OPEN_AFTER=1; shift ;;
    --adhoc) ADHOC=1; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 构建号：git 提交计数（无 git 环境时回退 1）
BUILD_NUM=$(git rev-list --count HEAD 2>/dev/null || echo 1)

[[ -f "$BIN" ]] || { echo "❌ 未找到 $BIN，先运行 Scripts/build.sh"; exit 1; }

# 1. 组装 bundle 结构
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Resources/Assets"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
# 拷贝纯文件资源（若有）
if [[ -d "Sources/ScreenToGif/Support/Assets" ]]; then
  rsync -a "Sources/ScreenToGif/Support/Assets/" "$APP/Contents/Resources/Assets/" 2>/dev/null || true
fi
# 应用图标（icns 同时放 Resources 根，CFBundleIconFile 直接引用）
if [[ -f "Sources/ScreenToGif/Support/Assets/AppIcon.icns" ]]; then
  cp "Sources/ScreenToGif/Support/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# 2. Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>ScreenToGif</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUM}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 3. 签名
#    本地：稳定自签名证书（避免 ad-hoc 重编译后 TCC 屏幕录制权限失效）。
#    --adhoc（CI）：直接 ad-hoc 签名。证书路径在无 GUI 环境不可行——codesign
#    访问 keychain 私钥的授权对话框无人应答会永久挂起。
CERT_NAME="ScreenToGif Dev"
if [[ "$ADHOC" == "1" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "✅ ad-hoc 签名（CI 模式，用户首开需右键打开）"
  codesign --verify "$APP" && echo "✅ 签名校验通过: $APP"
else
P12="$HOME/Library/Application Support/ScreenToGif/DevIdentity.p12"
if ! security find-certificate -c "$CERT_NAME" 2>/dev/null | grep -q "labl"; then
  mkdir -p "$HOME/Library/Application Support/ScreenToGif"
  if [[ ! -f "$P12" ]]; then
    echo "🔧 首次创建开发用自签名证书…"
    TMPD=$(mktemp -d)
    openssl req -new -newkey rsa:2048 -x509 -days 3650 -nodes \
      -subj "/CN=${CERT_NAME}" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=codeSigning" \
      -keyout "$TMPD/dev.key" -out "$TMPD/dev.crt" 2>/dev/null
    # macOS security 只认经典 P12 算法（OpenSSL 3 默认 AES-256 会被拒）
    openssl pkcs12 -export -out "$P12" -inkey "$TMPD/dev.key" -in "$TMPD/dev.crt" \
      -passout pass:screentogif -legacy 2>/dev/null || \
    openssl pkcs12 -export -out "$P12" -inkey "$TMPD/dev.key" -in "$TMPD/dev.crt" \
      -passout pass:screentogif -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
    rm -rf "$TMPD"
  fi
  security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "screentogif" -T /usr/bin/codesign >/dev/null 2>&1 || true
fi

if codesign --force --sign "$CERT_NAME" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
  echo "✅ 已用稳定证书签名（TCC 权限可跨编译保持）"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "⚠️ 回退 ad-hoc 签名（重编译后可能需重新授予屏幕录制权限）"
fi
codesign --verify "$APP" && echo "✅ 签名校验通过: $APP"
fi

# 4. 可选启动
if [[ "$OPEN_AFTER" == "1" ]]; then
  open "$APP"
fi
