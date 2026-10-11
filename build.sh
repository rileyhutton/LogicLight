#!/bin/bash
# Builds LogicLight.app next to this script. Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="LogicLight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling (Apple Silicon + Intel)…"
BUILD="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -o "$BUILD/LogicLight-$arch" \
    Sources/main.swift
done
lipo -create "$BUILD"/LogicLight-* -output "$APP/Contents/MacOS/LogicLight"
rm -rf "$BUILD"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LogicLight</string>
  <key>CFBundleDisplayName</key><string>LogicLight</string>
  <key>CFBundleIdentifier</key><string>com.rileyhutton.logiclight</string>
  <key>CFBundleExecutable</key><string>LogicLight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS can track the Accessibility permission.
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
echo "Move it to /Applications, open it, and grant Accessibility access when asked."
