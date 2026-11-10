#!/usr/bin/env bash
# Builds a Helm release from this checkout. Everything lands in dist/, which is emptied first:
#   Helm-<version>.dmg   a compressed, read-only disk image with Helm.app and a link to Applications
#   Helm-<version>.zip   the same app, zipped with ditto, without extended attributes (the zip step says why)
#   SHA256SUMS.txt       checksums of both, for `shasum -a 256 -c SHA256SUMS.txt`
#   release-notes.md     the text of the GitHub release; "What's new" comes from docs/releases/<version>.md
#                        (a pre-release such as 0.2-beta.1 falls back to docs/releases/0.2.md)
#
# usage: scripts/release/make_release.sh [version]
#   version  Such as 0.2 or 0.2-beta.1. It must be the app's version in App/Info.plist, with an optional
#            suffix after a "-", so the files and the app agree. Left out, it is the app's version.
#            A leading "v" is dropped.
#
# HELM_RELEASE_SCRATCH=<folder>  Build there and keep it, so the next build is faster. Otherwise a
#                                temporary folder is used, and removed when the build succeeds.
# HELM_RELEASE_NOTES=<file>      Read "What's new" from this file instead.
#
# It builds the folder as it is. On a Mac, uncommitted changes are built too, and the notes say so.
# On GitHub Actions it stops instead, because the attestation names the commit.
#
# Needs Xcode and XcodeGen, and nothing else: no network, no signing identity and no installs.
# The app is signed ad hoc, as the project is. docs/RELEASING.md says why it isn't notarized yet.
# Written for the bash 3.2 that comes with macOS.
set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

[ "$(uname -s)" = Darwin ] || die "Helm releases are built on a Mac."
cd "$(dirname "$0")/../.."
root=$PWD
[ -f App/project.yml ] && [ -f App/Info.plist ] || die "Run this from a Helm checkout: App/project.yml is missing."
for tool in xcodebuild xcodegen hdiutil ditto codesign shasum lipo xattr unzip zipinfo python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is missing. Releases need Xcode and XcodeGen (https://github.com/yonaskolb/XcodeGen)."
done

# The version: the argument, or else the app's own. No "+": GitHub renames files with one, and
# SHA256SUMS.txt would then name files the release doesn't have.
app_version=$(plist App/Info.plist CFBundleShortVersionString)
build_number=$(plist App/Info.plist CFBundleVersion)
version=${1:-$app_version}
version=${version#v}
pattern='^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
[[ $version =~ $pattern ]] || die "\"$version\" isn't a version. Use numbers and dots, such as 0.2, with an optional suffix such as -beta.1."
case $version in
    "$app_version" | "$app_version"-*) ;;
    *) die "Version $version doesn't match the app, which App/Info.plist says is $app_version. Change CFBundleShortVersionString there first, or leave the version out." ;;
esac

# What the files are built from: the commit, plus any changes in the folder.
commit=""
changes=""
if command -v git >/dev/null 2>&1 && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    commit=$(git rev-parse HEAD)
    changes=$(git status --porcelain)
fi
if [ -n "$changes" ]; then
    printf '%s\n' "$changes" >&2
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        die "The checkout has the changes above, which aren't in commit $commit. The files would not match the commit their attestation names."
    fi
    printf 'warning: The changes above are not committed. They go into this build, and the notes will say so.\n' >&2
fi

# A pre-release such as 0.2-beta.1 may share 0.2's notes.
notes_source=${HELM_RELEASE_NOTES:-docs/releases/$version.md}
if [ -z "${HELM_RELEASE_NOTES:-}" ] && [ ! -f "$notes_source" ] && [ -f "docs/releases/$app_version.md" ]; then
    notes_source="docs/releases/$app_version.md"
fi
if [ ! -f "$notes_source" ]; then
    printf 'warning: %s is missing, so the notes will say nothing was written for this version.\n' "$notes_source" >&2
    notes_source=""
fi

# Scratch space for the build, the staging folder and the mount point.
own_scratch=""
if [ -n "${HELM_RELEASE_SCRATCH:-}" ]; then
    mkdir -p "$HELM_RELEASE_SCRATCH"
    scratch=$(cd "$HELM_RELEASE_SCRATCH" && pwd -P)
