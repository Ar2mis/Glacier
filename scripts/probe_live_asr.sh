#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
  echo 'Usage: bash scripts/probe_live_asr.sh /path/to/synthetic-test-audio.wav' >&2
  echo 'Opt-in: sends recognized fixture TEXT to OpenAI using the saved key. Never use a private lecture without permission.' >&2
  exit 2
fi
swift build -c release
CORE_BIN=$(swift build -c release --show-bin-path)
source scripts/swift_core_flags.sh
swiftc -swift-version 5 -D GLACIER_TESTING -O -parse-as-library -target arm64-apple-macos26.0 \
  "${GLACIER_CORE_FLAGS[@]}" Sources/*.swift Tests/LiveASRProbe.swift -o .build/probe-live-asr \
  -framework AppKit -framework SwiftUI -framework Speech -framework AVFoundation -framework Translation
.build/probe-live-asr "$1"
