#!/usr/bin/env python3
"""Privacy check. Helm's shipped code must not use the network, send telemetry, read identifiers,
write to the unified log, or hand data to iCloud, other devices or other apps on its own.

It reads every Swift file under Sources/, the app target in App/ (Swift, plist, entitlements and
yml files) and Package.swift. Comments and strings count too, so a mention anywhere fails until it
is reworded or reviewed. A reviewed line goes in ALLOW: one rule, one file and the exact line.

It reads text only. scripts/release/check_binary_privacy.sh checks the built app, and
scripts/rebuild/host_smoke.sh runs the app with the network blocked.

Usage: python3 -I scripts/privacy_check.py [ROOT]   (ROOT is the repository root by default)
"""
import re
import sys
from pathlib import Path

SWIFT = ('.swift',)
APP = ('.swift', '.plist', '.entitlements', '.yml')
SETTINGS = ('.plist', '.entitlements', '.yml')
# The start of an import, with any attributes and access level, such as `@preconcurrency internal import`.
# It may follow a `;` on the same line.
IMPORT = (r'(?:^|;)[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*(?:(?:public|package|internal|fileprivate|private)[ \t]+)?'
          r'import[ \t]+(?:(?:struct|class|enum|func|var|let|typealias|protocol)[ \t]+)?')

