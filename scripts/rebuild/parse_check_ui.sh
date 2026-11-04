#!/usr/bin/env bash
# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
# Syntax only: does NOT validate SDK symbols, types, actors, linking or behaviour.
set -uo pipefail
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
if [[ -f /workspace/toolchains/env.sh ]]; then source /workspace/toolchains/env.sh; fi
count=0
failed=0
for module in HelmUI HelmApp Helm; do
    [[ -d "$root/Sources/$module" ]] || continue
    while IFS= read -r -d '' file; do
        count=$((count + 1))
        swiftc -parse "$file" || failed=$((failed + 1))
    done < <(find "$root/Sources/$module" -type f -name '*.swift' -print0)
done
printf 'UI syntax only: %s files; %s failures. SDK type checking and runtime behaviour NOT verified.\n' "$count" "$failed"
if (( count == 0 )); then echo 'NOT RUN: no UI/App/executable Swift sources exist.'; fi
(( failed == 0 ))
