#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -O -parse-as-library Sources/SpeechCapture.swift Sources/SentenceFeed.swift Sources/GPTTranslator.swift Tests/PipelineVerify.swift -o .build/verify-pipeline
.build/verify-pipeline
