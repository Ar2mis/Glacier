#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_store_release.py
swift build -c release
CORE_BIN=$(swift build -c release --show-bin-path)
# The fallback compiles the exact APP_STORE source branch with the installed Mac
# SDK, then tests an ad-hoc sandbox bundle. It does NOT validate an Xcode Archive.
if xcodebuild -version >/dev/null 2>&1; then
  xcodebuild -project Glacier.xcodeproj -scheme GlacierMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath .build/store-xcode CODE_SIGNING_ALLOWED=NO build
  APP="$PWD/.build/store-xcode/Build/Products/Release/Glacier.app"
else
  echo 'Full Xcode unavailable: compiling store source + sandbox smoke bundle; Archive remains unverified.'
  APP="$PWD/.build/store-smoke/Glacier.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -swift-version 5 -D APP_STORE -O -parse-as-library -target arm64-apple-macos26.0 \
    -I "$CORE_BIN" -I "$CORE_BIN/Modules" -L "$CORE_BIN" -lGlacierCore Sources/*.swift \
    -o "$APP/Contents/MacOS/Glacier" -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation -framework Translation
  python3 - "$APP" <<'PY'
import sys,plistlib
from pathlib import Path
p=plistlib.loads(Path('Config/Mac-Info.plist').read_bytes())
p.update(CFBundleExecutable='Glacier',CFBundleIdentifier='com.ziruochen.glacier',CFBundleName='Glacier',CFBundleDisplayName='Glacier',CFBundleShortVersionString='0.7.0',CFBundleVersion='12',LSMinimumSystemVersion='26.0',GlacierDistribution='store')
Path(sys.argv[1],'Contents/Info.plist').write_bytes(plistlib.dumps(p))
PY
  cp PRIVACY_POLICY.md SUPPORT.md THIRD_PARTY_NOTICES.txt Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
  swift scripts/make-icon.swift .build/Glacier.iconset
  iconutil -c icns .build/Glacier.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --options runtime --entitlements Config/GlacierMac.entitlements "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" > .build/store-entitlements.plist 2>/dev/null
python3 - <<'PY'
import plistlib
from pathlib import Path
actual=plistlib.loads(Path('.build/store-entitlements.plist').read_bytes())
expected=plistlib.loads(Path('Config/GlacierMac.entitlements').read_bytes())
assert all(actual.get(k)==v for k,v in expected.items())
PY
nm -u "$APP/Contents/MacOS/Glacier" > .build/store-imported-symbols.txt
if rg 'AXUIElement|AXIsProcessTrusted|CGEventPost' .build/store-imported-symbols.txt; then
  echo 'Store binary unexpectedly contains cross-app automation' >&2; exit 1
fi
"$APP/Contents/MacOS/Glacier" --verify-store-environment
printf 'PASS: APP_STORE compile, signed entitlement inspection, no AX automation imports, sandbox storage smoke\n'
