#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --locked --manifest-path core/Cargo.toml
APP="$PWD/build/Mi Air.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx14.0 Sources/*.swift -o "$APP/Contents/MacOS/MiAir" -framework SwiftUI -framework AppKit -framework Security
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp -R licenses "$APP/Contents/Resources/"
cp core/target/release/mi-air-core "$APP/Contents/Resources/mi-air-core"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.miair.menu</string>
<key>CFBundleName</key><string>Mi Air</string>
<key>CFBundleExecutable</key><string>MiAir</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSLocalNetworkUsageDescription</key><string>连接你选择的米家空调，读取状态并执行控制。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/mi-air-core"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
