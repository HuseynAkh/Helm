#!/usr/bin/env bash
# Drives the real app window through host_smoke_steps.txt against a throwaway fixture home.
# A fixture run uses a private pasteboard and a stand-in Trash, saves no window frames and reads no real
# preferences, legacy data or mounts. It never touches the user's own files.
# The app runs in the background: its windows are invisible, let clicks through and never come to the front
# (SmokeBackground.swift), so a run doesn't get in the way of whoever is using the Mac.
# The app also runs with the network blocked (scripts/rebuild/deny-network.sb). Any try at a connection, a
# host name lookup or a background download kills it, so a passing run shows Helm's own process stayed off
# the network. HELM_SMOKE_NETWORK=allow runs it without the block. Without sandbox-exec, the run warns and
# goes on without it. If sandbox-exec can't apply the profile, the run stops.
# A run passes only when no step failed and both launches got to their last step, so one that stops early fails.
# usage: scripts/rebuild/host_smoke.sh [scratch-path]
# HELM_SMOKE_ONLY=steps.txt runs only those steps from a fresh launch (fixture home as usual), then quits;
# the relaunch run is skipped unless HELM_SMOKE_ONLY_RESTORE=restore-steps.txt names steps for it.
# HELM_SMOKE_BIN=<path to an app's binary, such as Helm.app/Contents/MacOS/Helm> runs that build instead of HelmDev,
# such as a Release build made by Xcode, which links against a newer SDK than swift build does.
# HELM_SMOKE_AGENT=live runs both launches with --live-agent: AI mode's shipped wiring, with keys, disk and servers
# still stand-ins and no scripted model. The steps that need the scripted model (smoke.d/agent.txt and
# agent.restore.txt) are left out and smoke.live/off.txt is added, so with AI mode off every other step still passes
# and no model client is built.
# HELM_SMOKE_AGENT=denied runs one launch with --live-agent and only smoke.live/denied.txt, which turns AI mode on
# and picks Ollama. Its first request must get HelmDev killed by the sandbox (exit 137): the run then prints
# PASS network denied, and fails any other way.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
sandbox=()
profile="$PWD/scripts/rebuild/deny-network.sb"
if [ "${HELM_SMOKE_NETWORK:-}" = allow ]; then
    echo "Network: allowed (HELM_SMOKE_NETWORK=allow)."
elif ! command -v sandbox-exec >/dev/null 2>&1; then
    echo "warning: sandbox-exec is missing, so this run can't show that Helm stays off the network." >&2
elif ! sandbox-exec -f "$profile" /usr/bin/true; then
    echo "error: sandbox-exec can't apply $profile; HELM_SMOKE_NETWORK=allow runs without it." >&2
    exit 1
else
    sandbox=(sandbox-exec -f "$profile")
    echo "Network: blocked. Any try at it stops HelmDev."
fi
agent="${HELM_SMOKE_AGENT:-}"
case "$agent" in
    ""|live|denied) ;;
    *) echo "error: HELM_SMOKE_AGENT is live or denied." >&2; exit 1 ;;
