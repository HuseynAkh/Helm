#!/usr/bin/env bash
# Takes the README's pictures (docs/images/) from a made-up home folder, so they never show anyone's real files,
# disks or free space. The run uses fixture folders, a private pasteboard and a stand-in Trash, like the smoke,
# and like the smoke it's kept off the network.
# usage: bash scripts/readme/make_readme_images.sh [scratch-path]
# The run stays in the background: its windows are invisible and never take the screen. HELM_README_FOREGROUND=1
# brings Helm to the front first, so the window buttons are drawn in colour.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
scratch="${1:-/tmp/build-helm-readme}"
root="$PWD/.build/readme"
fix="$root/fixture"
rm -rf "$root"
mkdir -p "$fix/support" "$root/shots" docs/images
swift scripts/readme/make_demo_home.swift "$fix/home" || exit 1
python3 - "$fix" "$root" <<'PY'
import os, sys
fix, root = sys.argv[1], sys.argv[2]
steps = open('scripts/readme/readme_shots.txt', encoding='utf-8').read()
if not os.environ.get('HELM_README_FOREGROUND'):
    steps = '\n'.join(line for line in steps.split('\n') if line.strip() != 'activate') + '\n'
steps = steps.replace('@FIX@', fix).replace('@SHOTS@', os.path.join(root, 'shots'))
open(os.path.join(root, 'steps.txt'), 'w', encoding='utf-8').write(steps)
PY
swift build --scratch-path "$scratch" --target HelmDev || exit 1
bin="$(swift build --scratch-path "$scratch" --show-bin-path)/HelmDev"
# The smoke's profile, as host_smoke.sh uses it: macOS stops HelmDev at any try at the network.
sandbox=()
profile="$PWD/scripts/rebuild/deny-network.sb"
if ! command -v sandbox-exec >/dev/null 2>&1; then
    echo "warning: sandbox-exec is missing, so this run isn't kept off the network." >&2
elif ! sandbox-exec -f "$profile" /usr/bin/true; then
    echo "error: sandbox-exec can't apply $profile." >&2
    exit 1
else
    sandbox=(sandbox-exec -f "$profile")
    echo "Network: blocked. Any try at it stops HelmDev."
fi
${sandbox[@]+"${sandbox[@]}"} "$bin" --home "$fix/home" --support "$fix/support" --smoke "$root/steps.txt" 2>&1 | tee "$root/result.log" | grep -E '^(FAIL|MSG|SMOKE_END)'
code=${PIPESTATUS[0]}
chmod 755 "$fix/home/.Trash" 2>/dev/null
if [ "$code" -eq 137 ] && [ ${#sandbox[@]} -gt 0 ]; then echo "HelmDev was stopped, most likely for trying to use the network; see $root/result.log"; exit 1; fi
if grep -q '^FAIL' "$root/result.log"; then echo "Some steps failed; see $root/result.log"; exit 1; fi
if ! grep -qE '^SMOKE_(QUIT|END)' "$root/result.log"; then echo "The run stopped before its last step; see $root/result.log"; exit 1; fi
swiftc -O scripts/readme/frame_shot.swift -o "$root/frame_shot" || exit 1
frame() { "$root/frame_shot" "$root/shots/$1.png" "docs/images/$1.png" "$2" "${3:-26}" ${4:-} || exit 1; }
frame hero-dark 1600
frame hero-light 1600
frame list-light 1280
frame recent-dark 1280
frame search-dark 1280
frame settings-sidebar-light 1000 16
frame trash-card-light 1280
frame setup-light 900 16
frame view-options-dark 600 14
sips -Z 512 docs/brand/logo-variants/variant-4-isometric.png --out docs/images/helm-icon.png >/dev/null || exit 1
echo "Pictures in docs/images. Captures and log: $root"
