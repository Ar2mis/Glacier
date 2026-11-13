#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -D GLACIER_TESTING -O -parse-as-library -target arm64-apple-macos26.0 Sources/*.swift Tests/SessionVerify.swift -o .build/verify-session -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation -framework Translation
.build/verify-session
