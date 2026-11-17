#!/usr/bin/env bash
# Takes the README's pictures (docs/images/) from a made-up home folder, so they never show anyone's real files,
# disks or free space, and draws AI mode's mark (the trefoil) and the banner in docs/brand. The run uses fixture
# folders, a private pasteboard, a stand-in Trash and stand-ins for the onboarding's switches, like the smoke, and like
# the smoke it's kept off the network. AI mode answers from a scripted model (agent-script.json and
# agent-receipts.json beside the home), so no request goes to any provider.
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
python3 - "$fix" <<'PY' || exit 1
import datetime, json, os, sys
fix = sys.argv[1]

def names(*items):
    return ['@name:' + item for item in items]

# The scripted model's answers. The Organize suggestion's request holds "organize"; anything else gets a short reply.
organize = {"when": "organize", "turns": [
    {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
    {"text": "Papers go into Documents, pictures into Images and zips into Archives. The old Read Me can go.",
     "calls": [{"name": "propose_changes", "args": {
        "new_folders": [{"key": "n1", "parent": "@root", "name": "Documents"},
                        {"key": "n2", "parent": "@root", "name": "Images"},
                        {"key": "n3", "parent": "@root", "name": "Archives"}],
        "moves": [{"items": names("Boarding Pass.pdf", "Lease Agreement.pdf", "Trail Map.pdf", "Packing List.txt"), "all_in": "", "to": "n1"},
                  {"items": names("Beach Day.jpg", "Concert Poster.jpg", "Studio Portrait.png"), "all_in": "", "to": "n2"},
                  {"items": names("Invoices.zip", "Photos Backup.zip"), "all_in": "", "to": "n3"}],
        "copies": [], "renames": [], "trash": names("Read Me.txt")}}]}]}
# Whole Mac, with the Desktop on show: the home folder's listing finds Pictures/Screenshots, and both screenshots on
# the Desktop go there.
screenshots = {"when": "file my screenshots", "turns": [
    {"calls": [{"name": "list_folder", "args": {"folder": "@home", "depth": 2, "after": ""}},
               {"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
    {"text": "Your screenshots go into Screenshots in Pictures, with the others.",
     "calls": [{"name": "propose_changes", "args": {
        "new_folders": [], "copies": [], "renames": [], "trash": [],
        "moves": [{"items": names("Screenshot 2026-11-08 at 10.42.12.png", "Screenshot 2026-11-12 at 14.20.05.png"),
                   "all_in": "", "to": "@name:Screenshots"}]}}]}]}
# Read contents, in Documents/Scans: the names say nothing, so the model asks Helm what is inside, and files the two
# receipts and the invoice by what they say.
scans = names("IMG_1988.jpg", "IMG_2041.jpg", "Scan 2026-11-03.pdf", "Scan 2026-11-09.pdf")
sort_scans = {"when": "sort these scans", "turns": [
    {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
    {"calls": [{"name": "read_contents", "args": {"ids": scans}}]},
    {"text": "Two photos are receipts, from Harbour Cafe and Corner Market, and one scan is an invoice from Studio Maple. The lease letter stays.",
     "calls": [{"name": "propose_changes", "args": {
        "new_folders": [{"key": "n1", "parent": "@root", "name": "Receipts"},
                        {"key": "n2", "parent": "@root", "name": "Invoices"}],
        "moves": [{"items": names("IMG_1988.jpg", "IMG_2041.jpg"), "all_in": "", "to": "n1"},
                  {"items": names("Scan 2026-11-03.pdf"), "all_in": "", "to": "n2"}],
        "copies": [], "renames": [], "trash": []}}]}]}
anything = {"when": "*", "turns": [{"text": "I can organize, move and copy files in these folders."}]}
rules = [organize, screenshots, sort_scans, anything]
models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
# AI search: PDFs named like an invoice from the last two months, newest first.
today = datetime.date.today()
plan = {"sort": "newest", "queries": [
    {"name_any": ["invoice"], "kinds": ["pdf"], "date_field": "modified",
     "date_from": (today - datetime.timedelta(days=60)).isoformat(), "date_to": today.isoformat()}]}
rank = {"ranked": [{"row": row, "why": ["name", "kind", "date"]} for row in range(1, 4)]}
script = {"rules": rules, "searchPlan": plan, "searchRank": rank, "models": models}
# AI search with Read contents: the word "receipt", looked for inside pictures on this Mac. Helm keeps a word to look
# for inside files only when the person typed it.
receipts = {"rules": rules, "models": models, "searchRank": {"ranked": []},
            "searchPlan": {"sort": "relevance", "queries": [
                {"content_all": ["receipt"], "name_all": [], "name_any": [], "folder_any": [], "kinds": [], "extensions": [],
                 "date_field": "none", "date_from": "", "date_to": "", "size_min_bytes": 0, "size_max_bytes": 0}]}}
for name, value in (("agent-script.json", script), ("agent-receipts.json", receipts)):
    with open(os.path.join(fix, name), 'w', encoding='utf-8') as handle:
        json.dump(value, handle, ensure_ascii=False, indent=1)
PY
# The mark and the banner, drawn from the app's own icon, which is only ever scaled.
swift scripts/readme/make_brand.swift App/AppIcon.icns docs/brand || exit 1
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
frame() { name=$1; shift; "$root/frame_shot" "$root/shots/$name.png" "docs/images/$name.png" "$@" || exit 1; }
frame ai-panel-dark 1600
frame ai-panel-light 1600
frame ai-plan-light 760 18 crop=900,52,340,548
frame ai-undo-light 760 18 crop=900,52,340,548
frame ai-whole-mac-light 1600
frame ai-contents-light 1600
frame ai-search-dark 1600
frame onboarding-ai-light 900 16
frame onboarding-access-light 900 16
frame settings-ai-light 1000 16
frame hero-dark 1600
frame hero-light 1600
frame list-light 1600
frame recent-dark 1600
frame search-dark 1600
frame header-dark 1600 14 crop=0,0,1240,52
frame settings-sidebar-light 1000 16
frame trash-card-light 1600
frame view-options-dark 600 14
echo "Pictures in docs/images, the mark and the banner in docs/brand. Captures and log: $root"
