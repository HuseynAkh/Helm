#!/usr/bin/env python3
"""Privacy check. Helm connects only to the model provider the person chose, and only while AI mode is on.
So one file may name a URL session, and nothing else in the shipped code may use the network, send
telemetry, read identifiers, write to the unified log, or hand data to iCloud, other devices or other
apps on its own.

It reads every Swift file under Sources/, the app target in App/ (Swift, plist, entitlements and
yml files) and Package.swift. Comments and strings count too, so a mention anywhere fails until it is
reworded or reviewed. A reviewed line goes in ALLOW: one rule, one file and the exact line.

Some rules hold in one place only, or everywhere but one place:
- NETWORK_FILES may name a URL session. Every other rule holds there as it does anywhere else.
- Sources/HelmAgent is the module that reaches a model provider, so it names no way to change, open or
  look up a file, or to start a tool. It learns about the disk through HelmCore's AgentDisk alone.
- The files that draw a model's text draw it plain: no Markdown, no links, nothing that opens or shares.
- ONE_FILE and GUARDED list what only a file or two may say: the keychain calls, the call that shows a
  key, and the labels of the initializers that only those files may call. The file that declares such an
  initializer, in DECLARED, may name its label in a comment.

Swift lets a comment or a line break come between words, so a rule whose words have room between them reads
the code too, where comments are spaces. Property lists are also read as macOS reads them.

It reads text only. scripts/release/check_binary_privacy.sh checks the built app, and
scripts/rebuild/host_smoke.sh runs the app with the network blocked.

Usage: python3 -I scripts/privacy_check.py [ROOT]   (ROOT is the repository root by default)
"""
import plistlib
import re
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

SWIFT = ('.swift',)
APP = ('.swift', '.plist', '.entitlements', '.yml')
SETTINGS = ('.plist', '.entitlements', '.yml')
# The start of an import, with any attributes and access level, such as `@preconcurrency internal import`.
# It may follow a `;` on the same line. Swift lets a line break or a comment come between `import` and the module,
# so the rules that use it also read the code, where comments are blanked.
IMPORT = (r'(?:^|;)[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?'
          r'import\s+(?:(?:struct|class|enum|func|var|let|typealias|protocol)\s+)?')

AGENT = 'Sources/HelmAgent/'
TRANSPORT = AGENT + 'Transport/HTTPTransport.swift'
ENDPOINTS = AGENT + 'Transport/Endpoints.swift'
KEYCHAIN = AGENT + 'Secrets/KeychainSecretStore.swift'
SECRETS = AGENT + 'Contracts/AgentSecrets.swift'
LIVE_PARTS = AGENT + 'Runtime/AgentLiveParts.swift'
PLAN_CARD = 'Sources/HelmUI/Agent/AgentPlanCard.swift'
PANEL_MODEL = 'Sources/HelmUI/Agent/AgentPanelModel.swift'
WINDOW_AGENT = 'Sources/HelmUI/Window/BrowserWindowController+Agent.swift'
INFO_PLIST = 'App/Info.plist'

# The files that may name a URL session. They are let off `url-session` and nothing else, and each must exist
# while Sources/HelmAgent does.
NETWORK_FILES = {TRANSPORT}
# The files that draw text from a model and from the disk: the AI panel and AI search.
AGENT_UI = ('Sources/HelmUI/Agent/', 'Sources/HelmUI/Host/AISearchRunner.swift',
            'Sources/HelmUI/Host/AISearchPredicates.swift', 'Sources/HelmUI/Window/BrowserWindowController+AISearch.swift')
# The declaring file of each guarded initializer, whose comments may name its label (section GUARDED below).
DECLARED = {'fromPerson': AGENT + 'Contracts/AgentScopeContracts.swift',
            'typedByPerson': AGENT + 'Contracts/AgentSessionContracts.swift', 'liveProfile': TRANSPORT}
# What App/Info.plist may hold under NSAppTransportSecurity, if it has that key at all: plain http to this Mac,
# which is how a local model is reached.
ATS_SHAPE = {'NSAllowsLocalNetworking': True}
ATS_KEY = ('network-key', INFO_PLIST, '<key>NSAppTransportSecurity</key>')


def inside(*places):
    """Files in one of these folders, each ending in `/`, or one of these files."""
    return lambda rel: any(rel.startswith(place) if place.endswith('/') else rel == place for place in places)


def outside(*files):
    return lambda rel: rel not in files


