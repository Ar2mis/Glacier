#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swift build -c release
CORE_BIN=$(swift build -c release --show-bin-path)
source scripts/swift_core_flags.sh
swiftc "${GLACIER_CORE_FLAGS[@]}" -swift-version 5 -O -parse-as-library Sources/SpeechCapture.swift Sources/SentenceFeed.swift Sources/GPTTranslator.swift Tests/PipelineVerify.swift -o .build/verify-pipeline
.build/verify-pipeline
