#!/bin/bash
# Builds Winnie.app from the Swift package. Works with Command Line Tools alone (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

# Only the app itself: the snapshot tool is a debug-only developer utility.
swift build -c release --product Winnie
BIN=".build/release"
APP="build/Winnie.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Winnie" "$APP/Contents/MacOS/Winnie"
# SwiftPM resource bundles (MarkdownUI's dependencies) are looked up next to the executable's bundle.
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
cp Assets/icon/Winnie.icns "$APP/Contents/Resources/Winnie.icns"
cp Assets/icon/menubar.svg "$APP/Contents/Resources/menubar.svg"

# NSAppSleepDisabled: App Nap may hold a background app's timers back by minutes, and a reminder
# that fires late is a broken reminder. Winnie is idle between events, so this costs no energy.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Winnie</string>
    <key>CFBundleDisplayName</key><string>Winnie</string>
    <key>CFBundleIdentifier</key><string>local.winnie.pet</string>
    <key>CFBundleExecutable</key><string>Winnie</string>
    <key>CFBundleIconFile</key><string>Winnie</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppSleepDisabled</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Винни слушает вопрос, когда ты нажимаешь кнопку микрофона.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Винни превращает сказанное в текст вопроса. Распознавание идёт на этом Mac.</string>
</dict>
</plist>
PLIST

# A stable identity keeps the Keychain's "Always Allow" valid across rebuilds; ad-hoc
# signing (the fallback) makes macOS treat every build as a new app and ask again.
IDENTITY="Winnie Dev"
# No -v: a self-signed certificate is not "valid" in the trust sense, yet signs just fine.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null
else
    codesign --force --sign - "$APP" >/dev/null
fi
echo "Built $APP"