# A C call written bare, as `open(path)`. A method (`x.open(`), a longer name (`reopen(`) and a declaration
# (`func open(`) are something else. A call through a module's name, `Darwin.open(`, is the same call.
BARE = (r'(?:(?<![\w.])(?<!func )|\b(?:Darwin|Glibc|Musl|Foundation|CoreFoundation|Dispatch|ObjectiveC|Security)'
        r'\s*\.\s*)')
WRITE_CALLS = (r'unlink(?:at)?|creat|mkdir(?:at)?|rmdir|symlink(?:at)?|link(?:at)?|f?truncate|[fl]?chmod|fchmodat'
               r'|[fl]?chflags|f?copyfile|f?clonefile(?:at)?|removefile|system|popen|v?fork|execl[ep]?|execv[epP]?|exect'
               r'|fexecve|syscall|[fl]?chown|fchownat|[fl]?utimes|futimens|utimensat|f?setattrlist|exchangedata'
               r'|mk[sd]temps?|mkostemps?|mkfifo|mknod')
READ_CALLS = (r'fopen|freopen|fdopen|open(?:at|_dprotected_np)?|p?readv?|mmap|opendir|fdopendir|readdir(?:_r)?|scandir'
              r'|fts_open|n?ftw|[fl]?stat|fstatat|realpath|readlink(?:at)?|f?statv?fs|f?getattrlist(?:at|bulk)?'
              r'|getdirentries|access|faccessat|glob|f?pathconf')
# Swift marks these unavailable, so they can only be called, never handed on by name.
UNAVAILABLE = ('system', 'fork', 'vfork')


def bare(names, gap=''):
    return BARE + '(?:' + names + ')`?' + gap + r'\('


LABEL = re.compile(r'\s*`?[A-Za-z_]\w*`?\s*:')


def c_calls(name, least):
    """`name(...)` as C spells it: `least` arguments or more, and no label. For `rename`, two: `case rename(X, to: Y)`
    and `rename(item, to: name)` have a label, and `case rename(Int)` has one argument. For `remove`, one:
    `remove(at: index)` has a label and `remove()` has no argument."""
    call = re.compile(BARE + name + r'`?\s*\(')

    def find(code):
        for match in call.finditer(code):
            arguments, depth, start = [], 0, match.end()
            for index in range(match.end(), len(code)):
                char = code[index]
                if char in '([{':
                    depth += 1
                elif char == ',' and depth == 0:
                    arguments.append(code[start:index])
                    start = index + 1
                elif char in ')]}':
                    if depth:
                        depth -= 1
                        continue
                    arguments.append(code[start:index])
                    if (len(arguments) >= least and arguments[0].strip()
                            and not any(LABEL.match(argument) for argument in arguments)):
                        yield match.start(), ' '.join(code[match.start():index + 1].split())
                    break
    return find


def c_references(names):
    """A C call's name with no bracket after it, in the code: the function itself, kept to be called later, as in
    `path.withCString(unlink)`, `(unlink)(path)` or `let call = rename`. A name that is declared, given a value,
    written as a label, read as a member, compared or listed after `case` is something else, and so is a value passed
    under its own name (`system: system`, `self.system = system`). A function can't be compared, so a compared name
    is a value."""
    word = re.compile(BARE + r'(' + names + r')\b(?!`?\s*[(:.?!<>=\[])')

    def find(code):
        for match in word.finditer(code):
            name = match.group(1)
            if name in UNAVAILABLE:
                continue
            head = code[max(code.rfind(stop, 0, match.start()) for stop in '\n;{}') + 1:match.start()]
            if (re.match(r'\s*case\b', head) or re.search(r'\b(?:let|var|case|func|import)\s+`?$', head)
                    or re.search(r'\b' + name + r'`?\s*[:=]\s*$', head) or re.search(r'(?:[=!<>]=|[<>])\s*$', head)):
                continue
            yield match.start(), match.group()
    return find


# A Unicode escape, `\u{55}`, is the character it names once the code is built.
UNICODE_ESCAPE = re.compile(r'\\u\{([0-9A-Fa-f]{1,8})\}')


def unescaped(pattern):
    """`pattern` found in the text with each Unicode escape read as its character, at the place the escape starts."""
    compiled = re.compile(pattern)

    def find(text):
        parts, places, last = [], [], 0
        for escape in UNICODE_ESCAPE.finditer(text):
            parts.append(text[last:escape.start()])
            places.extend(range(last, escape.start()))
            number = int(escape.group(1), 16)
            parts.append(chr(number) if number <= 0x10FFFF else '\ufffd')
            places.append(escape.start())
            last = escape.end()
        parts.append(text[last:])
        places.extend(range(last, len(text)))
        for match in compiled.finditer(''.join(parts)):
            yield places[match.start()], match.group()
    return find


