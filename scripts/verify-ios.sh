#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Simulator build verifies the app + GlacierCore without signing or a developer account.
xcodebuild -project Glacier.xcodeproj -scheme GlacierIOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios \
  CODE_SIGNING_ALLOWED=NO build