esac
if [ "$agent" = denied ] && [ ${#sandbox[@]} -eq 0 ]; then
    echo "error: HELM_SMOKE_AGENT=denied needs the network-denied sandbox, so it can't run without it." >&2
    exit 1
fi
launch=()
[ -n "$agent" ] && launch=(--live-agent)
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
# An unreadable file among readable ones, for Skip / Stop. Unlocked again at the end so the fixture can go.
mkdir -p "$fix/home/Locked"
echo locked > "$fix/home/Locked/1-locked.txt"; echo two > "$fix/home/Locked/2-open.txt"; echo three > "$fix/home/Locked/3-open.txt"
chmod 000 "$fix/home/Locked/1-locked.txt"
ln -s "$fix/home/Documents/Reports" "$fix/home/Documents/link-to-reports"
xattr -w com.example.keep yes "$fix/home/Documents/notes.txt"
touch -t 202001020304 "$fix/home/Documents/notes.txt"
# Extra fixture files from scripts/rebuild/smoke.d/*.fixture.sh, each run with $fix and $root set.
for extra in scripts/rebuild/smoke.d/*.fixture.sh; do
    [ -f "$extra" ] && fix="$fix" root="$root" bash "$extra"
done
HELM_SMOKE_AGENT="$agent" python3 - "$fix" "$root" <<'PY' || exit 1
import os, sys, urllib.parse
fix, root = sys.argv[1], sys.argv[2]
nfc, nfd = 'café.txt', 'café.txt'
open(os.path.join(fix, 'home/Documents', nfc), 'w').write('nfc')
os.makedirs(os.path.join(fix, 'home/Documents', 'Résumés'), exist_ok=True)
import glob
agent = os.environ.get('HELM_SMOKE_AGENT', '')
# The steps that need the scripted model, which the live wiring doesn't have.
scripted_only = {'scripts/rebuild/smoke.d/agent.txt', 'scripts/rebuild/smoke.d/agent.restore.txt'}
only = 'scripts/rebuild/smoke.live/denied.txt' if agent == 'denied' else os.environ.get('HELM_SMOKE_ONLY')
steps = open(only or 'scripts/rebuild/host_smoke_steps.txt', encoding='utf-8').read()
if only and steps.rstrip('\n').split('\n')[-1].strip() != 'quit':
    steps = steps.rstrip('\n') + '\nquit\n'
# Steps from scripts/rebuild/smoke.d/*.txt run before the final quit; *.restore.txt run after the relaunch.
extras = [] if only else [f for f in sorted(glob.glob('scripts/rebuild/smoke.d/*.txt')) if not f.endswith('.restore.txt')]
if agent == 'live' and not only:
    extras = [f for f in extras if f not in scripted_only] + ['scripts/rebuild/smoke.live/off.txt']
if extras:
    body = steps.rstrip('\n').split('\n')
    tail = body.pop() if body and body[-1].strip() == 'quit' else None
    for f in extras:
        body += ['# From ' + f] + open(f, encoding='utf-8').read().rstrip('\n').split('\n')
    if tail: body.append(tail)
    steps = '\n'.join(body) + '\n'
steps = (steps.replace('@FILEURL@', 'file://' + urllib.parse.quote(os.path.join(fix, 'home/Documents')) + '/')
              .replace('@FIX@', fix).replace('@SHOTS@', os.path.join(root, 'shots'))
              .replace('@NFC@', nfc).replace('@NFD@', nfd))
open(os.path.join(root, 'steps.txt'), 'w', encoding='utf-8').write(steps)
only_restore = os.environ.get('HELM_SMOKE_ONLY_RESTORE')
restore = open(only_restore or 'scripts/rebuild/host_smoke_restore_steps.txt', encoding='utf-8').read()
for f in ([] if only else [f for f in sorted(glob.glob('scripts/rebuild/smoke.d/*.restore.txt'))
                          if not (agent == 'live' and f in scripted_only)]):
    restore = restore.rstrip('\n') + '\n# From ' + f + '\n' + open(f, encoding='utf-8').read()
restore = restore.replace('@FIX@', fix).replace('@SHOTS@', os.path.join(root, 'shots'))
open(os.path.join(root, 'restore.txt'), 'w', encoding='utf-8').write(restore)
# Only a run's last step may be quit, as HostSmokeDriver reads steps: an earlier one ends the run, and every step
# after it is skipped without a FAIL.
for name, text in (('steps', steps), ('restore steps', restore)):
    lines = [line.strip() for line in text.split('\n') if line and not line.startswith('#')]
    if 'quit' in lines[:-1]:
        sys.exit(f'error: the {name} quit before their last step, so the steps after it would never run.')
PY
if [ -n "${HELM_SMOKE_BIN:-}" ]; then
    bin="$HELM_SMOKE_BIN"
else
    swift build --scratch-path "$scratch" --target HelmDev || exit 1
    bin="$(swift build --scratch-path "$scratch" --show-bin-path)/HelmDev"
fi
# Exit 137 is SIGKILL. Inside the sandbox, that is what a try at the network gets.
killed() {
    if [ "$1" -eq 137 ] && [ ${#sandbox[@]} -gt 0 ] && [ "$agent" != denied ]; then
        echo "FAIL: HelmDev was killed in the $2, most likely for trying to use the network."
    fi
}
# A run that stops before its last step can exit 0 too, so each run must show it got there: SMOKE_QUIT from its
# final quit, or SMOKE_END after its last step.
finished() {
    grep -qE '^SMOKE_(QUIT|END)' "$1" && return 0
    echo "FAIL: the $2 stopped before its last step."
    return 1
}
${sandbox[@]+"${sandbox[@]}"} "$bin" --home "$fix/home" --support "$fix/support" --smoke "$root/steps.txt" ${launch[@]+"${launch[@]}"} 2>&1 | tee "$root/result.log" | grep -E '^(FAIL|MSG|SMOKE_END)'
code=${PIPESTATUS[0]}
if [ "$agent" = denied ]; then
    # The one way this run passes: the sandbox killed HelmDev at its first request, after every step before it passed.
    chmod 644 "$fix/home/Locked/1-locked.txt" 2>/dev/null
    for extra in scripts/rebuild/smoke.d/*.cleanup.sh; do
        [ -f "$extra" ] && fix="$fix" root="$root" bash "$extra"
    done
    if [ "$code" -eq 137 ] && ! grep -q '^FAIL' "$root/result.log"; then
        echo "PASS network denied: HelmDev was killed at its first request to the model provider. Log: $root/result.log"
        exit 0
    fi
    if [ "$code" -eq 137 ]; then
        echo "FAIL: a step failed before HelmDev's first request to the model provider."
    else
        echo "FAIL: HelmDev exited $code, not 137, so its request to the model provider wasn't stopped by the sandbox."
    fi
    exit 1
fi
killed "$code" "first run"
# The first run ends with a real Quit, which exits 0 whatever happened before it, so failures are read from the log.
grep -q '^FAIL' "$root/result.log" && code=1
if ! finished "$root/result.log" "first run" && (( code == 0 )); then code=1; fi
if [ -n "${HELM_SMOKE_ONLY:-}" ] && [ -z "${HELM_SMOKE_ONLY_RESTORE:-}" ]; then
    : > "$root/restore.log"; restore_code=0
else
    ${sandbox[@]+"${sandbox[@]}"} "$bin" --home "$fix/home" --support "$fix/support" --smoke "$root/restore.txt" ${launch[@]+"${launch[@]}"} 2>&1 | tee "$root/restore.log" | grep -E '^(FAIL|MSG|SMOKE_END)'
    restore_code=${PIPESTATUS[0]}
    killed "$restore_code" "restore run"
    grep -q '^FAIL' "$root/restore.log" && restore_code=1
    if ! finished "$root/restore.log" "restore run" && (( restore_code == 0 )); then restore_code=1; fi
fi
chmod 644 "$fix/home/Locked/1-locked.txt" 2>/dev/null
for extra in scripts/rebuild/smoke.d/*.cleanup.sh; do
    [ -f "$extra" ] && fix="$fix" root="$root" bash "$extra"
done
echo "First run exit $code, restore run exit $restore_code. PASS lines: $(cat "$root/result.log" "$root/restore.log" | grep -c '^PASS'). Screenshots and logs: $root"
(( code == 0 && restore_code == 0 ))