NETWORK_KEY_NAME = 'network entitlement, URL scheme or Info.plist key'
NETWORK_KEY = (r'com\.apple\.security\.network\.(?:client|server)|com\.apple\.developer\.(?:icloud|ubiquity'
               r'|associated-domains|networking)[\w.-]*|aps-environment|NSAppTransportSecurity|NSAllowsArbitraryLoads'
               r'|NSBonjourServices|NSLocalNetworkUsageDescription|NSUserActivityTypes|CFBundleURLTypes|SUFeedURL'
               r'|SUPublicEDKey|SUEnableAutomaticChecks')
WRITES = "AI mode's module: a way to change a file or start a tool"
READS = "AI mode's module: a way to open or look up a file"
PLAIN = 'AI panel and AI search: text drawn as more than plain text, or a way to open or share'

# (id, what it finds, pattern, files it reads), then where it looks when that isn't everywhere, then what it
# matches against when that isn't the raw text: `code` or `strings`, as layers() returns them, or a tuple of views
# to read in turn. A pattern can also be a function that takes the text and gives each place it found and what it
# found there. A pattern that spans spaces between words is read in the code too, where a comment is spaces.
SESSION_TASKS = r'(?:dataTask(?:Publisher)?|downloadTask|uploadTask|webSocketTask|streamTask)'
BOTH = ('text', 'code')
RULES = [
    # The session, its configuration and delegates, the request, the HTTP response and the bytes a session streams.
    # A file handle streams bytes too, and that type is Helm's ordinary work.
    ('url-session', 'network: URL session outside the transport file',
     r'\b(?:URLSession\w*|URLRequest|HTTPURLResponse)\b|(?<!FileHandle\.)\bAsyncBytes\b', SWIFT, outside(*NETWORK_FILES)),
    # AsyncImage, LPMetadataProvider, URL.resourceBytes and URL.lines load web addresses without naming URLSession.
    # The lines of an address are awaited, or read from something named for one; a session's bytes and a file's
    # bytes have lines too, and the transport reads its own.
    ('url-other', 'network: URL loading',
     r'\b(?:NSURLRequest|NSMutableURLRequest|NSURLSession\w*|NSURLConnection\w*|NSURLDownload|URLCache|URLProtocol'
     r'|HTTPCookieStorage|CFHTTP\w+|CFNetwork\w*|AsyncImage|LPMetadataProvider)\b|\.resourceBytes\b'
     r'|\bURL\.AsyncBytes\b|\bawait\b[^\n;{}]*(?<!bytes)\.\s*lines\b|\b\w*(?:url|Url|URL)\w*\s*\.\s*lines\b'
     r'|\bURL\s*\([^\n]*\)\s*!?\s*\.\s*lines\b', SWIFT),
    # The transport makes one session of its own that keeps nothing, and only awaits `data(for:)` and `bytes(for:)`.
    # A credential made from the server's trust would accept a certificate macOS didn't, and a load `from:` an
    # address goes around the request built in the transport.
    ('session-shape', 'network: a shared, default or background session, a trust override or a task-making call',
     r'\bURLSession\s*\.shared\b|\bURLSessionConfiguration\s*\.(?:default|background)\b'
     r'|\bbackground\s*\(\s*withIdentifier\b|\b(?:sharedSession|defaultSessionConfiguration)\b'
     r'|\bbackgroundSessionConfiguration\w*|\bURLCredential\s*(?:\.\s*init\s*)?\(\s*trust\s*:|\.\s*init\s*\(\s*trust\s*:'
     r'|\bforTrust\s*:|\bcredentialForTrust\b|\btypealias\b[^\n]*\bURLCredential\b'
     r'|\b' + SESSION_TASKS + r'`?\s*\(|\.\s*`?(?:download|upload)`?\s*\(\s*(?:for|from|resumeFrom)\s*:'
     r'|\.\s*`?(?:data|bytes)`?\s*\(\s*from\s*:', SWIFT, None, BOTH),
    # A task-making call kept by name, `let start = session.dataTask`, and the name in a string, where it can be
    # looked up. A property of one's own may have such a name, so `self.streamTask` and `streamTask = ...` pass.
    ('session-shape', 'network: a task-making call', r'(?<!\bself)\.\s*`?' + SESSION_TASKS + r'\b(?!`?\s*=(?!=))',
     SWIFT, None, 'code'),
    ('session-shape', 'network: a task-making call', r'\b' + SESSION_TASKS + r'\b', SWIFT, None, 'strings'),
    # Where the session types can be named, the type can also be left out: `let session: URLSession = .shared`.
    # So no `.shared` or `.default` there at all, but for a queue's or a task's priority. An alias, a subclass or an
    # extension of a session type would let another file use it under a name `url-session` doesn't know, and a
    # member looked up by name or by selector is not one this check can read.
    ('session-shape', 'network: a shared or default session with its type left out, a session type renamed, '
     'or a member looked up by name',
     r'(?<!qos: )(?<!priority: )\.`?(?:shared|default)\b'
     r'|\btypealias\b[^\n]*\b(?:URLSession\w*|URLRequest|HTTPURLResponse|AsyncBytes)\b'
     r'|\b(?:class|extension)\b[^\n{]*\bURLSession(?:Configuration)?\b'
     r'|\bforKey(?:Path)?\s*:|\bperform\s*\(|\bSelector\s*\(|#selector\b', SWIFT, inside(*NETWORK_FILES), BOTH),
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
     r'|CoreBluetooth|IOBluetooth|ExternalAccessory|IOKit|OSAKit|ScriptingBridge|FileProvider|NetFS'
     r'|DiskArbitration)\b', SWIFT, None, BOTH),
    ('telemetry', 'telemetry, crash reporting or self-update',
     r'\b(?:Sparkle|SPUUpdater\w*|SPUStandardUpdaterController|SUUpdater|Firebase\w*|Crashlytics|Sentry\w*'
     r'|Bugsnag\w*|Mixpanel|Amplitude\w*|TelemetryDeck|TelemetryClient|TelemetryManager|PostHog\w*|AppCenter\w*'
     r'|MSAppCenter|Datadog\w*|NewRelic\w*|Instabug\w*|Countly|PLCrashReporter|KSCrash\w*|MXMetricManager'
     r'|OSLogStore|NSSetUncaughtExceptionHandler)\b', SWIFT),
    ('unified-log', 'unified log, which keeps what it is given and goes into diagnostic reports',
     r'\b(?:NSLogv?|os_log|os_signpost|OSSignposter|v?syslog|asl_v?log)\s*\(|\bLogger\s*\(|'
     + IMPORT + r'(?:os(?:\.log)?|OSLog)\b', SWIFT, None, BOTH),
    ('identifier', 'identifier of the person or the Mac',
     r'\b(?:NSUserName|NSFullUserName|CSCopyUserName|CSCopyMachineName|getlogin(?:_r)?|getpwuid(?:_r)?'
     r'|getpwnam(?:_r)?|gethostuuid|gethostname|getifaddrs|SCDynamicStoreCopy\w+|IOPlatformExpertDevice'
     r'|kIOPlatform\w+Key|IORegistryEntryCreateCFProperty|IOServiceGetMatchingService\w*|ASIdentifierManager'
     r'|advertisingIdentifier|identifierForVendor|ATTrackingManager)\b'
     r'|ProcessInfo\.processInfo\.(?:hostName|userName|fullUserName|globallyUniqueString)\b|\bHost\.current\s*\('
     # The account name, read from the environment.
     r'|\b(?:getenv\s*\(|environment\s*\[)\s*"(?:USER|LOGNAME)"', SWIFT),
    # Sending a file back to its cloud, the File Provider manager and mounting a server are hand-offs too. Helm
    # gives a server address to macOS and mounts nothing itself.
    ('hand-off', 'hand-off to iCloud, Handoff, Spotlight, a cloud provider, a server or other apps',
     r'\b(?:NSUserActivity|CSSearchable\w+|INInteraction|INVoiceShortcut\w*|NSUbiquitousKeyValueStore'
     r'|CK(?:Container|Database|Record|Query|Share)\w*|forUbiquityContainerIdentifier|ubiquityIdentityToken'
     r'|startDownloadingUbiquitousItem|evictUbiquitousItem|setUbiquitous|kSecAttrSynchronizable|NSFileProvider\w*'
     r'|NetFSMount\w*|NSDocumentController|noteNewRecentDocument\w*|LSSharedFileList\w*|NSAppleScript|OSAScript'
     r'|AESend\w*|NSDistributedNotificationCenter|DistributedNotificationCenter'
     r'|CFNotificationCenterGetDistributedCenter|NSXPCConnection|SMJobBless)\b', SWIFT),
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
     r'|\bNSImage\s*\(\s*byReferencing\s*:|\bNSAttributedString\s*\(\s*(?:url|html)\s*:', SWIFT, None, BOTH),
    # NSAppTransportSecurity has an ALLOW line for App/Info.plist, and transport_security() checks what is under it.
    # settings_keys() reads the same names as a property list reader does.
    ('network-key', NETWORK_KEY_NAME, NETWORK_KEY, SETTINGS),
    # Code from a package or a binary target is not read by this check.
    ('package', 'package dependency or binary target', r'\.(?:package|binaryTarget)\s*\(', ('Package.swift',)),
    ('package', 'remote package', r'^[ \t]*url[ \t]*:', ('.yml',)),

    # The release check finds these paths in the shipped app. A comment doesn't ship, so only strings count, with
    # each Unicode escape read as its character. `#file` and `#filePath` become the path of the file being built.
    ('build-path', 'a path on the Mac that built it, in a string',
     unescaped(r'/Users/|/var/folders/|DerivedData/'), SWIFT, inside('Sources/'), 'strings'),
    ('build-path', 'a path on the Mac that built it, in a string', r'#file(?:Path)?\b', SWIFT, inside('Sources/'), 'code'),

    # Foundation's ways to change a file or start a tool. A type's name counts wherever it stands, so an alias and
    # a value whose type is left to inference fail too, and a method's name counts whether or not it is called.
    # `Process` passes only as a plain word in a sentence.
    ('agent-no-write', WRITES,
     r'\b(?:(?:NS)?FileManager|(?:NS)?FileHandle|NSFileCoordinator|(?:NS)?FileWrapper|(?:NS)?OutputStream'
     r'|(?:NS)?UserDefaults|CFPreferences\w*|NSKeyedArchiver'
     r'|(?:removeItem|moveItem|copyItem|replaceItem|trashItem|createDirectory|createFile)(?:At\w*)?|setResourceValues?'
     r'|DispatchIO|f?setxattr|f?removexattr|rename(?:at|x_np|atx_np)|NSTask|NSUser\w*Task|posix_spawn\w*|NSWorkspace'
     r'|NSFileVersion|NSAppleEventDescriptor|Darwin|Glibc|Musl)\b'
     r'|\.\s*`?write\b|\bwrite`?\s*\(\s*to(?:File)?\s*:|\bProcess\b(?![ \t]+[a-z])', SWIFT, inside(AGENT)),
    # In a comment or a string a call is the name and its bracket, so a sentence such as "a link (never followed)"
    # passes. In code a space or a line break may come between them, or the name may stand alone, handed on to be
    # called later. C's `remove(path)` and `rename(old, new)` are told from Helm's own `remove` and `rename` by
    # having no label.
    ('agent-no-write', WRITES, bare(WRITE_CALLS), SWIFT, inside(AGENT)),
    ('agent-no-write', WRITES, bare(WRITE_CALLS, r'\s+'), SWIFT, inside(AGENT), 'code'),
    ('agent-no-write', WRITES, c_references(WRITE_CALLS + '|rename|remove'), SWIFT, inside(AGENT), 'code'),
    ('agent-no-write', WRITES, BARE + r'rename`?\([^(),:\n]*,[^(),:\n]*\)', SWIFT, inside(AGENT)),
    ('agent-no-write', WRITES, c_calls('rename', 2), SWIFT, inside(AGENT), 'code'),
    ('agent-no-write', WRITES, BARE + r'remove`?\([^(),:\n]+\)', SWIFT, inside(AGENT)),
    ('agent-no-write', WRITES, c_calls('remove', 1), SWIFT, inside(AGENT), 'code'),
    # Three modules are all it needs. Darwin's calls come with Foundation, which is why they are caught by name.
    ('agent-no-write', "AI mode's module: an import other than Foundation, Security and HelmCore",
     IMPORT + r'(?!(?:struct|class|enum|func|var|let|typealias|protocol)\s)(?!(?:Foundation|Security|HelmCore)\b)\w+',
     SWIFT, inside(AGENT), BOTH),
    # A bundle made from a path reads the Info.plist inside it, and completing a path lists a folder.
    ('agent-no-read', READS,
     r'\b(?:contentsOf(?:Mapped)?File|contentsOfDirectory|(?:NS)?InputStream|NSKeyedUnarchiver|f?getxattr|f?listxattr'
     r'|(?:promisedItemR|r)esourceValues|get(?:PromisedItem)?ResourceValue|check(?:Resource|PromisedItem)IsReachable\w*'
     r'|resolvingSymlinksInPath|NSMetadataQuery|NSMetadataItem|completePath|resolvingAliasFileAt|bookmarkData\w*'
     r'|resolvingBookmarkData)\b|\benumerator\s*\(|\bBundle\s*(?:\.\s*init\s*)?\(\s*(?:path|url)\s*:',
     SWIFT, inside(AGENT), BOTH),
    ('agent-no-read', READS, bare(READ_CALLS), SWIFT, inside(AGENT)),
    ('agent-no-read', READS, bare(READ_CALLS, r'\s+'), SWIFT, inside(AGENT), 'code'),
    ('agent-no-read', READS, c_references(READ_CALLS), SWIFT, inside(AGENT), 'code'),

    # A string handed to Text as a key is read as Markdown, and its links can be clicked. A key can be made by
    # name or by a literal's own initializer. Link detection may only be turned off, by `= false` and nothing more.
    # A link attribute, text checking, HTML and the Services menu are other ways to make a link or to send text away;
    # the tool code `.link` is read and compared, never given a value or called.
    ('agent-ui-plain', PLAIN,
     r'(?i:markdown)|\bLocalizedString(?:Key|Resource)\b|\b(?:stringLiteral|stringInterpolation)\s*:'
     r'|\bLink`?\s*(?:[(<]|\.init\b)|\bShareLink\b|\bNSDataDetector\b|\bdataDetectorTypes\b'
     r'|\bisAutomatic(?:Link|Data)DetectionEnabled\b(?!\s*=\s*false\s*(?:;|$|\}|//|/\*))'
     r'|\btoggleAutomatic(?:Link|Data)Detection\b'
     r'|\.\s*`?link`?\s*(?:=(?!=)|\()|[\[,]\s*\.link\s*:|\.\s*Key\s*\.\s*link\b|\bLinkAttribute\b'
     r'|\benabledTextCheckingTypes\b|\bcheckTextInDocument\b|\bdocumentType\b|\bNSPerformService\b'
     r'|\bopenURL\b|\bOpenURLAction\b|\bNSWorkspace\b|\bLSOpen\w*|\bNSSharingService\w*|\bNSTask\b'
     r'|\bProcess\b(?![ \t]+[a-z])', SWIFT, inside(*AGENT_UI)),
    # A key can also be made with no name at all: `Text(.init(reply))`, or `Text(.init((reply)))`. So a call's first
    # argument is never `.init(` with a plain value in it; `.padding(.init(top: 4, ...))` has a label and passes.
    ('agent-ui-plain', 'AI panel and AI search: `.init(` as a first argument, which can make a text key. Write the type',
     r'\(\s*\.init\s*\(\s*(?:\(\s*)*(?!`?[A-Za-z_]\w*`?\s*:)[^()\s]', SWIFT, inside(*AGENT_UI)),
]

