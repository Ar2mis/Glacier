#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swift build -c release
CORE_BIN=$(swift build -c release --show-bin-path)
swiftc -I "$CORE_BIN" -I "$CORE_BIN/Modules" -L "$CORE_BIN" -lGlacierCore -swift-version 5 -O -parse-as-library Sources/SpeechCapture.swift Sources/GPTTranslator.swift Tests/StreamVerify.swift -o .build/verify-stream
.build/verify-stream