else
    tmp=${TMPDIR:-/tmp}
    scratch=$(mktemp -d "${tmp%/}/helm-release.XXXXXX")
    scratch=$(cd "$scratch" && pwd -P)
    own_scratch=1
fi
mounted=""
cleanup() {
    local status=$?
    if [ -n "$mounted" ]; then hdiutil detach -quiet -force "$mounted" >/dev/null 2>&1 || true; fi
    if [ -n "$own_scratch" ]; then
        if [ "$status" -eq 0 ]; then rm -rf "$scratch"; else printf 'The build files are kept in %s\n' "$scratch" >&2; fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# hdiutil now and then answers "Resource busy" while macOS looks at a new disk image, so it gets three tries.
retry() {
    local attempt=1
    until "$@"; do
        [ "$attempt" -lt 3 ] || return 1
        printf '%s failed. Trying again in %s seconds.\n' "$1 $2" "$((attempt * 5))" >&2
        sleep $((attempt * 5))
        attempt=$((attempt + 1))
    done
}
detach() {
    retry hdiutil detach -quiet "$1" || hdiutil detach -quiet -force "$1"
    mounted=""
}

step "Checking the source for privacy"
# The source check sees what the binary check can't, such as a read from a web address or a tool Helm starts.
python3 -I scripts/privacy_check.py || die "The source failed the privacy check above."

step "Generating the Xcode project from App/project.yml"
xcodegen generate --spec App/project.yml --quiet

step "Building Helm $version in Release. This takes a few minutes."
derived="$scratch/DerivedData"
log="$scratch/xcodebuild.log"
# Ad hoc ("-") on purpose, whatever the machine has: no signing identity is used or needed.
# The hardened runtime stays on, and the debugging entitlement is left out.
if ! xcodebuild -project App/Helm.xcodeproj -scheme Helm -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build > "$log" 2>&1; then
    grep -E ': error: ' "$log" | head -n 40 >&2 || true
    tail -n 30 "$log" >&2
    die "The build failed. The whole log is in $log"
fi
if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::group::Build log\n'
    cat "$log"
    printf '::endgroup::\n'
fi
printf 'Built, with %s compiler warnings.' "$(grep -c ': warning: ' "$log" || true)"
if [ -z "$own_scratch" ]; then printf ' The whole log is in %s' "$log"; fi
printf '\n'
app="$derived/Build/Products/Release/Helm.app"
[ -d "$app" ] || die "The build finished, but $app is missing."

step "Checking the app"
codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign --display --verbose=2 "$app" 2>&1)
grep -E '^(Identifier|Format|CodeDirectory|Signature)' <<<"$signature" || true
grep -q '^Signature=adhoc' <<<"$signature" || die "The app should be signed ad hoc."
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$signature" || die "The app should have the hardened runtime."
entitlements=$(codesign --display --entitlements - "$app" 2>/dev/null || true)
if grep -q 'get-task-allow' <<<"$entitlements"; then
    die "The app shouldn't carry the debugging entitlement (get-task-allow)."
fi
built_version=$(plist "$app/Contents/Info.plist" CFBundleShortVersionString)
built_number=$(plist "$app/Contents/Info.plist" CFBundleVersion)
[ "$built_version" = "$app_version" ] && [ "$built_number" = "$build_number" ] ||
    die "The built app says it is $built_version ($built_number), not $app_version ($build_number)."
min_os=$(plist "$app/Contents/Info.plist" LSMinimumSystemVersion)
archs=$(lipo -archs "$app/Contents/MacOS/Helm")
# The notes and the README promise both kinds of Mac, and check_binary_privacy.sh sees short strings only in the
# Intel slice.
for arch in arm64 x86_64; do
    case " $archs " in *" $arch "*) ;; *) die "The app should be built for Apple silicon and Intel Macs (arm64 and x86_64), but it's built for $archs." ;; esac
done
printf 'Helm %s (%s) for macOS %s or later, built for %s\n' "$built_version" "$built_number" "$min_os" "$archs"

step "Checking the app for privacy"
# No network or identifier code, no web addresses, no paths from this Mac, no entitlements.
bash "$root/scripts/release/check_binary_privacy.sh" "$app" || die "The app failed the privacy check above."
# Each slice's code directory hash, for the notes. A copy that passes codesign --verify with these hashes as its
# requirement is this build, unchanged: --verify checks every slice. The hashes alone, as codesign -d shows them,
# could be copied.
cdhash_arm=$(codesign -dvvv --arch arm64 "$app" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)
cdhash_intel=$(codesign -dvvv --arch x86_64 "$app" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)
[ -n "$cdhash_arm" ] && [ -n "$cdhash_intel" ] || die "codesign didn't give the app's CDHash for both kinds of Mac."

