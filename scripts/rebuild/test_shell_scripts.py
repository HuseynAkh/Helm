# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
"""Exercise shell gates with fake Swift commands; no Swift build in these fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).parent
PLIST = ('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
         '<key>CFBundleExecutable</key><string>Helm</string></dict></plist>\n')
RELEASE = SCRIPTS.parent / 'release'
BINARY_CHECK = RELEASE / 'check_binary_privacy.sh'
SYMBOL_LIST = RELEASE / 'allowed_network_symbols.txt'
ADDRESS_LIST = RELEASE / 'allowed_addresses.txt'
NEEDS_MAC = (sys.platform == 'darwin' and shutil.which('otool') is not None, 'the binary check needs macOS tools')

# What a transport that keeps DESIGN.md section 3 imports, as `nm -um | swift-demangle` spells it: an ephemeral
# session, a request with its method, body, header and time limit set, the request handed to the delegate that
# refuses every redirect, the async data and bytes calls, and the bytes read one at a time and as lines.
SESSION = '(extension in Foundation):__C.NSURLSession'
BYTES = f'{SESSION}.AsyncBytes'
DATA_CALL = (f'{SESSION}.data(for: Foundation.URLRequest, delegate: __C.NSURLSessionTaskDelegate?) async throws '
             '-> (Foundation.Data, __C.NSURLResponse)')
BYTES_CALL = (f'{SESSION}.bytes(for: Foundation.URLRequest, delegate: __C.NSURLSessionTaskDelegate?) async throws '
              f'-> ({BYTES}, __C.NSURLResponse)')
TRANSPORT_SYMBOLS = [
    '_OBJC_CLASS_$_NSURLSession', '_OBJC_CLASS_$_NSURLSessionConfiguration', '_OBJC_CLASS_$_NSHTTPURLResponse',
    'type metadata accessor for Foundation.URLRequest', 'nominal type descriptor for Foundation.URLRequest',
    'Foundation.URLRequest.init(url: Foundation.URL, cachePolicy: __C.NSURLRequestCachePolicy, '
    'timeoutInterval: Swift.Double) -> Foundation.URLRequest',
    'Foundation.URLRequest.httpMethod.setter : Swift.String?', 'Foundation.URLRequest.httpBody.setter : Foundation.Data?',
    'Foundation.URLRequest.setValue(_: Swift.String?, forHTTPHeaderField: Swift.String) -> ()',
    'Foundation.URLRequest.timeoutInterval.setter : Swift.Double',
    'static Foundation.URLRequest._unconditionallyBridgeFromObjectiveC(__C.NSURLRequest?) -> Foundation.URLRequest',
    DATA_CALL, f'async function pointer to {DATA_CALL}', BYTES_CALL, f'async function pointer to {BYTES_CALL}',
    f'type metadata accessor for {BYTES}', f'nominal type descriptor for {BYTES}',
    f'protocol conformance descriptor for {BYTES} : Swift.AsyncSequence in Foundation',
    '(extension in Foundation):Swift.AsyncSequence< where A.Element == Swift.UInt8>.lines.getter : '
    'Foundation.AsyncLineSequence<A>',
]
# Matched by a prefix entry of the list, not an exact one.
BY_PREFIX = f'{BYTES}.makeAsyncIterator() -> {BYTES}.Iterator'
# Imports that aren't for the network at all.
ORDINARY_SYMBOLS = ['_exit', 'Swift.print(_: Any..., separator: Swift.String, terminator: Swift.String) -> ()',
                    'type metadata accessor for Foundation.URL', '_OBJC_CLASS_$_NSFileManager']
# The API members CONTRACTS.md section 10 lets allowed_network_symbols.txt name, and nothing else.
LIST_MEMBERS = [
    r'_OBJC_CLASS_\$_NSURLSession(Configuration)?',
    r'(type metadata accessor|nominal type descriptor) for Foundation\.URLRequest',
    r'Foundation\.URLRequest\.init\(url: .*',
    r'Foundation\.URLRequest\.(httpMethod|httpBody|timeoutInterval)\.setter : .*',
    r'Foundation\.URLRequest\.setValue\(_: Swift\.String\?, forHTTPHeaderField: Swift\.String\) -> \(\)',
    # The redirect delegate's request arrives through this bridge; it reads nothing from the network.
    r'static Foundation\.URLRequest\._unconditionallyBridgeFromObjectiveC\(__C\.NSURLRequest\?\) -> Foundation\.URLRequest',
    r'(async function pointer to )?\(extension in Foundation\):__C\.NSURLSession\.(data|bytes)\(for: .*',
    r'((type metadata accessor|nominal type descriptor|protocol conformance descriptor) for |async function pointer to )?'
    r'\(extension in Foundation\):__C\.NSURLSession\.AsyncBytes([ .].*)?',
]


def load_privacy_check():
    spec = importlib.util.spec_from_file_location('privacy_check', SCRIPTS.parent / 'privacy_check.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stand_in_app(directory, plist=PLIST):
    """A Helm.app made from /usr/bin/true, under a Release build folder."""
    app = Path(directory, 'Build/Products/Release/Helm.app')
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/Resources').mkdir()
    shutil.copyfile('/usr/bin/true', app / 'Contents/MacOS/Helm')
    (app / 'Contents/Info.plist').write_text(plist)
    return app


def tool_stand_ins(directory, symbols=None, methods=None, libraries=None):
    """A folder to put first on PATH: nm prints `symbols` as `nm -um` does, already demangled, and otool prints
    `methods` as the Objective-C method names and `libraries` as the linked libraries. Every other use of otool
    goes to the real one."""
    folder = Path(directory, 'tools')
    folder.mkdir()
    if symbols is not None:
        listing = Path(directory, 'symbols.txt')
        listing.write_text('Helm (for architecture arm64):\n'
                           + ''.join(f'                 (undefined) external {name} (from Foundation)\n' for name in symbols))
        (folder / 'nm').write_text(f'#!/bin/bash\ncat "{listing}"\n')
    if methods is not None or libraries is not None:
        cases = ''
        if methods is not None:
            names = Path(directory, 'methods.txt')
            names.write_text('Helm:\nContents of (__TEXT,__objc_methname) section\n'
                             + ''.join(f'{0x100003f00 + index:016x}  {name}\n' for index, name in enumerate(methods)))
            cases += f'*" __objc_methname "*) cat "{names}" ;;\n'
        if libraries is not None:
            linked = Path(directory, 'libraries.txt')
            linked.write_text('Helm (architecture arm64):\n'
                              + ''.join(f'\t{library} (compatibility version 1.0.0, current version 1.0.0)\n'
                                        for library in libraries))
            cases += f'*" -L "*) cat "{linked}" ;;\n'
        (folder / 'otool').write_text(f'#!/bin/bash\ncase " $* " in\n{cases}'
                                      f'*) exec "{shutil.which("otool")}" "$@" ;;\nesac\n')
    for tool in folder.iterdir():
        tool.chmod(0o755)
    return dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}')


def binary_check(app, env=None, script=BINARY_CHECK, *options):
    return subprocess.run(['bash', str(script), *options, str(app)], env=env, capture_output=True, text=True)


def url_family(names):
    """The names check 3 holds to allowed_network_symbols.txt."""
    return [name for name in names if 'URLSession' in name or 'URLRequest' in name]


def failures(output):
    """Each FAIL line with the indented lines under it, as one block of text per failure."""
    blocks, current = [], None
    for line in output.splitlines():
        if line.startswith('FAIL '):
            current = [line]
            blocks.append(current)
        elif line.startswith('       ') and current is not None:
            current.append(line.strip())
        else:
            current = None
    return ['\n'.join(block) for block in blocks]


class ShellTests(unittest.TestCase):
    def test_parse_handles_spaces_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'Sources/HelmUI'
            folder.mkdir(parents=True)
            (folder / 'With space.swift').write_text('// syntax fixture')
            for status in (0, 1):
                command = f'swiftc() {{ return {status}; }}; export -f swiftc; bash "$1" "$2"'
                result = subprocess.run(['bash', '-c', command, 'fixture', str(SCRIPTS / 'parse_check_ui.sh'), str(root)], capture_output=True, text=True)
                self.assertEqual(result.returncode, status)
                self.assertIn('1 files', result.stdout)
                self.assertIn('syntax only', result.stdout)

    def test_parse_empty_is_explicit_not_run(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', str(SCRIPTS / 'parse_check_ui.sh'), directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('NOT RUN', result.stdout)

    def test_runner_failure_zero_skipped_and_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/rebuild'
            scripts.mkdir(parents=True)
            shutil.copyfile(SCRIPTS / 'run_all.sh', scripts / 'run_all.sh')
            (root / 'scripts/static_checks.sh').write_text('exit 0\n')
            (scripts / 'parse_check_ui.sh').write_text('exit 0\n')
            (scripts / 'check_core_type_names.py').write_text('')
            (scripts / 'check_coverage.py').write_text('print("fixture coverage")\n')
            (scripts / 'test_fixture.py').write_text('import unittest\nclass Fixture(unittest.TestCase):\n def test_one(self): pass\n')
            for name in ('test_static_checks.py', 'test_privacy_check.py'):
                (root / 'scripts' / name).write_text('import unittest\nclass Fixture(unittest.TestCase):\n def test_one(self): pass\n')
            for count, skipped, build_status, expected in ((2, 0, 0, 0), (0, 0, 0, 1), (2, 2, 0, 1), (2, 1, 0, 0), (2, 0, 1, 1)):
                log = f'Executed {count} tests, with {skipped} tests skipped and 0 failures'
                command = 'swift() { if [[ "$1" == build ]]; then return "$BUILD_STATUS"; fi; echo "$TEST_LOG"; }; export -f swift; bash "$1"'
                env = dict(os.environ, HELM_K11_SCRATCH=str(root / 'scratch'), TEST_LOG=log, BUILD_STATUS=str(build_status), PLAN_DIR=str(root))
                result = subprocess.run(['bash', '-c', command, 'fixture', str(scripts / 'run_all.sh')], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(f'{count} executed; {skipped} skipped', result.stdout)

    @unittest.skipUnless(sys.platform == 'darwin', 'the binary check needs macOS tools')
    def test_binary_check_paths_and_signatures(self):
        # Xcode writes /var/... and /tmp/... where pwd says /private/var/... and /private/tmp/....
        # /usr/bin/true has Apple's signature, whose certificates name web addresses. They don't count.
        with tempfile.TemporaryDirectory() as directory:
            build = str(Path(directory).resolve())
            app = Path(build, 'Build/Products/Release/Helm.app')
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            shutil.copyfile('/usr/bin/true', app / 'Contents/MacOS/Helm')
            (app / 'Contents/Info.plist').write_text(PLIST)
            short = build.removeprefix('/private')
            (app / 'Contents/Resources/leak.txt').write_text(f'object={short}/Build/Intermediates.noindex/a.o\n')
            result = subprocess.run(['bash', str(SCRIPTS.parent / 'release/check_binary_privacy.sh'), str(app)],
                                    capture_output=True, text=True)
            if result.returncode == 2:
                self.skipTest(result.stderr.strip())
            self.assertIn('FAIL files with paths from the build machine', result.stdout)
            self.assertIn('Contents/Resources/leak.txt', result.stdout)
            self.assertIn('ok   web addresses: none', result.stdout)

    @unittest.skipUnless(*NEEDS_MAC)
    def test_binary_check_holds_url_session_symbols_to_the_list(self):
        # The symbols a transport that keeps the design imports pass, one of them through a prefix entry. Anything
        # else that names a URL session or request fails: a task, the shared session, a call not on the list.
        # A cache type fails whatever the list says.
        fixture = TRANSPORT_SYMBOLS + [BY_PREFIX] + ORDINARY_SYMBOLS
        methods = ['init', 'ephemeralSessionConfiguration', 'sessionWithConfiguration:delegate:delegateQueue:']
        with tempfile.TemporaryDirectory() as directory:
            app = stand_in_app(directory)
            result = binary_check(app, tool_stand_ins(directory, fixture, methods))
            if result.returncode == 2:
                self.skipTest(result.stderr.strip())
            self.assertIn(f'ok   imported symbols: {len(fixture)}, none for the network or identifiers but '
                          f'{len(url_family(fixture))} URL session symbols on allowed_network_symbols.txt', result.stdout)
            self.assertNotIn('FAIL imported', result.stdout)
        refused = {
            'a data task class': '_OBJC_CLASS_$_NSURLSessionDataTask',
            'a data task call': f'{SESSION}.dataTask(with: Foundation.URLRequest) -> __C.NSURLSessionDataTask',
            'the task an async bytes holds': f'{BYTES}.task.getter : __C.NSURLSessionDataTask',
            'the shared session': f'static {SESSION}.shared.getter : __C.NSURLSession',
            'a download': f'{SESSION}.download(for: Foundation.URLRequest, delegate: __C.NSURLSessionTaskDelegate?)',
            'a request member not on the list': 'Foundation.URLRequest.url.getter : Foundation.URL?',
            'the request class': '_OBJC_CLASS_$_NSMutableURLRequest',
        }
        for case, symbol in refused.items():
            with self.subTest(case), tempfile.TemporaryDirectory() as directory:
                app = stand_in_app(directory)
                result = binary_check(app, tool_stand_ins(directory, TRANSPORT_SYMBOLS + [symbol], methods))
                found = [block for block in failures(result.stdout) if symbol in block.splitlines()[1:]]
                self.assertEqual(len(found), 1, result.stdout)
                self.assertTrue(found[0].startswith("FAIL imported URL session symbols that aren't on "
                                                    'allowed_network_symbols.txt'), found[0])
                self.assertEqual(result.returncode, 1)
        for case, symbol in {'the cache class': '_OBJC_CLASS_$_NSURLCache',
                             'the cache type in Swift': 'type metadata accessor for __C.NSURLCache',
                             'the cookie store': '_OBJC_CLASS_$_NSHTTPCookieStorage'}.items():
            with self.subTest(case), tempfile.TemporaryDirectory() as directory:
                app = stand_in_app(directory)
                result = binary_check(app, tool_stand_ins(directory, TRANSPORT_SYMBOLS + [symbol], methods))
                found = [block for block in failures(result.stdout) if symbol in block]
                self.assertEqual(len(found), 1, result.stdout)
                self.assertTrue(found[0].startswith('FAIL imported symbols for the network or identifiers:'), found[0])

    @unittest.skipUnless(*NEEDS_MAC)
    def test_binary_check_list_cannot_let_in_tasks_shared_sessions_or_caches(self):
        # A list that names them doesn't help: a task, the shared session and a cache type still fail, and the
        # entries that tried are reported. A prefix entry lets in what starts with it, and only that.
        task = f'{SESSION}.dataTask(with: Foundation.URLRequest) -> __C.NSURLSessionDataTask'
        shared = f'static {SESSION}.shared.getter : __C.NSURLSession'
        cache = 'type metadata accessor for __C.NSURLCache'
        prefixed = 'Foundation.URLRequest.url.getter : Foundation.URL?'
        unmatched = 'Foundation.URLResponse.URLRequestish.getter : Swift.Int'
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory, 'Checkout/scripts/release')
            release.mkdir(parents=True)
            shutil.copyfile(BINARY_CHECK, release / BINARY_CHECK.name)
            shutil.copyfile(ADDRESS_LIST, release / ADDRESS_LIST.name)
            (release / SYMBOL_LIST.name).write_text('\n'.join(['Foundation.URLRequest.url.*', task, shared, cache, '*', '']))
            app = stand_in_app(directory)
            env = tool_stand_ins(directory, [prefixed, unmatched, task, shared, cache], ['init'])
            result = binary_check(app, env, release / BINARY_CHECK.name)
            if result.returncode == 2:
                self.skipTest(result.stderr.strip())
            self.assertEqual(result.returncode, 1, result.stdout)
            blocks = failures(result.stdout)
            symbols = next(block for block in blocks if block.startswith('FAIL imported URL session symbols')).splitlines()[1:]
            self.assertEqual(sorted(symbols), sorted([unmatched, task, shared]))
            network = next(block for block in blocks if block.startswith('FAIL imported symbols for the network'))
            self.assertIn(cache, network)
            entries = next(block for block in blocks if block.startswith('FAIL allowed_network_symbols.txt has entries'))
            self.assertEqual(sorted(entries.splitlines()[1:]), sorted(['*', cache, task, shared]))
            self.assertNotIn(prefixed, result.stdout)

    @unittest.skipUnless(*NEEDS_MAC)
    def test_network_symbols_prints_each_url_session_symbol_sorted(self):
        fixture = ORDINARY_SYMBOLS + list(reversed(TRANSPORT_SYMBOLS)) + [BY_PREFIX, TRANSPORT_SYMBOLS[0]]
        with tempfile.TemporaryDirectory() as directory:
            app = stand_in_app(directory)
            result = binary_check(app, tool_stand_ins(directory, fixture), BINARY_CHECK, '--network-symbols')
            if result.returncode == 2:
                self.skipTest(result.stderr.strip())
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = sorted(set(url_family(fixture)), key=lambda name: name.encode())
            self.assertEqual(result.stdout.splitlines(), expected)
            self.assertEqual(len(expected), len(TRANSPORT_SYMBOLS) - 1)
            self.assertNotIn('ok   ', result.stdout)
        # An app that imports none prints nothing, and that is no failure either.
        with tempfile.TemporaryDirectory() as directory:
            app = stand_in_app(directory)
            result = binary_check(app, tool_stand_ins(directory, ORDINARY_SYMBOLS), BINARY_CHECK, '--network-symbols')
            self.assertEqual((result.returncode, result.stdout), (0, ''))

    @unittest.skipUnless(*NEEDS_MAC)
    def test_binary_check_links_cfnetwork_and_no_other_network_library(self):
        # The URL session classes bind from CFNetwork, so the transport links it. Network.framework stays off the list.
        apple = ['/usr/lib/libSystem.B.dylib', '/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation']
        cfnetwork = '/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork'
        network = '/System/Library/Frameworks/Network.framework/Versions/A/Network'
        for libraries, line in ((apple + [cfnetwork], 'ok   linked libraries: 3, all on the list'),
                                (apple + [cfnetwork, network], f"FAIL linked libraries that aren't on the list: {network}")):
            with self.subTest(libraries[-1]), tempfile.TemporaryDirectory() as directory:
                result = binary_check(stand_in_app(directory), tool_stand_ins(directory, libraries=libraries))
                if result.returncode == 2:
                    self.skipTest(result.stderr.strip())
                self.assertIn(line, result.stdout)

    @unittest.skipUnless(*NEEDS_MAC)
    def test_binary_check_method_names(self):
        # Removing a downloaded copy of a cloud file, the shared session, the default configuration, a credential
        # from a server's certificate and a task-making call each leave a method name, and each fails.
        with tempfile.TemporaryDirectory() as directory:
            app = stand_in_app(directory)
            result = binary_check(app, tool_stand_ins(directory, ORDINARY_SYMBOLS,
                                                      ['init', 'ephemeralSessionConfiguration', 'URLSession:task:'
                                                       'willPerformHTTPRedirection:newRequest:completionHandler:']))
            if result.returncode == 2:
                self.skipTest(result.stderr.strip())
            self.assertIn('ok   method names: none that', result.stdout)
        for method in ('evictUbiquitousItemAtURL:error:', 'sharedSession', 'defaultSessionConfiguration',
                       'backgroundSessionConfigurationWithIdentifier:', 'credentialForTrust:',
                       'dataTaskWithRequest:completionHandler:', 'startDownloadingUbiquitousItemAtURL:error:'):
            with self.subTest(method), tempfile.TemporaryDirectory() as directory:
                app = stand_in_app(directory)
                result = binary_check(app, tool_stand_ins(directory, ORDINARY_SYMBOLS, ['init', method]))
                found = [line for line in result.stdout.splitlines() if line.startswith('FAIL method names')]
                self.assertEqual(len(found), 1, result.stdout)
                self.assertTrue(found[0].endswith(f': {method} '), found[0])
                self.assertEqual(result.returncode, 1)

    @unittest.skipUnless(*NEEDS_MAC)
    def test_binary_check_allows_only_the_listed_addresses(self):
        listed = ADDRESS_LIST.read_text().splitlines()
        cases = {
            'a listed address': (listed[0], True),
            'every listed address': ('\0'.join(listed), True),
            'another address': ('https://example.com/v1', False),
            'a listed address with more after it': (listed[0] + '.example.com', False),
            'a listed address with a path': (listed[0] + '/v1/messages', False),
            'a listed host over plain http': (listed[0].replace('https:', 'http:'), False),
        }
        for case, (text, passes) in cases.items():
            with self.subTest(case), tempfile.TemporaryDirectory() as directory:
                app = stand_in_app(directory)
                (app / 'Contents/Resources/addresses.txt').write_text(f'\0{text}\0')
                result = binary_check(app)
                if result.returncode == 2:
                    self.skipTest(result.stderr.strip())
                if passes:
                    self.assertIn("ok   web addresses: only the providers' on allowed_addresses.txt", result.stdout)
                    self.assertNotIn('FAIL web addresses', result.stdout)
                else:
                    self.assertIn("FAIL web addresses that aren't on allowed_addresses.txt:", result.stdout)
                    self.assertIn(f'Contents/Resources/addresses.txt: {text}', result.stdout)

    def test_allowed_addresses_are_the_four_provider_addresses(self):
        # The same four addresses as the source check's web-address ALLOW lines for Endpoints.swift, in that order.
        privacy = load_privacy_check()
        allowed = [re.search(r'"(https://[^"]+)"', line).group(1)
                   for rule, rel, line in privacy.ALLOW if rule == 'web-address']
        self.assertEqual(ADDRESS_LIST.read_text(), ''.join(f'{address}\n' for address in allowed))
        self.assertEqual(allowed, ['https://api.anthropic.com', 'https://api.openai.com/v1',
                                   'https://generativelanguage.googleapis.com/v1beta', 'https://api.x.ai/v1'])

    def test_allowed_network_symbols_name_only_the_designed_members(self):
        entries = SYMBOL_LIST.read_text().splitlines()
        self.assertTrue(entries)
        self.assertEqual(len(entries), len(set(entries)))
        for entry in entries:
            with self.subTest(entry):
                self.assertEqual(entry, entry.strip())
                name = entry[:-1] if entry.endswith('*') else entry
                self.assertTrue(name.strip(), 'an entry of * alone lets every symbol in')
                self.assertTrue(any(re.fullmatch(member, name if not entry.endswith('*') else name + 'x')
                                    for member in LIST_MEMBERS), entry)
                self.assertNotRegex(entry, r'([Dd]ata|[Dd]ownload|[Uu]pload|[Ss]tream|[Ww]ebSocket)Task|[Ss]hared'
                                           r'|[Bb]ackground|Cache[^P]|Cookie|Credential|default[A-Z]')
        # The transport's own symbols are all on it, one of them through a prefix entry.
        exact = {entry for entry in entries if not entry.endswith('*')}
        prefixes = [entry[:-1] for entry in entries if entry.endswith('*')]
        self.assertEqual([name for name in url_family(TRANSPORT_SYMBOLS) if name not in exact], [])
        self.assertTrue(any(BY_PREFIX.startswith(prefix) for prefix in prefixes))
        self.assertNotIn(BY_PREFIX, exact)

    @unittest.skipUnless(*NEEDS_MAC)
    def test_binary_check_transport_security(self):
        # No App Transport Security key, or one holding NSAllowsLocalNetworking = true and nothing else.
        def plist(ats):
            return PLIST.replace('</dict></plist>', f'<key>NSAppTransportSecurity</key>{ats}</dict></plist>')
        shape = load_privacy_check().ATS_SHAPE
        cases = {
            'no key': (PLIST, 'ok   Info.plist: no network, URL scheme, Handoff or update keys'),
            'local networking alone': (plist('<dict><key>NSAllowsLocalNetworking</key><true/></dict>'),
                                       'ok   Info.plist: no network, URL scheme, Handoff or update keys but '
                                       'NSAllowsLocalNetworking, for this Mac only'),
            'arbitrary loads too': (plist('<dict><key>NSAllowsLocalNetworking</key><true/>'
                                          '<key>NSAllowsArbitraryLoads</key><true/></dict>'), None),
            'arbitrary loads alone': (plist('<dict><key>NSAllowsArbitraryLoads</key><true/></dict>'), None),
            'an exception domain': (plist('<dict><key>NSAllowsLocalNetworking</key><true/><key>NSExceptionDomains</key>'
                                          '<dict><key>example.com</key><dict/></dict></dict>'), None),
            'local networking as a number': (plist('<dict><key>NSAllowsLocalNetworking</key><integer>1</integer></dict>'),
                                             None),
            'local networking off': (plist('<dict><key>NSAllowsLocalNetworking</key><false/></dict>'), None),
            'an empty dictionary': (plist('<dict/>'), None),
            'not a dictionary': (plist('<true/>'), None),
        }
        self.assertEqual(shape, {'NSAllowsLocalNetworking': True})
        self.assertIn("ats_shape='" + json.dumps(shape, separators=(',', ':')) + "'", BINARY_CHECK.read_text())
        for case, (text, line) in cases.items():
            with self.subTest(case), tempfile.TemporaryDirectory() as directory:
                result = binary_check(stand_in_app(directory, text))
                if result.returncode == 2:
                    self.skipTest(result.stderr.strip())
                if line:
                    self.assertIn(line, result.stdout)
                    self.assertNotIn('FAIL Info.plist', result.stdout)
                else:
                    self.assertIn('FAIL Info.plist has these keys: NSAppTransportSecurity', result.stdout)
        with tempfile.TemporaryDirectory() as directory:
            text = PLIST.replace('</dict></plist>', '<key>CFBundleURLTypes</key><array/></dict></plist>')
            result = binary_check(stand_in_app(directory, text))
            self.assertIn('FAIL Info.plist has these keys: CFBundleURLTypes', result.stdout)

    def test_release_scripts_parse_and_their_commands_carry_no_comments(self):
        # zsh passes a trailing "# ..." on to the command as arguments, so a line meant for copying has none.
        make_release = RELEASE / 'make_release.sh'
        for script in (BINARY_CHECK, make_release):
            with self.subTest(script.name):
                result = subprocess.run(['bash', '-n', str(script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                text = script.read_text(encoding='utf-8')
                usage = [line for line in text.splitlines()
                         if re.match(r'#\s+(usage: )?scripts/release/', line) or line.startswith('# usage:')]
                self.assertTrue(usage)
                for line in usage:
                    self.assertNotIn('#', line[1:], line)
        text = make_release.read_text(encoding='utf-8')
        block = text[text.index("printf '```sh\\n'"):text.index("printf '```\\n'")]
        commands = [line for line in block.splitlines()[1:] if line.strip()]
        self.assertTrue(commands)
        for line in commands:
            self.assertNotRegex(line, r'Helm\.app.*#', line)

    def test_release_notes_and_headers_state_the_promise(self):
        promise = 'connects only to the model provider'
        notes = (RELEASE / 'make_release.sh').read_text(encoding='utf-8')
        self.assertIn('## Privacy', notes)
        privacy = notes[notes.index('## Privacy'):notes.index('---', notes.index('## Privacy'))]
        self.assertIn(promise, privacy)
        self.assertIn('only while AI mode is on', privacy)
        self.assertNotIn('no network connections', privacy)
        self.assertIn(promise, ' '.join(line.lstrip('# ') for line in BINARY_CHECK.read_text().splitlines()[:6]))

    def smoke_fixture(self, directory, app_script):
        """A checkout with host_smoke.sh, one step for each run and a stand-in for HelmDev, in a folder with spaces."""
        root = Path(directory, 'Checkout with spaces')
        scripts = root / 'scripts/rebuild'
        (scripts / 'smoke.d').mkdir(parents=True)
        for name in ('host_smoke.sh', 'deny-network.sb'):
            shutil.copyfile(SCRIPTS / name, scripts / name)
        (scripts / 'host_smoke_steps.txt').write_text('windows 1\nquit\n')
        (scripts / 'host_smoke_restore_steps.txt').write_text('windows 1\n')
        app = root / 'Stand-in Helm'
        # Called as: --home <home> --support <support> --smoke <steps>
        app.write_text('#!/bin/bash\n' + app_script)
        app.chmod(0o755)
        return scripts / 'host_smoke.sh', app

    def test_smoke_runs_must_reach_their_end(self):
        # A run that stops early exits 0 like one that finished, so each run must show it got to its end:
        # the first run's final quit (SMOKE_QUIT) and the restore run's SMOKE_END.
        with tempfile.TemporaryDirectory() as directory:
            smoke, app = self.smoke_fixture(directory, 'echo "PASS windows 1"\ncase "$6" in\n'
                                            '*restore.txt) [ -z "$RESTORE_ENDS" ] || echo "SMOKE_END PASS all steps passed" ;;\n'
                                            '*) [ -z "$FIRST_ENDS" ] || echo SMOKE_QUIT ;;\nesac\n')
            for first, restore, expected in (('yes', 'yes', 0), ('', 'yes', 1), ('yes', '', 1)):
                env = dict(os.environ, HELM_SMOKE_BIN=str(app), HELM_SMOKE_NETWORK='allow', FIRST_ENDS=first, RESTORE_ENDS=restore)
                result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if not first:
                    self.assertIn('FAIL: the first run stopped before its last step', result.stdout)
                if not restore:
                    self.assertIn('FAIL: the restore run stopped before its last step', result.stdout)
            # A step file of its own that quits would end the first run there, and skip every step after it.
            (smoke.parent / 'smoke.d/early.txt').write_text('windows 1\nquit\n')
            env = dict(os.environ, HELM_SMOKE_BIN=str(app), HELM_SMOKE_NETWORK='allow', FIRST_ENDS='yes', RESTORE_ENDS='yes')
            result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('the steps quit before their last step', result.stderr)
            self.assertNotIn('First run exit', result.stdout)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('sandbox-exec'), 'the network block needs sandbox-exec')
    def test_smoke_network_block_stops_a_connection(self):
        # The same stand-in, finishing both runs, but the first run tries the network: the sandbox kills it.
        with tempfile.TemporaryDirectory() as directory:
            connect = 'import socket\nsocket.socket().connect(("127.0.0.1", 9))\n'
            smoke, app = self.smoke_fixture(directory, 'case "$6" in\n*restore.txt) echo "SMOKE_END PASS" ;;\n'
                                            f'*) echo SMOKE_QUIT; exec /usr/bin/python3 -I -c \'{connect}\' ;;\nesac\n')
            env = {key: value for key, value in os.environ.items() if key != 'HELM_SMOKE_NETWORK'}
            result = subprocess.run(['bash', str(smoke)], env=dict(env, HELM_SMOKE_BIN=str(app)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('Network: blocked', result.stdout)
            self.assertIn('killed in the first run, most likely for trying to use the network', result.stdout)
            self.assertIn('First run exit 137', result.stdout)

    def test_live_agent_run_leaves_out_the_scripted_steps(self):
        # HELM_SMOKE_AGENT=live: both launches get --live-agent, the steps that need the scripted model are left out,
        # and the AI-mode-off checks run after every other step file.
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory, 'record')
            smoke, app = self.smoke_fixture(directory, f'echo "ARGS $*" >> "{record}"\ncat "$6" >> "{record}"\n'
                                            'case "$6" in\n*restore.txt) echo "SMOKE_END PASS" ;;\n*) echo SMOKE_QUIT ;;\nesac\n')
            extra = smoke.parent / 'smoke.d'
            (extra / 'agent.txt').write_text('agent-scripted-step\n')
            (extra / 'agent.restore.txt').write_text('agent-scripted-restore\n')
            (extra / 'zz-other.txt').write_text('other-step\n')
            (smoke.parent / 'smoke.live').mkdir()
            (smoke.parent / 'smoke.live/off.txt').write_text('off-step\n')
            env = dict(os.environ, HELM_SMOKE_BIN=str(app), HELM_SMOKE_NETWORK='allow', HELM_SMOKE_AGENT='live')
            result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            text = record.read_text()
            self.assertEqual(text.count('--live-agent'), 2, text)
            self.assertNotIn('agent-scripted', text)
            self.assertLess(text.index('other-step'), text.index('off-step'))
            self.assertLess(text.index('off-step'), text.index('quit'))
            # The usual run has the scripted steps, no --live-agent and no off steps.
            record.unlink()
            env.pop('HELM_SMOKE_AGENT')
            result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            text = record.read_text()
            self.assertNotIn('--live-agent', text)
            self.assertIn('agent-scripted-step', text)
            self.assertIn('agent-scripted-restore', text)
            self.assertNotIn('off-step', text)
            # Anything else is refused before a run starts.
            result = subprocess.run(['bash', str(smoke)], env=dict(env, HELM_SMOKE_AGENT='other'), capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('HELM_SMOKE_AGENT is live or denied', result.stderr)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('sandbox-exec'), 'the network block needs sandbox-exec')
    def test_denied_run_passes_only_when_the_sandbox_kills_the_app(self):
        # HELM_SMOKE_AGENT=denied: one launch with --live-agent and the denied steps only. It passes when the first
        # try at the network gets the app killed, and fails when the app gets to its end, or a step failed first.
        connect = 'import socket\nsocket.socket().connect(("127.0.0.1", 9))\n'
        stand_ins = (
            (f'echo "PASS $*"\nexec /usr/bin/python3 -I -c \'{connect}\'\n', 0, 'PASS network denied'),
            ('echo "PASS $*"\necho SMOKE_QUIT\n', 1, 'exited 0, not 137'),
            (f'echo "FAIL early"\nexec /usr/bin/python3 -I -c \'{connect}\'\n', 1, 'a step failed before'),
        )
        for script, expected, line in stand_ins:
            with tempfile.TemporaryDirectory() as directory:
                smoke, app = self.smoke_fixture(directory, script)
                (smoke.parent / 'smoke.live').mkdir()
                (smoke.parent / 'smoke.live/denied.txt').write_text('denied-step\n')
                env = {key: value for key, value in os.environ.items() if key != 'HELM_SMOKE_NETWORK'}
                env.update(HELM_SMOKE_BIN=str(app), HELM_SMOKE_AGENT='denied')
                result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(line, result.stdout)
                self.assertNotIn('restore run', result.stdout)
                if expected == 0:
                    log = (smoke.parent.parent.parent / '.build/host-smoke/result.log').read_text()
                    self.assertIn('--live-agent', log)
                    self.assertIn('denied-step', (smoke.parent.parent.parent / '.build/host-smoke/steps.txt').read_text())
        with tempfile.TemporaryDirectory() as directory:
            smoke, app = self.smoke_fixture(directory, 'echo SMOKE_QUIT\n')
            env = dict(os.environ, HELM_SMOKE_BIN=str(app), HELM_SMOKE_NETWORK='allow', HELM_SMOKE_AGENT='denied')
            result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('needs the network-denied sandbox', result.stderr)

    def test_release_workflow_checks_the_source_before_building(self):
        # The README says the privacy check stops a release, and the binary check can't see everything it can,
        # such as a read from a web address: the workflow runs both checks of the source before it builds.
        workflow = (SCRIPTS.parent.parent / '.github/workflows/release.yml').read_text(encoding='utf-8')
        checks = workflow.find('run: bash scripts/static_checks.sh')
        build = workflow.find('run: bash scripts/release/make_release.sh')
        self.assertNotEqual(checks, -1, 'the release workflow never runs scripts/static_checks.sh')
        self.assertNotEqual(build, -1, 'the release workflow never runs make_release.sh')
        self.assertLess(checks, build)
        self.assertIn('python3 -I scripts/privacy_check.py', (SCRIPTS.parent / 'static_checks.sh').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
