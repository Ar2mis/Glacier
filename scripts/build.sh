#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Glacier.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
swift scripts/make-icon.swift .build/Glacier.iconset
iconutil -c icns .build/Glacier.iconset -o "$APP/Contents/Resources/Glacier.icns"
swift build -c release
BIN_PATH=$(swift build -c release --show-bin-path)
cp "$BIN_PATH/Glacier" "$APP/Contents/MacOS/LectureCaptions"
cp THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LectureCaptions</string>
<key>CFBundleIdentifier</key><string>local.ar2mis.lecturecaptions</string>
<key>CFBundleName</key><string>Glacier</string>
<key>CFBundleDisplayName</key><string>Glacier</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Glacier</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>将讲话实时转为字幕。WhisperKit/Apple 在本机处理；选择 OpenAI/Deepgram 时会发送音频到该服务。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>将英语讲话转为实时字幕。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