dist="$root/dist"
rm -rf "$dist"
mkdir -p "$dist"
dmg="$dist/Helm-$version.dmg"
zip="$dist/Helm-$version.zip"
mnt="$scratch/mount"
mkdir -p "$mnt"

step "Making Helm-$version.dmg"
stage="$scratch/dmg"
rm -rf "$stage"
mkdir -p "$stage"
ditto "$app" "$stage/Helm.app"
ln -s /Applications "$stage/Applications"
cp App/AppIcon.icns "$stage/.VolumeIcon.icns"
rw="$scratch/Helm-rw.dmg"
retry hdiutil create -quiet -ov -volname Helm -fs HFS+ -format UDRW -srcfolder "$stage" "$rw"
retry hdiutil attach -quiet -readwrite -nobrowse -noverify -noautoopen -mountpoint "$mnt" "$rw"
mounted=$mnt
# The volume shows Helm's icon: .VolumeIcon.icns at its root, plus the root's "has custom icon" Finder flag.
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$mnt"
detach "$mnt"
retry hdiutil convert -quiet -ov "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
rm -f "$rw"
rm -rf "$stage"

step "Checking the disk image"
retry hdiutil verify -quiet "$dmg"
retry hdiutil attach -quiet -readonly -nobrowse -noverify -noautoopen -mountpoint "$mnt" "$dmg"
mounted=$mnt
[ -d "$mnt/Helm.app" ] || die "Helm.app is missing from the disk image."
[ -L "$mnt/Applications" ] && [ "$(readlink "$mnt/Applications")" = /Applications ] || die "The Applications link is missing from the disk image."
[ -f "$mnt/.VolumeIcon.icns" ] || die "The volume icon is missing from the disk image."
codesign --verify --deep --strict "$mnt/Helm.app"
ls -A "$mnt"
detach "$mnt"

step "Making Helm-$version.zip"
# Without extended attributes. ditto would otherwise store them (com.apple.provenance, for one) as ._ files
# inside the app. macOS puts those back, but other unzip tools leave them in place, which breaks the
# app's signature, and macOS then calls Helm damaged. The signature itself lives in files, not attributes.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$zip"
listing=$(zipinfo -1 "$zip")
if grep -Eq '(^|/)(\._|__MACOSX/)' <<<"$listing"; then
    die "The zip holds ._ files, which break the app's signature when another tool unzips it."
fi
# Unzipped the macOS way (Finder, Safari) and the plain way (unzip, and most other tools).
for tool in ditto unzip; do
    unzipped="$scratch/unzipped-$tool"
    rm -rf "$unzipped"
    mkdir -p "$unzipped"
    if [ "$tool" = ditto ]; then ditto -x -k "$zip" "$unzipped"; else unzip -q "$zip" -d "$unzipped"; fi
    codesign --verify --deep --strict "$unzipped/Helm.app" || die "Helm.app's signature breaks when $tool unzips the zip."
    rm -rf "$unzipped"
done
printf 'The app inside unzips intact with ditto and with unzip.\n'

step "Writing SHA256SUMS.txt"
(cd "$dist" && shasum -a 256 "Helm-$version.dmg" "Helm-$version.zip" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt)

step "Writing release-notes.md"
repo=${GITHUB_REPOSITORY:-HuseynAkh/Helm}
case ${min_os%%.*} in
    14) os_name="macOS 14 Sonoma" ;;
    15) os_name="macOS 15 Sequoia" ;;
    26) os_name="macOS 26 Tahoe" ;;
    *) os_name="macOS ${min_os%.0}" ;;
esac
dirty=""
[ -z "$changes" ] || dirty=" (with uncommitted changes)"
xcode="$(xcodebuild -version | sed -n 1p) ($(xcodebuild -version | sed -n 's/^Build version //p'))"
built_on="macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

