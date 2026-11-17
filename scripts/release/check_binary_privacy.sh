#!/usr/bin/env bash
# Checks a built Helm.app against the privacy promise. Helm connects only to the model provider the person
# chose, and to OpenAI's sign-in host for a ChatGPT sign-in, and only while AI mode is on. It listens only on
# 127.0.0.1, for a sign-in's callback. It doesn't read the person's name or the Mac's name or serial number (it
# reads a disk's ID only to tell disks apart, and never keeps it), and carries no folder paths from the Mac
# that built it.
#
# usage: scripts/release/check_binary_privacy.sh <Helm.app>
#        scripts/release/check_binary_privacy.sh --network-symbols <Helm.app>
#
# The second form checks nothing. It prints every imported symbol that check 3 holds to
# allowed_network_symbols.txt, sorted, one a line, so a spelling on that list can be corrected.
#
# Two lists next to this script name what may reach the network, and a change to either is a reviewed edit:
#   allowed_network_symbols.txt  The URL session calls the transport to the provider makes. One demangled imported
#                                symbol a line, or a prefix ending in *. A call that makes a session task, the shared
#                                session, a background session, and the cache, cookie and credential types fail even
#                                when listed.
#   allowed_addresses.txt        The providers' fixed addresses, OpenAI's sign-in host, and the help pages the person
#                                can open in their browser, one a line. The app may hold no other web address.
#                                Opening a help page hands its address to the browser; Helm doesn't connect to it.
#
# It only reads the app, and works on copies in a temporary folder. Each problem is printed, and the
# exit status is 1 if there is any (2 if the check can't run). scripts/privacy_check.py checks the
# source, so only the transport file names a URL session, and scripts/rebuild/host_smoke.sh runs the app
# with the network blocked, so nothing connects while AI mode is off. This checks what ships.
# What it can't see: a web address put together as the app runs, a web read through a call that also reads
# files (such as Data(contentsOf:)), the tools the app starts, and lookups by name at run time. Swift also keeps
# strings of up to 15 bytes inside the code, so checks 5 and 6 see those only in the Intel slice, 8 bytes at a
# time, and make_release.sh refuses a build without it. scripts/privacy_check.py, which make_release.sh runs first,
# reviews web reads, launched tools and written-out web addresses in the source, and the lookups by name it lists:
# NSClassFromString, NSSelectorFromString, dlopen, dlsym, objc_getClass, objc_lookUpClass, @_silgen_name, a
# bundle's classNamed, a Selector made from a string and a perform of one. A lookup by name through any other call
# is not reviewed, nor is a web address put together at run time, or a short home-folder path in an Apple silicon
# only build.
# Needs Xcode's command line tools. Written for the bash 3.2 that comes with macOS.
set -uo pipefail