# What only these files may say, and the folder the rule looks in when that isn't everywhere.
ONE_FILE = [
    # The keychain, by either of its interfaces. Under Sources/HelmAgent, the rest of the Security framework too,
    # so the transport can't weigh a certificate itself.
    (r'\bSecItem\w*|\bSecKeychain\w*', {KEYCHAIN}, None),
    (r'\bk?Sec[A-Z]\w*', {KEYCHAIN}, AGENT),
    # The one call that turns a key into text, and the one way to hand a session a loader of its own.
    (r'\brevealSecret\b', {SECRETS, KEYCHAIN, TRANSPORT}, None),
    (r'\bprotocolClasses\b', {TRANSPORT}, None),
]
# The first label of an initializer, the type it makes, and the only files that may call it. A declaration,
# `init(fromPerson text: String`, has no colon after the label, so it passes; `.init(fromPerson:` and a call that
# leaves the type to inference don't. `X.init`, `X.self` and an alias of X can make the value with no label
# written, so they are held to the same files.
GUARDED = [
    ('tickedByPerson', 'AgentApprovedPlan', {PLAN_CARD}),
    ('typedByPerson', 'AgentPersonInput', {PANEL_MODEL}),
    ('fromPerson', 'AgentRootInput', {PANEL_MODEL, WINDOW_AGENT}),
    ('liveProfile', 'HTTPTransport', {LIVE_PARTS}),
]
ONE_FILE += [(r'\b' + label + r'`?\s*:|\b' + made + r'\s*\.\s*(?:init|self)\b'
              r'|\btypealias\s+\w+\s*=\s*(?:\w+\s*\.\s*)*' + made + r'\b', homes, None) for label, made, homes in GUARDED]
