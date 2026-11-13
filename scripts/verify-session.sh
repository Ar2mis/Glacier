#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swift build -c release
CORE_BIN=$(swift build -c release --show-bin-path)
swiftc -swift-version 5 -D GLACIER_TESTING -O -parse-as-library -target arm64-apple-macos26.0 -I "$CORE_BIN/Modules" -L "$CORE_BIN" -lGlacierCore Sources/*.swift Tests/SessionVerify.swift -o .build/verify-session -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation -framework Translation
.build/verify-session
