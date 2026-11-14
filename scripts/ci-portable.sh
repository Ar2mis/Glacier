#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_daily_workflow.py
# No Apple SDK or Swift execution: these are portable automation checks only.
for script in scripts/*.sh; do bash -n "$script"; done
python3 - <<'PY'
import ast
from pathlib import Path
for path in [*Path('scripts').glob('*.py'), *Path('Tests').glob('test_*.py')]:
    ast.parse(path.read_text(), filename=str(path))
PY
python3 -m unittest discover -s Tests -p 'test_*.py' -v