# A label's file of declaration may name it in a comment, which calls nothing; its code and strings are held as
# anywhere else. The code is read too, so a comment between a label and its colon hides nothing.
DECLARING = [None] * (len(ONE_FILE) - len(GUARDED)) + [DECLARED.get(label) for label, _, _ in GUARDED]
RULES += [('one-file', 'a call or a label that belongs to another file', pattern, SWIFT,
           lambda rel, homes=homes, folder=folder, declared=declared:
           rel not in homes and rel != declared and rel.startswith(folder or ''), BOTH)
          for (pattern, homes, folder), declared in zip(ONE_FILE, DECLARING)]
RULES += [('one-file', 'a call or a label that belongs to another file', pattern, SWIFT,
           lambda rel, homes=homes, declared=declared: rel == declared and rel not in homes, ('code', 'strings'))
          for (pattern, homes, _), declared in zip(ONE_FILE, DECLARING) if declared]

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
    # The four model providers with a fixed address. An address on this Mac is put together from 127.0.0.1 and a
    # port, and the address of any other provider is typed by the person, so neither is written out anywhere.
    ('web-address', ENDPOINTS, 'static let claudeBase = "https://api.anthropic.com"'),
    ('web-address', ENDPOINTS, 'static let openAIBase = "https://api.openai.com/v1"'),
    ('web-address', ENDPOINTS, 'static let geminiBase = "https://generativelanguage.googleapis.com/v1beta"'),
    ('web-address', ENDPOINTS, 'static let grokBase = "https://api.x.ai/v1"'),
    # Plain http to a model on this Mac. transport_security() holds what is under the key to ATS_SHAPE.
    ATS_KEY,
]
ALLOWED = {(rule, rel, line.strip()) for rule, rel, line in ALLOW}
# Info.plist has no such key unless a local model can't be reached without it, so its entry is never called gone.
MAY_BE_ABSENT = {ATS_KEY}

