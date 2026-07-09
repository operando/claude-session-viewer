#!/bin/bash
# ClaudeSessionViewer.app (Phase 2: Swiftネイティブ版・Node不要) をビルドする
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeSessionViewer"
BUNDLE="$APP_NAME.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
RES_DIR="$BUNDLE/Contents/Resources"

mkdir -p "$MACOS_DIR" "$RES_DIR"

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  Sources/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

# UI一式をバンドルに同梱 (server.jsは不要)
cp ../../index.html ../../marked.min.js "$RES_DIR/"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeSessionViewer</string>
    <key>CFBundleIdentifier</key>
    <string>local.claude-session-viewer</string>
    <key>CFBundleName</key>
    <string>Claude Session Viewer</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Session Viewer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE" 2>/dev/null || true

echo "✅ Built: $(pwd)/$BUNDLE"