mode=check
if [ $# -eq 2 ] && [ "$1" = --network-symbols ]; then
    mode=symbols
    shift
fi
if [ $# -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 [--network-symbols] <Helm.app>" >&2
    exit 2
fi
for tool in otool nm codesign plutil file lipo xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is missing. Install Xcode's command line tools." >&2; exit 2; }
done
xcrun --find swift-demangle >/dev/null 2>&1 || { echo "error: swift-demangle is missing. Install Xcode." >&2; exit 2; }

root=$(cd "$(dirname "$0")/../.." && pwd)
here=$(cd "$(dirname "$0")" && pwd)
symbol_list="$here/allowed_network_symbols.txt"
address_list="$here/allowed_addresses.txt"
app=$(cd "$1" && pwd)
plist="$app/Contents/Info.plist"
exe=$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null) || { echo "error: $plist names no executable." >&2; exit 2; }
bin="$app/Contents/MacOS/$exe"
[ -f "$bin" ] || { echo "error: $bin is missing." >&2; exit 2; }

# The symbols that name a URL session or a URL request. Check 3 holds each of them to allowed_network_symbols.txt.
network_family='URLSession|URLRequest'
# What allowed_network_symbols.txt can't let in: a call that makes a session task (only the async data and bytes
# calls may fetch), the shared or a background session, and the cache, cookie and credential types. "__shared" is
# how Swift spells a parameter convention, so it isn't the shared session.
network_never='([Dd]ata|[Dd]ownload|[Uu]pload|[Ss]tream|[Ww]ebSocket)Task|\.(download|upload)\(|(^|[^_[:alnum:]])shared|[a-z]Shared'
network_never="$network_never|[Bb]ackground|URLCache|CachedURLResponse|HTTPCookie|URLCredential"
# Swift names are demangled, so the lists can be read and written by hand.
imports=$(nm -um -arch all "$bin" | xcrun swift-demangle)
# The name of each imported symbol, one a line and sorted, without nm's "(undefined) external" and "(from ...)".
imported_names() {
    printf '%s\n' "$imports" | grep -E '^[[:space:]]*\(undefined\) ' | sed -E \
        -e 's/^[[:space:]]*\(undefined\) (weak )?external //' \
        -e 's/ \((from [^()]*|dynamically looked up)\)$//' | LC_ALL=C sort -u
}
if [ "$mode" = symbols ]; then
    imported_names | grep -E "$network_family"
    exit 0
fi
for list in "$symbol_list" "$address_list"; do
    [ -f "$list" ] || { echo "error: $list is missing." >&2; exit 2; }
done
# The lines of a list, without blank lines, a carriage return or spaces at the end.
entries() { sed -e 's/[[:space:]]*$//' "$1" | grep -v '^$'; }

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
# CFNetwork holds the URL session classes the transport to the chosen provider uses. Check 3 lists which of its
# calls Helm may make.
# AVFoundation, PDFKit and Vision are Read contents: a PDF's text, the text in a picture and what it shows,
# and a few frames of a video, read on this Mac from bytes Helm reads itself. scripts/privacy_check.py keeps them to
# one file, and check 3 still holds every URL session call to the list.
allowed='^(/usr/lib/libobjc\.A\.dylib|/usr/lib/libSystem\.B\.dylib|/usr/lib/swift/libswift[A-Za-z_]+\.dylib'
allowed="$allowed|/System/Library/Frameworks/(AppKit|AVFoundation|CFNetwork|Combine|CoreFoundation|CoreGraphics|CoreServices"
allowed="$allowed|CoreText|CoreTransferable|Foundation|PDFKit|Quartz|QuartzCore|QuickLookThumbnailing|QuickLookUI|Security"
allowed="$allowed|ServiceManagement|SwiftUI|UniformTypeIdentifiers|Vision)\.framework/.+)$"
libraries=$(otool -arch all -L "$bin" | awk '/^[[:space:]]/ { print $1 }' | sort -u)
others=$(printf '%s\n' "$libraries" | grep -Ev "$allowed")
if [ -n "$libraries" ] && [ -z "$others" ]; then
    pass "linked libraries: $(printf '%s\n' "$libraries" | wc -l | tr -d ' '), all on the list"
else
    fail "linked libraries that aren't on the list: $(printf '%s\n' "$others" | tr '\n' ' ')"
fi

# 3. Imported symbols: nothing that opens a connection, looks up a host name, or reads who the person or
# the Mac is, but the URL session calls on allowed_network_symbols.txt. A ChatGPT sign-in listens on 127.0.0.1 for
# the browser's callback, so socket, bind, listen and accept may be imported; connect, and every call that sends to
# or hears from an address of its own choosing, may not. CoreServices and Foundation bring
# CFNetwork along, so its other names are listed too. URL.lines, URL.resourceBytes and SwiftUI's AsyncImage load
# web addresses through Foundation and SwiftUI, which are allowed, so they are named here. dlopen isn't,
# because dlsym, which macOS's own availability check uses, finds the same things. scripts/privacy_check.py
# reviews every dynamic lookup in the source.
count=$(printf '%s\n' "$imports" | grep -c external)
denied=$(printf '%s\n' "$imports" | grep -E \
    -e 'external _(connect|connectx|sendto|sendmsg|recvfrom|recvmsg)( |$)' \
    -e 'external _(getaddrinfo|getnameinfo|gethostbyname2?|gethostbyaddr|getifaddrs|res_query|res_search)( |$)' \
    -e 'external _(gethostuuid|gethostname|getlogin(_r)?|getpwuid(_r)?|getpwnam(_r)?|NSUserName|NSFullUserName|CSCopyUserName|CSCopyMachineName)( |$)' \
    -e 'external _(DNSService|nw_|CFSocket|CFStreamCreatePair|CFHost|CFHTTP|CFFTP|CFNetService|CFNetDiagnostic|CFNetwork|CFURLConnection)' \
    -e 'external _(CFReadStreamCreateForHTTPRequest|CF(Read|Write)StreamCreateWithFTPURL|SCNetworkReachability|SCDynamicStore|IOService|IORegistry)' \
    -e 'OBJC_CLASS_\$_(NSURLConnection|NSURLDownload|NSHTTPCookieStorage|NSURLCache|NSURLCredentialStorage)( |$)' \
    -e 'OBJC_CLASS_\$_(NSURLProtocol|NSHost|NSNetService[A-Za-z]*|WKWebView|WebView|NSUbiquitousKeyValueStore|NSUserActivity|NSAppleScript|NSXPCConnection)( |$)' \
    -e 'Network\.NW|FoundationNetworking|SwiftUI\.AsyncImage|URLConnection|URLDownload|URLCache|HTTPCookie|URLCredentialStorage|URLProtocol' \
    -e 'Foundation\.URL\.(lines|resourceBytes|AsyncBytes)' | sed 's/^ *//' | sort -u)
# The URL session and request symbols: each must be on the list, and none may be one the list can't let in.
network=$(imported_names | grep -E "$network_family")
# An entry that names no URL session or request lets nothing in, so a lone * can't let every symbol in.
unlisted=$( { printf '%s\n' "$network" | awk -v list="$symbol_list" -v family="$network_family" '
    BEGIN {
        while ((getline entry < list) > 0) {
            sub(/[[:space:]]+$/, "", entry)
            if (entry !~ family) continue
            if (substr(entry, length(entry)) == "*") prefixes[++n] = substr(entry, 1, length(entry) - 1)
            else exact[entry] = 1
        }
    }
    $0 == "" || ($0 in exact) { next }
    { for (i = 1; i <= n; i++) if (index($0, prefixes[i]) == 1) next; print }'
    printf '%s\n' "$network" | grep -E "$network_never"; } | grep -v '^$' | LC_ALL=C sort -u)
# A list entry has to name a URL session or request, and can't be one the list can't let in.
bad_entries=$( { entries "$symbol_list" | grep -Ev "$network_family"; entries "$symbol_list" | grep -E "$network_never"; } |
    LC_ALL=C sort -u)
if [ "$count" -eq 0 ]; then
    fail "imported symbols: nm listed none, so they weren't checked"
elif [ -z "$denied" ] && [ -z "$unlisted" ] && [ -z "$bad_entries" ]; then
    if [ -z "$network" ]; then
        pass "imported symbols: $count, none for the network or identifiers"
    else
        pass "imported symbols: $count, none for the network or identifiers but $(printf '%s\n' "$network" | wc -l | tr -d ' ') URL session symbols on allowed_network_symbols.txt"
    fi
else
    if [ -n "$denied" ]; then
        fail "imported symbols for the network or identifiers:"
        printf '%s\n' "$denied" | head -n 20 | sed 's/^/       /'
    fi
    if [ -n "$unlisted" ]; then
        fail "imported URL session symbols that aren't on allowed_network_symbols.txt, or that it can't let in:"
        printf '%s\n' "$unlisted" | head -n 40 | sed 's/^/       /'
    fi
    if [ -n "$bad_entries" ]; then
        fail "allowed_network_symbols.txt has entries that name no URL session or request, or that it can't let in:"
        printf '%s\n' "$bad_entries" | sed 's/^/       /'
    fi
fi

# 4. Objective-C method names that fetch from the web outside the async data and bytes calls, or read the
# user or host name. The shared session, the default and background configurations and a credential made from
# a server's certificate leave no imported symbol, only a method name, so they are named here. So is the call
# that removes a downloaded copy of a cloud file. Each row is an address and a name.
names=$(otool -arch all -v -s __TEXT __objc_methname "$bin" | awk '$1 ~ /^[0-9a-f]+$/ && NF == 2 { print $2 }')
methods=$(printf '%s\n' "$names" | grep -E \
    -e '^(dataTaskWith|downloadTaskWith|uploadTaskWith|streamTaskWith|webSocketTaskWith|sendSynchronousRequest)' \
    -e '^(sharedSession|defaultSessionConfiguration|backgroundSessionConfiguration|credentialForTrust:|initWithTrust:)' \
    -e '^(hostName|userName|fullUserName|startDownloadingUbiquitousItemAtURL:error:|evictUbiquitousItemAtURL:error:)$' | sort -u)
if [ -z "$names" ]; then
    fail "method names: otool listed none, so they weren't checked"
elif [ -z "$methods" ]; then
    pass "method names: none that fetch from the web outside the async calls, evict a download, or read the user or host name"
else
    fail "method names that fetch from the web outside the async calls, evict a download, or read the user or host name: $(printf '%s\n' "$methods" | tr '\n' ' ')"
fi

# 5. Web addresses, in any file: only the providers' addresses on allowed_addresses.txt, each matched whole.
# Apple's plist header names its DTD by address: nothing fetches it.
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
# Each row is a file and an address, and an address holds no space, so it is what follows the last ": ".
other_urls=$(printf '%s\n' "$urls" | awk -v list="$address_list" '
    BEGIN {
        while ((getline entry < list) > 0) {
            sub(/[[:space:]]+$/, "", entry)
            if (entry != "") listed[entry] = 1
        }
    }
    $0 == "" { next }
    { count = split($0, parts, ": "); if (!(parts[count] in listed)) print }')
if [ -z "$urls" ]; then
    pass "web addresses: none"
elif [ -z "$other_urls" ]; then
    pass "web addresses: only those on allowed_addresses.txt ($(printf '%s\n' "$urls" | wc -l | tr -d ' ') found)"
else
    fail "web addresses that aren't on allowed_addresses.txt:"
    printf '%s\n' "$other_urls" | head -n 20 | sed 's/^/       /'
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

# 7. Info.plist: no URL schemes, Bonjour or local network keys, Handoff activity types, or an update feed.
# App Transport Security has no exceptions, but one: plain http to this Mac, which is how a local model is
# reached. Its key is absent, or holds exactly ats_shape, read as JSON so a 1 or a "YES" isn't taken for true.
ats_shape='{"NSAllowsLocalNetworking":true}'
keys=""
for key in CFBundleURLTypes NSBonjourServices NSLocalNetworkUsageDescription NSUserActivityTypes SUFeedURL; do
    plutil -extract "$key" xml1 -o /dev/null "$plist" >/dev/null 2>&1 && keys="$keys $key"
done
ats=""
if plutil -extract NSAppTransportSecurity xml1 -o /dev/null "$plist" >/dev/null 2>&1; then
    ats=$(plutil -extract NSAppTransportSecurity json -o - "$plist" 2>/dev/null)
    [ "$ats" = "$ats_shape" ] || keys="$keys NSAppTransportSecurity (with more than NSAllowsLocalNetworking = true)"
fi
if [ -n "$keys" ]; then
    fail "Info.plist has these keys:$keys"
elif [ -n "$ats" ]; then
    pass "Info.plist: no network, URL scheme, Handoff or update keys but NSAllowsLocalNetworking, for this Mac only"
else
    pass "Info.plist: no network, URL scheme, Handoff or update keys"
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