LITERAL = re.compile(r'(#*)("""|")')
REGEX_LITERAL = re.compile(r'(#+)/')


def layers(text):
    """Two copies of `text` with the same length and line breaks. The first is the code: comments and the text of
    string literals are blanked. The second is the text of string literals and nothing else. What is written
    inside an interpolation, `\\( ... )`, is code."""
    code, strings = list(text), [char if char == '\n' else ' ' for char in text]

    def blank(start, stop, keep=False):
        for at in range(start, min(stop, len(text))):
            if text[at] != '\n':
                code[at] = ' '
                if keep:
                    strings[at] = text[at]

    # `literal` is the hashes and the quote of the string being read. `interpolations` holds, for each
    # interpolation that is open, the literal it is in and how many brackets are open inside it.
    index, end, literal, interpolations = 0, len(text), None, []
    while index < end:
        if literal:
            hashes, quote = literal
            escape = '\\' + hashes
            if text.startswith(quote + hashes, index):
                index += len(quote + hashes)
                literal = None
            elif text.startswith(escape + '(', index):
                index += len(escape) + 1
                interpolations.append([literal, 0])
                literal = None
            elif text.startswith(escape, index):
                blank(index, index + len(escape) + 1, keep=True)
                index += len(escape) + 1
            elif text[index] == '\n' and quote == '"':
                literal = None  # A one-line string that never closed. The next line is code again.
            else:
                blank(index, index + 1, keep=True)
                index += 1
            continue
        string, regex = LITERAL.match(text, index), REGEX_LITERAL.match(text, index)
        if text.startswith('//', index):
            stop = text.find('\n', index)
            stop = end if stop < 0 else stop
            blank(index, stop)
            index = stop
        elif text.startswith('/*', index):
            stop, depth = index + 2, 1
            while stop < end and depth:
                if text.startswith('/*', stop):
                    depth, stop = depth + 1, stop + 2
                elif text.startswith('*/', stop):
                    depth, stop = depth - 1, stop + 2
                else:
                    stop += 1
            blank(index, stop)
            index = stop
        elif string:
            literal = (string.group(1), string.group(2))
            index = string.end()
        elif regex and text.find('/' + regex.group(1), regex.end()) >= 0:
            # `#/ ... /#` is a regular expression. A quote inside it opens no string.
            stop = text.find('/' + regex.group(1), regex.end()) + len(regex.group())
            blank(index, stop)
            index = stop
        else:
            if interpolations and text[index] == '(':
                interpolations[-1][1] += 1
            elif interpolations and text[index] == ')':
                if interpolations[-1][1]:
                    interpolations[-1][1] -= 1
                else:
                    literal = interpolations.pop()[0]
            index += 1
    return ''.join(code), ''.join(strings)


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


