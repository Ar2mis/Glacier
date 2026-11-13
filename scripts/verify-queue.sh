#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -O -parse-as-library Sources/SentenceFeed.swift Sources/CaptionHistory.swift Tests/CaptionQueueTests.swift -o .build/verify-queue
.build/verify-queue
