#!/bin/bash
# 编译并打包成 SafeClean.app（放在本目录下）
#
# 可选环境变量：
#   BUNDLE_ID      应用的 bundle id（默认见下方）
#   SIGN_IDENTITY  用来签名的证书名或 SHA-1；不设置时会找名为 "SafeClean Local Signing" 的本地证书，
#                  找不到就用临时签名（ad-hoc）。用固定证书签名的好处：系统权限（完全磁盘访问等）
#                  跟着证书走，重新编译后不用再授权。
set -euo pipefail
cd "$(dirname "$0")"

APP="SafeClean.app"
BUILD=".build/bundle"
BUNDLE_ID="${BUNDLE_ID:-io.github.thomaswang0916.SafeClean}"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"
cp .build/release/SafeClean "$APP/Contents/MacOS/SafeClean"

# 图标只在第一次生成
if [ ! -f "$BUILD/AppIcon.icns" ]; then
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift Scripts/make_icon.swift "$BUILD/icon_1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SafeClean</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>SafeClean</string>
  <key>CFBundleDisplayName</key><string>SafeClean</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Scan your Desktop for large and duplicate files.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Scan your Documents for large and duplicate files.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Scan Downloads for old and duplicate files.</string>
  <key>NSAppDataUsageDescription</key><string>Scan caches and logs inside app containers, and find leftover files when uninstalling apps.</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  for name in "SafeClean Local Signing" "MacCleaner Local Signing"; do
    IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk -v n="\"$name\"" 'index($0, n) {print $2; exit}')
    [ -n "$IDENTITY" ] && break
  done
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "⚠️  没找到本地签名证书，使用临时签名（每次重新编译后需要重新授予完全磁盘访问权限）"
  codesign --force --sign - "$APP"
fi
echo "✅ 已生成 $(pwd)/$APP"