def finder(pattern):
    if callable(pattern):
        return pattern
    compiled = re.compile(pattern, re.M)
    return lambda text: ((match.start(), match.group()) for match in compiled.finditer(text))


def missing_network_files(root):
    """A file in NETWORK_FILES is let off a rule by its path, so the path has to be a real file."""
    if not (root / AGENT).is_dir():
        return []
    return [f'{rel}:1: privacy: the file that may name a URL session is missing [url-session]: {rel}'
            for rel in sorted(NETWORK_FILES) if not (root / rel).is_file()]


def property_list(data):
    """The property list in `data`, or None when it isn't one."""
    try:
        return plistlib.loads(data)
    except Exception:
        return None


def key_names(data):
    """Every `<key>` of an XML property list as a reader sees it, with character references and CDATA read, or None
    when `data` isn't XML."""
    try:
        return [key.text or '' for key in ElementTree.fromstring(data).iter('key')]
    except Exception:
        return None


def transport_security(root):
    """App/Info.plist has no NSAppTransportSecurity key, or has it once, at the top, holding exactly ATS_SHAPE. The key
    is looked for as macOS reads it too, so a character reference in its name hides nothing."""
    path, name = root / INFO_PLIST, b'NSAppTransportSecurity'
    data = path.read_bytes() if path.is_file() else b''
    parsed, keys = property_list(data), key_names(data)
    if name not in data and not (isinstance(parsed, dict) and name.decode() in parsed) and name.decode() not in (keys or []):
        return []
    found = parsed.get(name.decode()) if isinstance(parsed, dict) else None
    read = data.count(name) if keys is None else keys.count(name.decode())
    if (data.count(name) == 1 and read == 1 and found == ATS_SHAPE
            and all(value is True for value in found.values())):
        return []
    number = data.count(b'\n', 0, data.find(name)) + 1 if name in data else 1
    return [f'{INFO_PLIST}:{number}: privacy: {NETWORK_KEY_NAME} [network-key]: '
            f'NSAppTransportSecurity may be there once, holding NSAllowsLocalNetworking = true and nothing else']


