#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swift build -c release
CORE_BIN=$(swift build -c release --show-bin-path)
source scripts/swift_core_flags.sh
swiftc -swift-version 5 -D GLACIER_TESTING -O -parse-as-library -target arm64-apple-macos26.0 "${GLACIER_CORE_FLAGS[@]}" Sources/*.swift Tests/SessionVerify.swift -o .build/verify-session -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation -framework Translation
.build/verify-session