# (id, what it finds, pattern, files it reads). Patterns are matched against the raw text.
RULES = [
    # AsyncImage, LPMetadataProvider and URL.resourceBytes load web addresses without naming URLSession.
    ('url-loading', 'network: URL loading',
     r'\b(?:URLSession\w*|URLRequest|NSURLRequest|NSMutableURLRequest|NSURLSession\w*|NSURLConnection\w*'
     r'|NSURLDownload|URLCache|URLProtocol|HTTPURLResponse|HTTPCookieStorage|CFHTTP\w+|CFNetwork\w*'
     r'|AsyncImage|LPMetadataProvider)\b|\.resourceBytes\b|\bURL\.AsyncBytes\b', SWIFT),
    ('network-framework', 'network: Network.framework',
     r'\bNW(?:Connection|Listener|Browser|PathMonitor|Endpoint|Parameters|Protocol|Path|Interface|TXTRecord)\w*\b'
     r'|\bnw_\w+', SWIFT),
    ('sockets', 'network: sockets, DNS and streams',
     r'\b(?:CFSocket\w*|CFStreamCreatePairWith\w+|CF(?:Read|Write)StreamCreateWith\w+|CFHost\w*|getStreamsToHost\w*'
     r'|SCNetworkReachability\w*|AF_INET6?|PF_INET6?|SOCK_STREAM|SOCK_DGRAM|IPPROTO_\w+|sockaddr_in6?|sockaddr_storage'
     r'|getaddrinfo|getnameinfo|gethostbyname2?|gethostbyaddr|inet_pton|inet_ntop|inet_addr|inet_aton'
     r'|res_query|res_search|sendto|recvfrom|sendmsg|recvmsg)\b', SWIFT),
    # A bare `connect(fd, ...)` is the socket call. `x.connect(to:)` and `func connect(to:)` are not.
    ('socket-call', 'network: socket() or connect() call',
     r'\b(?:Darwin|Glibc)\.(?:socket|connect|bind|listen|accept)\s*\('
     r'|(?<![\w.])socket\s*\('
     r'|(?<![\w.])connect\s*\(\s*&?[A-Za-z_][\w.]*(?:\([^()]*\))?\s*,', SWIFT),
    ('web-view', 'network: web view, Bonjour or peer-to-peer',
     r'\b(?:WKWebView|WKWebsiteDataStore|WebView|SFSafariViewController|ASWebAuthenticationSession|NetService\w*'
     r'|NSNetService\w*|DNSService\w+|MCSession|MCPeerID|MCNearbyService\w*|MCAdvertiserAssistant)\b', SWIFT),
    ('import', 'a framework that uses the network, tracks the person or shares data',
     IMPORT + r'(?:Network|NetworkExtension|FoundationNetworking|CFNetwork|WebKit|SafariServices|LinkPresentation'
     r'|MultipeerConnectivity|CloudKit|CoreSpotlight|Intents|IntentsUI|AuthenticationServices|StoreKit|GameKit'
     r'|MapKit|CoreLocation|AdSupport|AdServices|AppTrackingTransparency|iAd|MetricKit|SystemConfiguration|CoreWLAN'
     r'|CoreBluetooth|IOBluetooth|ExternalAccessory|IOKit|OSAKit|ScriptingBridge)\b', SWIFT),
    ('telemetry', 'telemetry, crash reporting or self-update',
     r'\b(?:Sparkle|SPUUpdater\w*|SPUStandardUpdaterController|SUUpdater|Firebase\w*|Crashlytics|Sentry\w*'
     r'|Bugsnag\w*|Mixpanel|Amplitude\w*|TelemetryDeck|TelemetryClient|TelemetryManager|PostHog\w*|AppCenter\w*'
     r'|MSAppCenter|Datadog\w*|NewRelic\w*|Instabug\w*|Countly|PLCrashReporter|KSCrash\w*|MXMetricManager'
     r'|OSLogStore|NSSetUncaughtExceptionHandler)\b', SWIFT),
    ('unified-log', 'unified log, which keeps what it is given and goes into diagnostic reports',
     r'\b(?:NSLogv?|os_log|os_signpost|OSSignposter|v?syslog|asl_v?log)\s*\(|\bLogger\s*\(|'
     + IMPORT + r'(?:os(?:\.log)?|OSLog)\b', SWIFT),
    ('identifier', 'identifier of the person or the Mac',
     r'\b(?:NSUserName|NSFullUserName|CSCopyUserName|CSCopyMachineName|getlogin(?:_r)?|getpwuid(?:_r)?'
     r'|getpwnam(?:_r)?|gethostuuid|gethostname|getifaddrs|SCDynamicStoreCopy\w+|IOPlatformExpertDevice'
     r'|kIOPlatform\w+Key|IORegistryEntryCreateCFProperty|IOServiceGetMatchingService\w*|ASIdentifierManager'
     r'|advertisingIdentifier|identifierForVendor|ATTrackingManager)\b'
     r'|ProcessInfo\.processInfo\.(?:hostName|userName|fullUserName|globallyUniqueString)\b|\bHost\.current\s*\('
     # The account name, read from the environment.
     r'|\b(?:getenv\s*\(|environment\s*\[)\s*"(?:USER|LOGNAME)"', SWIFT),
    ('hand-off', 'hand-off to iCloud, Handoff, Spotlight or other apps',
     r'\b(?:NSUserActivity|CSSearchable\w+|INInteraction|INVoiceShortcut\w*|NSUbiquitousKeyValueStore'
     r'|CK(?:Container|Database|Record|Query|Share)\w*|forUbiquityContainerIdentifier|ubiquityIdentityToken'
     r'|startDownloadingUbiquitousItem|setUbiquitous|kSecAttrSynchronizable|NSDocumentController'
     r'|noteNewRecentDocument\w*|LSSharedFileList\w*|NSAppleScript|OSAScript|AESend\w*|NSDistributedNotificationCenter'
     r'|DistributedNotificationCenter|CFNotificationCenterGetDistributedCenter|NSXPCConnection|SMJobBless)\b', SWIFT),
    # The xattr names are declared by hand for Linux in NativeTagAttributes.swift.
    ('dynamic-lookup', 'dynamic lookup, which can hide a call this check looks for',
     r'\b(?:NSClassFromString|NSSelectorFromString|dlopen|dlsym|objc_getClass|objc_lookUpClass)\s*\('
     r'|@_silgen_name\s*\(\s*"(?!(?:getxattr|setxattr|removexattr|listxattr)")', SWIFT),
    # Every Apple plist starts with the address of its DTD. Nothing fetches it.
    ('web-address', 'web address',
     r'\b(?:https?|wss?|ftps?)://(?!www\.apple\.com/DTDs/PropertyList-1\.0\.dtd")', APP),
    ('network-tool', 'network or identifier tool',
     r'\b(?:curl|wget|ncat|netcat|nscurl|osascript|ssh|scp|sftp|rsync|telnet|ioreg|system_profiler|scutil'
     r'|networksetup|nslookup)\b', SWIFT),
    ('tool-path', 'tool that is not on the list',
     r'(?<![\w.])/(?:usr/)?(?:s?bin|libexec)/(?!(?:zip|unzip|gzip|tar|ditto|hdiutil|killall|open)\b)[\w.+-]+', SWIFT),
    # Also `Data.init(contentsOf:)` and `.init(contentsOf:)`. NSAttributedString loads web images for HTML.
    ('read-url', 'read from a URL, which can also fetch a web address',
     r'\b(?:Data|NSData|String|NSString|NSDictionary|NSArray|AttributedString|NSAttributedString|XMLParser'
     r'|XMLDocument|NSImage|NSSound)(?:\.init)?\s*\(\s*contentsOf\s*:|(?<![\w.])\.init\s*\(\s*contentsOf\s*:'
     r'|\bNSImage\s*\(\s*byReferencing\s*:|\bNSAttributedString\s*\(\s*(?:url|html)\s*:', SWIFT),
    ('network-key', 'network entitlement, URL scheme or Info.plist key',
     r'com\.apple\.security\.network\.(?:client|server)|com\.apple\.developer\.(?:icloud|ubiquity|associated-domains'
     r'|networking)[\w.-]*|aps-environment|NSAppTransportSecurity|NSAllowsArbitraryLoads|NSBonjourServices'
     r'|NSLocalNetworkUsageDescription|NSUserActivityTypes|CFBundleURLTypes|SUFeedURL|SUPublicEDKey'
     r'|SUEnableAutomaticChecks', SETTINGS),
    # Code from a package or a binary target is not read by this check.
    ('package', 'package dependency or binary target', r'\.(?:package|binaryTarget)\s*\(', ('Package.swift',)),
    ('package', 'remote package', r'^[ \t]*url[ \t]*:', ('.yml',)),
]