def settings_keys(root):
    """A network key in a property list or an entitlements file under App/, as a property list reader sees it. The
    raw text is read by `network-key`; this finds a name written so that only a reader sees it, such as one with a
    character reference in it."""
    app, problems, network_key = root / 'App', [], re.compile(NETWORK_KEY)
    for path in sorted(app.rglob('*')) if app.is_dir() else []:
        if not path.is_file() or path.suffix not in ('.plist', '.entitlements'):
            continue
        data, rel = path.read_bytes(), path.relative_to(root).as_posix()
        parsed, keys, values = property_list(data), set(key_names(data) or []), []
        while parsed is not None:
            if isinstance(parsed, dict):
                keys.update(key for key in parsed if isinstance(key, str))
                values.extend(parsed.values())
            elif isinstance(parsed, list):
                values.extend(parsed)
            parsed = values.pop() if values else None
        for key in sorted(keys):
            if network_key.search(key) and key.encode() not in data:
                problems.append(f'{rel}:1: privacy: {NETWORK_KEY_NAME} [network-key]: {key}, as a property list reader '
                                f'reads it')
    return problems


def file_problems(rel, text, used=None):
    """The problems in one file, from its path under ROOT and its text. An ALLOW entry that matched goes in `used`."""
    # Split on \n only, as the line numbers below count. splitlines() also splits on form feeds and
    # other breaks, which would pair a match with the wrong line and so with the wrong ALLOW entry.
    lines = text.split('\n')
    views, reported, problems = {'text': text}, set(), []
    for row in RULES:
        rule, name, pattern, suffixes = row[:4]
        where, view = row[4] if len(row) > 4 else None, row[5] if len(row) > 5 else 'text'
        if not applies(Path(rel), suffixes) or (where and not where(rel)):
            continue
        find = finder(pattern)
        wanted = view if isinstance(view, tuple) else (view,)
        # A string keeps its characters where they were, so what the raw text lacks its strings lack too.
        if wanted == ('strings',) and next(iter(find(text)), None) is None:
            continue
        if any(each not in views for each in wanted):
            views['code'], views['strings'] = layers(text)
        for start, words in (found for each in wanted for found in find(views[each])):
            # Two patterns of one rule can find the same call, once in the raw text and once in the code.
            if (rule, start) in reported:
                continue
            reported.add((rule, start))
            number = text.count('\n', 0, start) + 1
            line = lines[number - 1].strip() if number <= len(lines) else ''
            entry = (rule, rel, line)
            if entry in ALLOWED:
                if used is not None:
                    used.add(entry)
                continue
            problems.append(f'{rel}:{number}: privacy: {name} [{rule}]: {" ".join(words.split())}')
    return problems


def check(root):
    """Returns the files read, the problems found and the ALLOW entries that matched nothing."""
    scanned, problems, used = files(root), [], set()
    for path in scanned:
        rel = path.relative_to(root).as_posix()
        problems += file_problems(rel, path.read_text(encoding='utf-8', errors='replace'), used)
    problems += missing_network_files(root) + transport_security(root) + settings_keys(root)
    return scanned, problems, sorted(ALLOWED - used - MAY_BE_ABSENT)


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
