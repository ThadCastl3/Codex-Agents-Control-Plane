#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
if [[ "${1:-}" == "--skip-doctor" ]]; then
  shift
else
  "$SCRIPT_DIR/doctor.sh"
fi
[[ $# -eq 0 ]] || { echo 'Usage: verify.sh [--skip-doctor]' >&2; exit 2; }
for script in bin/*.sh lib/*.sh skills/*/scripts/*.sh; do
  [[ -f "$script" ]] || continue
  bash -n "$script"
done
python3 - <<'PY'
import ast
from pathlib import Path
for folder in ['bin', 'lib', 'hooks', 'tests', 'skills']:
    for path in Path(folder).rglob('*.py'):
        if '__pycache__' not in path.parts:
            ast.parse(path.read_text(), filename=str(path))
print('Shell and Python syntax passed.')
PY
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v 2>&1 \
  | python3 "$REPO_ROOT/lib/secret_scan.py" --mode read --format text
git diff --check
