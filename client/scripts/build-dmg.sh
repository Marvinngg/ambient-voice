#!/bin/bash
# WE DMG 打包脚本
#
# 用法:
#   ./scripts/build-dmg.sh           # 用 Info.plist 里的版本号
#   ./scripts/build-dmg.sh 0.2.0     # 显式覆盖版本号
#
# 输出: .build/WE-<version>.dmg
#
# 签名策略: ad-hoc 签名（codesign -s -）
# 用户首次安装需要执行 xattr -cr /Applications/WE.app 绕过 Gatekeeper
# 详细安装步骤见 scripts/INSTALL.txt

set -euo pipefail

# 切到 client 目录（脚本可能在任何位置被调用）
cd "$(dirname "$0")/.."

INFO_PLIST="Sources/Info.plist"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/WE.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"

# 1) 解析版本号
if [ $# -ge 1 ]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
fi
DMG_NAME="WE-${VERSION}.dmg"
VOL_NAME="WE ${VERSION}"
STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "=== Building WE ${VERSION} ==="

# 2) Release 构建
echo "[1/5] swift build -c release..."
swift build -c release

# 3) 组装 .app bundle
echo "[2/5] Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/release/WE" "$APP_MACOS/WE"
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"

# 4) ad-hoc 签名（每个 release 重签 hash 会变；用户需用 xattr -cr 清除 quarantine）
echo "[3/5] Codesigning (ad-hoc)..."
codesign --force --deep --sign - --options runtime "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE" || {
    echo "ERROR: codesign verification failed"
    exit 1
}

# 5) 准备 DMG staging 目录
echo "[4/5] Staging DMG content..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/WE.app"
ln -s /Applications "$STAGING/Applications"
cp scripts/INSTALL.txt "$STAGING/INSTALL.txt"

# 6) 制作 DMG（UDZO 压缩格式，最常用）
echo "[5/5] Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

# 清理 staging
rm -rf "$STAGING"

# 输出
SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo ""
echo "=== Done ==="
echo "  DMG:     $DMG_PATH"
echo "  Volume:  $VOL_NAME"
echo "  Size:    $SIZE"
echo "  Version: $VERSION"
echo ""
echo "Test:    open $DMG_PATH"
echo "Install: drag WE.app to /Applications, then run:"
echo "         xattr -cr /Applications/WE.app"
