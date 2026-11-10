#!/usr/bin/env bash
# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")/../.." || exit 1
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
if [[ -f /workspace/toolchains/env.sh ]]; then source /workspace/toolchains/env.sh; fi
scratch="${HELM_K11_SCRATCH:-/tmp/build-K11}"
plan="${HELM_PLAN_DIR:-${PLAN_DIR:-/workspace/forge/helm-plan/docs/rebuild}}"
if [[ ! -d "$plan" ]]; then echo "NOT RUN: plan directory missing: $plan" >&2; exit 1; fi
mkdir -p "$scratch/logs" || exit 1
failures=0
summary=()
run_check() {
    local name="$1"; shift
    if "$@" >"$scratch/logs/$name.log" 2>&1; then
        summary+=("PASS $name")
    else
        summary+=("FAIL $name")
        failures=$((failures + 1))
        tail -n 12 "$scratch/logs/$name.log"
    fi
}
# Explicit portable targets: never a bare swift build, even as the manifest evolves.
for target in HelmCore HelmFileSystem HelmPersistence HelmOperations HelmSearch HelmTestKit; do
    run_check "build-$target" swift build --scratch-path "$scratch" --target "$target"
done
run_check tests swift test --scratch-path "$scratch" --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'
counts=$(python3 - "$scratch/logs/tests.log" <<'PY'
import re, sys
# SwiftPM can build one bundle per test target, each with its own closing summary. Sum them all,
# so a later bundle with nothing selected cannot hide an earlier bundle's tests or failures.
tests = skipped = failures = 0
closing = re.compile(r"Test Suite '(?:All|Selected) tests' (?:passed|failed)")
summary = re.compile(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?')
lines = open(sys.argv[1]).read().splitlines()
for index, line in enumerate(lines):
    if closing.search(line) and index + 1 < len(lines):
        match = summary.search(lines[index + 1])
        if match:
            tests += int(match.group(1)); skipped += int(match.group(2) or 0); failures += int(match.group(3))
if tests == 0:
    # Linux's XCTest and simple runners print a single summary with no closing suite line.
    found = summary.findall('\n'.join(lines))
    if found:
        tests, skipped, failures = int(found[-1][0]), int(found[-1][1] or 0), int(found[-1][2])
print(tests, skipped, failures)
PY
)
read -r tests skipped test_failures <<< "$counts"
if (( tests == 0 || tests == skipped || test_failures != 0 )); then
    summary+=("FAIL XCTest nonzero discovery / failure gate")
    failures=$((failures + 1))
fi
run_check python-tests python3 -m unittest discover -s scripts/rebuild -p 'test_*.py' -v
run_check static-tests python3 -m unittest discover -s scripts -p 'test_static_checks.py' -v
run_check privacy-tests python3 -I -B -m unittest discover -s scripts -p 'test_privacy_check.py' -v
run_check static bash scripts/static_checks.sh
run_check core-type-name-fixtures python3 scripts/rebuild/check_core_type_names.py --self-test
run_check core-type-names python3 scripts/rebuild/check_core_type_names.py
run_check ui-parse bash scripts/rebuild/parse_check_ui.sh
run_check coverage python3 scripts/rebuild/check_coverage.py --parity "$plan/02-finder-parity.md" --current-state "$plan/00-current-state.md" --report-only
printf '\nPortable verification\n'
printf '%s\n' "${summary[@]}"
printf 'XCTest: %s executed; %s skipped; %s failures. Failed checks: %s\nLogs: %s/logs\n' "$tests" "$skipped" "$test_failures" "$failures" "$scratch"
echo 'Coverage is report-only; UI parse is syntax only. Neither closes feature acceptance.'
(( failures == 0 ))