# (rule id, file from ROOT, the exact line). Spaces at either end of a line don't count.
ALLOW = [
    # Store files and the fixture smoke script. Each URL is a file URL.
    ('read-url', 'Sources/HelmPersistence/JSONFileStore.swift',
     'init(url: URL, read: @escaping @Sendable (URL) async throws -> Data = { try Data(contentsOf: $0) }) {'),
    ('read-url', 'Sources/HelmPersistence/Tags/PreferenceDocumentFile.swift',
     'do { data = try Data(contentsOf: url) }'),
    ('read-url', 'Sources/HelmApp/macOS/HostSmokeDriver.swift',
     'guard let text = try? String(contentsOf: script, encoding: .utf8) else { finish(code: 2, "cannot read script"); return }'),
    # Move to Applications. Whether macOS runs this copy from a translocated place: the Security framework keeps the
    # call private, so it's looked up by name.
    ('dynamic-lookup', 'Sources/HelmUI/Onboarding/AppMover.swift',
     'guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return false }'),
    ('dynamic-lookup', 'Sources/HelmUI/Onboarding/AppMover.swift',
     'guard let symbol = dlsym(security, "SecTranslocateIsTranslocatedURL") else { return false }'),
    # Move to Applications. An app's own Info.plist, read from disk to tell Helm apart from another app.
    ('read-url', 'Sources/HelmUI/Onboarding/AppMover.swift',
     'guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),'),
    # Move to Applications. A fixed script that waits for Helm to quit, then opens the moved copy with /usr/bin/open.
    ('tool-path', 'Sources/HelmUI/Onboarding/AppMover.swift',
     'waiter.executableURL = URL(fileURLWithPath: "/bin/sh")'),
]
ALLOWED = {(rule, rel, line.strip()) for rule, rel, line in ALLOW}


def files(root):
    found = sorted((root / 'Sources').rglob('*.swift'))
    app = root / 'App'
    if app.is_dir():
        found += sorted(p for p in app.rglob('*') if p.is_file() and p.suffix in APP)
    if (root / 'Package.swift').is_file():
        found.append(root / 'Package.swift')
    return found


def applies(path, suffixes):
    return any(path.name == s or path.suffix == s for s in suffixes)


def check(root):
    """Returns the files read, the problems found and the ALLOW entries that matched nothing."""
    rules = [(rule, name, re.compile(pattern, re.M), suffixes) for rule, name, pattern, suffixes in RULES]
    scanned, problems, used = files(root), [], set()
    for path in scanned:
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding='utf-8', errors='replace')
        # Split on \n only, as the line numbers below count. splitlines() also splits on form feeds and
        # other breaks, which would pair a match with the wrong line and so with the wrong ALLOW entry.
        lines = text.split('\n')
        for rule, name, pattern, suffixes in rules:
            if not applies(path, suffixes):
                continue
            for match in pattern.finditer(text):
                number = text.count('\n', 0, match.start()) + 1
                line = lines[number - 1].strip() if number <= len(lines) else ''
                entry = (rule, rel, line)
                if entry in ALLOWED:
                    used.add(entry)
                    continue
                problems.append(f'{rel}:{number}: privacy: {name} [{rule}]: {match.group().strip()}')
    return scanned, problems, sorted(ALLOWED - used)


def main(args):
    root = Path(args[0]) if args else Path(__file__).resolve().parent.parent
    scanned, problems, unused = check(root)
    # Package.swift and App/main.swift are Swift too, so look under Sources/ itself.
    sources = root / 'Sources'
    if not any(path.suffix == '.swift' and sources in path.parents for path in scanned):
        print(f'Privacy checks: no Swift files under {sources}')
        return 1
    for problem in problems:
        print(problem)
    for rule, rel, line in unused:
        print(f'note: this allowed line is gone, so its ALLOW entry can go too: [{rule}] {rel}: {line}')
    print(f'Privacy checks: {len(scanned)} files, {len(problems)} problems')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
