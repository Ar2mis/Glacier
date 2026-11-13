#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -O -parse-as-library Sources/SpeechCapture.swift Sources/GPTTranslator.swift Tests/StreamVerify.swift -o .build/verify-stream
.build/verify-stream
