#!/usr/bin/env bash
# 构建单一自包含的合并版 macOS 应用 CuktechStudioTray.app
# 内含：原生状态栏三页签主程序 + 无界面蓝牙服务(18399) + 无界面网页工作台(18383)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT_DIR/Sources"
RUNTIME_CACHE="$ROOT_DIR/.studio-runtime/Contents"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="CuktechStudioTray"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ARCH="$(uname -m)"

if [ ! -d "$RUNTIME_CACHE" ]; then
  echo "==> 本地未发现 .studio-runtime，正在从 GitHub Release 获取 CUKTECH Studio 运行库..."
  mkdir -p "$ROOT_DIR/.studio-runtime"
  TMPZIP="$(mktemp -t studiozip)"
  curl -fL "https://github.com/morty626/cuktech-studio-releases/releases/download/v0.1.0-beta.10/CUKTECH-Studio-0.1.0-beta.10-macos-arm64.zip" -o "$TMPZIP"
  ditto -x -k "$TMPZIP" "$ROOT_DIR/.studio-runtime/extracted"
  mv "$ROOT_DIR/.studio-runtime/extracted/CUKTECH Studio.app/Contents" "$RUNTIME_CACHE"
  rm -rf "$ROOT_DIR/.studio-runtime/extracted" "$TMPZIP"

  python3 - "$RUNTIME_CACHE" <<'PY'
import glob, os, sys
root = sys.argv[1]
for path in glob.glob(os.path.join(root, "Resources/desktop/frontend/dist/assets/SystemConfig-*.js")):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    patched = src.replace(
        "[`account.xiaomi.com`,`c3.account.xiaomi.com`].includes(r.hostname)",
        "(r.hostname===`account.xiaomi.com`||r.hostname.endsWith(`.account.xiaomi.com`))"
    ).replace(
        "/^data:image\\/(?:png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\\s]+$/",
        "/^data:image\\/(?:png|jpeg|gif|webp)(?:;charset=[^;,]+)?;base64,[A-Za-z0-9+/=\\s]+$/i"
    )
    with open(path, "w", encoding="utf-8") as f:
        f.write(patched)
PY
fi

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE"
# 使用 cp -a 保留 Frameworks 与 Resources 内部的全部符号链接结构
cp -a "$RUNTIME_CACHE" "$APP_BUNDLE/Contents"

echo "==> 编译原生 Swift 状态栏主入口 ($ARCH-apple-macos13.0)..."
swiftc -O \
  -target "${ARCH}-apple-macos13.0" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  "$SRC_DIR/WattStyle.swift" \
  "$SRC_DIR/Models.swift" \
  "$SRC_DIR/BackendSupervisor.swift" \
  "$SRC_DIR/Smart10uStore.swift" \
  "$SRC_DIR/LaunchAgentHelper.swift" \
  "$SRC_DIR/PanelView.swift" \
  "$SRC_DIR/PanelController.swift" \
  "$SRC_DIR/AppDelegate.swift" \
  "$SRC_DIR/main.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>CUKTECH Studio</string>
  <key>CFBundleName</key>
  <string>CUKTECH Studio</string>
  <key>CFBundleExecutable</key>
  <string>CuktechStudioTray</string>
  <key>CFBundleIconFile</key>
  <string>app-b-bolt.icns</string>
  <key>CFBundleIdentifier</key>
  <string>com.morty626.cuktechstudio</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>10</string>
  <key>CUKTECHReleaseVersion</key>
  <string>0.1.0-beta.10</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>通过蓝牙连接你的酷态科充电设备，读取实时功率并执行端口控制。</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>连接并管理你的酷态科蓝牙充电设备。</string>
  <key>NSBluetoothUsageDescription</key>
  <string>通过蓝牙连接你的酷态科充电设备，读取实时功率并执行端口控制。</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>访问你在工作台设置中选择的局域网 CUKTECH 后端。</string>
</dict>
</plist>
PLIST

echo "==> 签名合并版单应用 Bundle..."
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/CUKTECH Studio"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> 已生成自包含合并版应用: $APP_BUNDLE"

if [ "${1:-}" = "--install-user" ]; then
  USER_APPS="$HOME/Applications"
  mkdir -p "$USER_APPS"
  rm -rf "$USER_APPS/$APP_NAME.app"
  cp -a "$APP_BUNDLE" "$USER_APPS/$APP_NAME.app"
  echo "==> 已安装到: $USER_APPS/$APP_NAME.app"
fi
