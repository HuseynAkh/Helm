#!/usr/bin/env bash
# Checks a built Helm.app against the privacy promise. Helm itself never connects to a server,
# doesn't read the person's name or the Mac's name or serial number (it reads a disk's ID only to tell
# disks apart, and never keeps it), and carries no folder paths from the Mac that built it.
#
# usage: scripts/release/check_binary_privacy.sh <Helm.app>
#
# It only reads the app, and works on copies in a temporary folder. Each problem is printed, and the
# exit status is 1 if there is any (2 if the check can't run). scripts/privacy_check.py checks the
# source, and scripts/rebuild/host_smoke.sh runs the app with the network blocked. This checks what ships.
# What it can't see: a web address put together as the app runs, a web read through a call that also reads
# files (such as Data(contentsOf:)), the tools the app starts, and lookups by name at run time. Swift also keeps
# strings of up to 15 bytes inside the code, so checks 5 and 6 see those only in the Intel slice, 8 bytes at a
# time, and make_release.sh refuses a build without it. scripts/privacy_check.py, which make_release.sh runs first,
# reviews web reads, launched tools, lookups by name and written-out web addresses in the source. Nothing reviews
# a web address put together at run time, or a short home-folder path in an Apple silicon only build.
# Needs Xcode's command line tools. Written for the bash 3.2 that comes with macOS.
set -uo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <Helm.app>" >&2
    exit 2
fi
for tool in otool nm codesign plutil file lipo xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is missing. Install Xcode's command line tools." >&2; exit 2; }
done
xcrun --find swift-demangle >/dev/null 2>&1 || { echo "error: swift-demangle is missing. Install Xcode." >&2; exit 2; }

root=$(cd "$(dirname "$0")/../.." && pwd)
app=$(cd "$1" && pwd)
plist="$app/Contents/Info.plist"
exe=$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null) || { echo "error: $plist names no executable." >&2; exit 2; }
bin="$app/Contents/MacOS/$exe"
[ -f "$bin" ] || { echo "error: $bin is missing." >&2; exit 2; }
work=$(mktemp -d) || { echo "error: can't make a temporary folder." >&2; exit 2; }
trap 'rm -rf "$work"' EXIT
problems=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; problems=$((problems + 1)); }
# Every file in the app, one per line, from Contents/.
files() { find "$app" -type f -print0 | while IFS= read -r -d '' f; do printf '%s\n' "${f#"$app"/}"; done; }

# 1. One Mach-O file, Helm itself: no frameworks, plug-ins, helpers or XPC services that could do other things.
# Nor the folders that hold them, or launch agents, which are plists that can start any tool.
machos=$(files | while IFS= read -r f; do
    if file -b "$app/$f" | head -n 1 | grep -q 'Mach-O'; then printf '%s\n' "$f"; fi
done)
folders=""
for folder in Frameworks PlugIns Extensions XPCServices Library LoginItems Helpers; do
    [ -e "$app/Contents/$folder" ] && folders="$folders $folder"
done
extra=$(printf '%s\n' "$machos" | grep -vxF -e "Contents/MacOS/$exe" -e '' | tr '\n' ' ' | sed 's/ $//')
problem=""
[ -n "$extra" ] && problem="Mach-O files besides Contents/MacOS/$exe: $extra"
printf '%s\n' "$machos" | grep -qxF "Contents/MacOS/$exe" || problem="${problem:+$problem; }Contents/MacOS/$exe isn't a Mach-O file"
[ -n "$folders" ] && problem="${problem:+$problem; }folders for helpers or agents:$folders"
if [ -z "$problem" ]; then
    pass "one Mach-O file: Contents/MacOS/$exe, and no helpers or agents"
else
    fail "$problem"
fi

# 2. Linked libraries: only Apple's, and only these. A new one needs a reviewed edit here.
# CoreText measures the lines of the grid's names (GridNameLines); it lays out text and opens nothing.
allowed='^(/usr/lib/libobjc\.A\.dylib|/usr/lib/libSystem\.B\.dylib|/usr/lib/swift/libswift[A-Za-z_]+\.dylib'
allowed="$allowed|/System/Library/Frameworks/(AppKit|Combine|CoreFoundation|CoreGraphics|CoreServices|CoreText|CoreTransferable"
allowed="$allowed|Foundation|Quartz|QuartzCore|QuickLookThumbnailing|QuickLookUI|Security|ServiceManagement|SwiftUI"
allowed="$allowed|UniformTypeIdentifiers)\.framework/.+)$"
libraries=$(otool -arch all -L "$bin" | awk '/^[[:space:]]/ { print $1 }' | sort -u)
others=$(printf '%s\n' "$libraries" | grep -Ev "$allowed")
if [ -n "$libraries" ] && [ -z "$others" ]; then
    pass "linked libraries: $(printf '%s\n' "$libraries" | wc -l | tr -d ' '), all on the list"
