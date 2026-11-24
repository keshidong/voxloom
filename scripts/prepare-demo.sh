#!/bin/bash
# Prepare and build the legacy voice demo.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [ "$#" -gt 0 ]; then
    exec bash scripts/prepare-app.sh "$@"
fi
bash scripts/prepare-app.sh --prepare-only
exec python3 scripts/make-demo.py
