#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -O -parse-as-library Sources/CaptionText.swift Sources/SpeechCapture.swift Tests/Verify.swift -o .build/verify
.build/verify "$@"