else
    fail "linked libraries that aren't on the list: $(printf '%s\n' "$others" | tr '\n' ' ')"
fi

# 3. Imported symbols: nothing that opens a connection, looks up a host name, or reads who the person or
# the Mac is. Swift names are demangled first. CoreServices and Foundation bring CFNetwork along, so its
# names are listed too. URL.lines, URL.resourceBytes and SwiftUI's AsyncImage load web addresses through
# Foundation and SwiftUI, which are allowed, so they are named here. dlopen isn't, because dlsym, which
# macOS's own availability check uses, finds the same things. scripts/privacy_check.py reviews every
# dynamic lookup in the source.
imports=$(nm -um -arch all "$bin" | xcrun swift-demangle)
count=$(printf '%s\n' "$imports" | grep -c external)
denied=$(printf '%s\n' "$imports" | grep -E \
    -e 'external _(socket|connect|connectx|bind|listen|accept|sendto|sendmsg|recvfrom|recvmsg)( |$)' \
    -e 'external _(getaddrinfo|getnameinfo|gethostbyname2?|gethostbyaddr|getifaddrs|res_query|res_search)( |$)' \
    -e 'external _(gethostuuid|gethostname|getlogin(_r)?|getpwuid(_r)?|getpwnam(_r)?|NSUserName|NSFullUserName|CSCopyUserName|CSCopyMachineName)( |$)' \
    -e 'external _(DNSService|nw_|CFSocket|CFStreamCreatePair|CFHost|CFHTTP|CFFTP|CFNetService|CFNetDiagnostic|CFNetwork|CFURLConnection)' \
    -e 'external _(CFReadStreamCreateForHTTPRequest|CF(Read|Write)StreamCreateWithFTPURL|SCNetworkReachability|SCDynamicStore|IOService|IORegistry)' \
    -e 'OBJC_CLASS_\$_(NSURLSession[A-Za-z]*|NSURLConnection|NSURLDownload|NSURLRequest|NSMutableURLRequest|NSHTTPCookieStorage|NSURLCache)( |$)' \
    -e 'OBJC_CLASS_\$_(NSURLProtocol|NSHost|NSNetService[A-Za-z]*|WKWebView|WebView|NSUbiquitousKeyValueStore|NSUserActivity|NSAppleScript|NSXPCConnection)( |$)' \
    -e 'URLSession|URLRequest|Network\.NW|FoundationNetworking|SwiftUI\.AsyncImage' \
    -e 'Foundation\.URL\.(lines|resourceBytes|AsyncBytes)' | sed 's/^ *//' | sort -u)
if [ "$count" -eq 0 ]; then
    fail "imported symbols: nm listed none, so they weren't checked"
elif [ -z "$denied" ]; then
    pass "imported symbols: $count, none for the network or identifiers"
else
    fail "imported symbols for the network or identifiers:"
    printf '%s\n' "$denied" | head -n 20 | sed 's/^/       /'
fi

# 4. Objective-C method names that fetch from the web, or read the user or host name.
# Each row is an address and a name.
names=$(otool -arch all -v -s __TEXT __objc_methname "$bin" | awk '$1 ~ /^[0-9a-f]+$/ && NF == 2 { print $2 }')
methods=$(printf '%s\n' "$names" | grep -E \
    -e '^(dataTaskWith|downloadTaskWith|uploadTaskWith|streamTaskWith|webSocketTaskWith|sendSynchronousRequest)' \
    -e '^(hostName|userName|fullUserName|startDownloadingUbiquitousItemAtURL:error:)$' | sort -u)
if [ -z "$names" ]; then
    fail "method names: otool listed none, so they weren't checked"
elif [ -z "$methods" ]; then
    pass "method names: none that fetch from the web or read the user or host name"
