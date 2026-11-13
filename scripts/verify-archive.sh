#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -O -parse-as-library Sources/SpeechCapture.swift Sources/SentenceFeed.swift Sources/GPTTranslator.swift Sources/CaptionHistory.swift Sources/LectureArchive.swift Sources/WordExporter.swift Tests/ArchiveVerify.swift -o .build/verify-archive
.build/verify-archive