{
    printf "## What's new\n\n"
    if [ -n "$notes_source" ]; then
        # The notes file's own top heading, if it has one, gives way to the release's title.
        awk 'NR == 1 && /^# / { next } !started && /^[[:space:]]*$/ { next } { started = 1; print }' "$notes_source"
    else
        printf 'No notes were written for this version.\n'
    fi
    printf '\n## Requirements\n\n'
    printf -- '- %s or later.\n' "$os_name"
    printf -- '- A Mac with Apple silicon or an Intel processor.\n'
    printf '\n## Install\n\n'
    printf 'Open `Helm-%s.dmg` and drag Helm onto Applications, then eject the disk image. ' "$version"
    printf '`Helm-%s.zip` holds the same app, if you prefer a zip: open it and move Helm to Applications.\n' "$version"
    cat <<'EOF'

## First launch

Helm isn't notarized by Apple yet, so macOS stops it the first time you open it.

- **macOS 15 Sequoia and later:** open Helm, and click **Done** when macOS says it can't verify it. Open **System Settings › Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to the line about Helm. Confirm with your login password or Touch ID, and click **Open Anyway** again if macOS asks. The button shows for about an hour after you try to open Helm.
- **macOS 14 Sonoma:** Control-click Helm in Applications, choose **Open**, then click **Open** again.

You do this once for each new version.

## Updating

Quit Helm, then drag the new Helm onto Applications and choose **Replace**. Helm is signed ad hoc, so macOS treats each version as a new app: open it as in "First launch", and turn Full Disk Access on again in **System Settings › Privacy & Security › Full Disk Access**. Remove Helm from the list with **−**, then add it back with **+**.

## Verify the download

`SHA256SUMS.txt` lists the SHA-256 of the disk image and the zip. In the folder you downloaded them to, run:

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Each file you downloaded should be followed by `OK`.

EOF
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        printf 'GitHub Actions built these files from the commit below and signed a build provenance attestation for each. '
        printf 'To check one, use the [GitHub CLI](https://cli.github.com), signed in to any GitHub account with `gh auth login`:\n\n'
        printf '```sh\ngh attestation verify Helm-%s.dmg --repo %s\ngh attestation verify Helm-%s.zip --repo %s\n```\n\n' "$version" "$repo" "$version" "$repo"
    else
        printf 'These files were built outside GitHub Actions, so they have no build provenance attestation.\n\n'
    fi
    printf '| File | SHA-256 |\n|---|---|\n'
    while read -r sum name; do printf '| %s | `%s` |\n' "$name" "$sum"; done < "$dist/SHA256SUMS.txt"
    printf "\nAfter installing, this checks that your copy of Helm is intact and is this build: each part must match its "
    printf "signature, and its code directory hashes (CDHashes) must be this build's. It should end with \`explicit requirement satisfied\`:\n\n"
    printf '```sh\n'
    printf "codesign --verify --deep --strict --verbose=1 -R='cdhash H\"%s\" or cdhash H\"%s\"' /Applications/Helm.app\n" "$cdhash_arm" "$cdhash_intel"
    printf '```\n'
    cat <<'EOF'

## Privacy

Helm makes no network connections of its own: no accounts, analytics, telemetry or update checks. What Helm keeps, such as your settings, tabs and bookmarks, stays on your Mac.

---

EOF
    if [ -n "$commit" ]; then
        printf 'Built from commit [`%s`](https://github.com/%s/commit/%s)%s ' "$(printf '%s' "$commit" | cut -c1-12)" "$repo" "$commit" "$dirty"
    else
        printf 'Built '
    fi
    printf 'with %s on %s' "$xcode" "$built_on"
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
        printf ', in [GitHub Actions run %s](%s/%s/actions/runs/%s)' "$GITHUB_RUN_ID" "${GITHUB_SERVER_URL:-https://github.com}" "$repo" "$GITHUB_RUN_ID"
    fi
    printf '.\n'
} > "$dist/release-notes.md"

step "Done: Helm $version is in dist/"
ls -lh "$dist"
printf '\n'
cat "$dist/SHA256SUMS.txt"
if [ -z "$notes_source" ]; then
    printf '\nwarning: No notes were found for %s. Write docs/releases/%s.md before tagging.\n' "$version" "$version" >&2
fi
if [ -n "$changes" ]; then
    printf '\nwarning: This build includes changes that are not committed, so it is not the build of commit %s.\n' "${commit:-?}" >&2
fi
