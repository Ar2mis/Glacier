#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep commands fixed and outside the model's editable scope.
bash scripts/ci-portable.sh
bash scripts/build.sh
CORE_BIN=$(swift build -c release --show-bin-path)
"$CORE_BIN/GlacierCoreVerify"
bash scripts/verify-all.sh
