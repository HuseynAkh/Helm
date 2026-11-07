#!/usr/bin/env bash
# Drives the real app window through host_smoke_steps.txt against a throwaway fixture home.
# A fixture run uses a private pasteboard and a stand-in Trash, saves no window frames and reads no real
# preferences, legacy data or mounts. It never touches the user's own files.
# usage: scripts/rebuild/host_smoke.sh [scratch-path]
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
scratch="${1:-/tmp/build-MAC-HANDOFF}"
# Kept under .build, not /tmp: the path then has spaces and no OS-managed symlink, like a real home folder.
root="$PWD/.build/host-smoke"
fix="$root/fixture"
rm -rf "$root"
mkdir -p "$fix/home/Documents/Reports/2026" "$fix/home/Desktop" "$fix/home/Downloads" "$fix/home/.Trash" "$fix/support" "$fix/home/Templates" "$root/shots"
mkdir -p "$fix/home/Library/CloudStorage/GoogleDrive-me@example.com/Shared" "$fix/home/Library/Mobile Documents/com~apple~CloudDocs"
echo hello > "$fix/home/Documents/notes.txt"
echo a > "$fix/home/Documents/alpha.md"
echo r > "$fix/home/Documents/Reports/q1.txt"
echo z > "$fix/home/Documents/Reports/2026/q2.txt"
echo .hidden > "$fix/home/Documents/.secret"
ln -s "$fix/home/Documents/Reports" "$fix/home/Documents/link-to-reports"
xattr -w com.example.keep yes "$fix/home/Documents/notes.txt"
touch -t 202001020304 "$fix/home/Documents/notes.txt"
python3 - "$fix" "$root" <<'PY'
import os, sys, urllib.parse
fix, root = sys.argv[1], sys.argv[2]
nfc, nfd = 'café.txt', 'café.txt'
open(os.path.join(fix, 'home/Documents', nfc), 'w').write('nfc')
os.makedirs(os.path.join(fix, 'home/Documents', 'Résumés'), exist_ok=True)
steps = open('scripts/rebuild/host_smoke_steps.txt', encoding='utf-8').read()
steps = (steps.replace('@FILEURL@', 'file://' + urllib.parse.quote(os.path.join(fix, 'home/Documents')) + '/')
              .replace('@FIX@', fix).replace('@SHOTS@', os.path.join(root, 'shots'))
              .replace('@NFC@', nfc).replace('@NFD@', nfd))
open(os.path.join(root, 'steps.txt'), 'w', encoding='utf-8').write(steps)
restore = open('scripts/rebuild/host_smoke_restore_steps.txt', encoding='utf-8').read().replace('@FIX@', fix)
open(os.path.join(root, 'restore.txt'), 'w', encoding='utf-8').write(restore)
PY
swift build --scratch-path "$scratch" --target HelmDev || exit 1
bin="$(swift build --scratch-path "$scratch" --show-bin-path)/HelmDev"
"$bin" --home "$fix/home" --support "$fix/support" --smoke "$root/steps.txt" 2>&1 | tee "$root/result.log" | grep -E '^(FAIL|MSG|SMOKE_END)'
code=${PIPESTATUS[0]}
"$bin" --home "$fix/home" --support "$fix/support" --smoke "$root/restore.txt" 2>&1 | tee "$root/restore.log" | grep -E '^(FAIL|MSG|SMOKE_END)'
restore_code=${PIPESTATUS[0]}
echo "First run exit $code, restore run exit $restore_code. PASS lines: $(cat "$root/result.log" "$root/restore.log" | grep -c '^PASS'). Screenshots and logs: $root"
(( code == 0 && restore_code == 0 ))