else
    fail "method names that fetch from the web or read the user or host name: $(printf '%s\n' "$methods" | tr '\n' ' ')"
fi

# 5. Web addresses, in any file. Apple's plist header names its DTD by address: nothing fetches it.
# A Mach-O file is read from a copy without its signature: a Developer ID signature holds the addresses
# of Apple's certificate services, which Helm itself never uses.
urls=$(files | while IFS= read -r f; do
    target="$app/$f"
    if printf '%s\n' "$machos" | grep -qxF "$f" && cp "$target" "$work/unsigned" &&
        codesign --remove-signature "$work/unsigned" 2>/dev/null; then
        target="$work/unsigned"
    fi
    LC_ALL=C grep -aoE '(https?|wss?)://[A-Za-z0-9._~:/?#@!$&+,;=%-]*' "$target" | awk -v f="$f" '{ print f ": " $0 }'
done | grep -Ev ': https?://www\.apple\.com/DTDs/PropertyList-1\.0\.dtd$' | sort -u)
if [ -z "$urls" ]; then
    pass "web addresses: none"
else
    fail "web addresses:"
    printf '%s\n' "$urls" | head -n 20 | sed 's/^/       /'
fi

# 6. Folder paths from the Mac that built the app: any home folder, temporary or Xcode build folder, this
# checkout, or the build folder.
paths=("/Users/" "/var/folders/" "DerivedData/" "$root" "$(cd "$root" && pwd -P)")
case $app in */Build/Products/*)
    build=${app%%/Build/Products/*}
    paths+=("$build" "$(cd "$build" && pwd -P)") ;;
esac
[ "${#HOME}" -gt 1 ] && paths+=("$HOME")
# Xcode writes /tmp/... where pwd says /private/tmp/... (the same for /var), so each path is looked for
# without /private. That shorter form also matches the longer one.
patterns=()
for p in "${paths[@]}"; do patterns+=(-e "${p#/private}"); done
leaks=$(files | while IFS= read -r f; do
    if LC_ALL=C grep -aqF "${patterns[@]}" "$app/$f"; then
        printf '%s, such as: %s\n' "$f" "$(LC_ALL=C tr -c '[:print:]' '\n' < "$app/$f" | grep -F "${patterns[@]}" |
            head -n 2 | cut -c 1-160 | tr '\n' ' ')"
    fi
done)
if [ -z "$leaks" ]; then
    pass "build machine paths: none (looked for /Users/, /var/folders/, DerivedData/, the checkout and the build folder)"
else
    fail "files with paths from the build machine:"
    printf '%s\n' "$leaks" | sed 's/^/       /'
fi

# 7. Info.plist: no App Transport Security exceptions, URL schemes, Bonjour or local network keys,
# Handoff activity types, or an update feed.
keys=""
for key in NSAppTransportSecurity CFBundleURLTypes NSBonjourServices NSLocalNetworkUsageDescription NSUserActivityTypes SUFeedURL; do
    plutil -extract "$key" xml1 -o /dev/null "$plist" >/dev/null 2>&1 && keys="$keys $key"
done
if [ -z "$keys" ]; then
    pass "Info.plist: no network, URL scheme, Handoff or update keys"
else
    fail "Info.plist has these keys:$keys"
fi

# 8. Signature, for each architecture: the hardened runtime on, and no entitlements at all.
# So no get-task-allow, which lets a debugger into Helm, and no network or iCloud entitlement.
for arch in $(lipo -archs "$bin"); do
    flags=$(codesign -d --verbose=2 --arch "$arch" "$app" 2>&1 | sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-f]*([^)]*)\).*/\1/p')
    entitlements=$(codesign -d --entitlements - --xml --arch "$arch" "$app" 2>/dev/null |
        grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g' | tr '\n' ' ')
    problem=""
    case $flags in '') problem="the app isn't signed" ;; *runtime*) ;; *) problem="the hardened runtime is off ($flags)" ;; esac
    [ -n "$entitlements" ] && problem="${problem:+$problem, and }it has entitlements: $entitlements"
    if [ -z "$problem" ]; then
        pass "$arch signature: hardened runtime on, no entitlements"
    else
        fail "$arch signature: $problem"
    fi
done

if [ "$problems" -eq 0 ]; then
    echo "Binary privacy checks passed: $app"
    exit 0
fi
echo "Binary privacy checks: $problems problems in $app"
exit 1
