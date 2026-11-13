#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/verify.sh
bash scripts/verify-queue.sh
bash scripts/verify-pipeline.sh
bash scripts/verify-stream.sh
bash scripts/verify-session.sh
bash scripts/verify-soak.sh
bash scripts/verify-archive.sh
