#!/usr/bin/env bash
# Runs the lexical checks and the privacy check. Both always run, and both must pass.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
python3 -I scripts/static_checks.py "$@" || status=1
python3 -I scripts/privacy_check.py || status=1
exit "$status"
