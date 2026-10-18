#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_ROOT="$PWD"
# SwiftPM embeds source locations in the binary. Build in an anonymous path so
# those literals cannot expose the builder's account or clone location.
BUILD_ROOT="$(mktemp -d /tmp/daikinac-menubar-build.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
cp "$PROJECT_ROOT/Package.swift" "$BUILD_ROOT/Package.swift"
cp "$PROJECT_ROOT/Package.resolved" "$BUILD_ROOT/Package.resolved"
cp -R "$PROJECT_ROOT/Sources" "$BUILD_ROOT/Sources"
# Dependencies come only from the pinned revisions in Package.resolved.
swift build --package-path "$BUILD_ROOT" --scratch-path "$BUILD_ROOT/.build" -c release --force-resolved-versions \
  -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_ROOT=." \
  -Xswiftc -file-prefix-map -Xswiftc "$BUILD_ROOT=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_ROOT=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$BUILD_ROOT=." \
  -Xcc "-ffile-prefix-map=$PROJECT_ROOT=." \
  -Xcc "-ffile-prefix-map=$BUILD_ROOT=."
APP="$PROJECT_ROOT/dist/DaikinAC-menubar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_ROOT/.build/release/DaikinACMenubar" "$APP/Contents/MacOS/DaikinACMenubar"
strip -S "$APP/Contents/MacOS/DaikinACMenubar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DaikinACMenubar</string>
<key>CFBundleIdentifier</key><string>br.local.DaikinAC</string>
<key>CFBundleName</key><string>DaikinAC-menubar</string>
<key>CFBundleDisplayName</key><string>DaikinAC-menubar</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Find and control your Daikin air conditioner directly on your Wi-Fi network, without going through the cloud.</string>
<key>NSBonjourServices</key><array><string>_iota._tcp</string></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - --identifier br.local.DaikinAC "$APP"
printf 'App created at %s\n' "$APP"
