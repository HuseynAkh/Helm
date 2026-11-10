import contextlib
import io
import re
import tempfile
import unittest
from pathlib import Path
from privacy_check import ALLOW, check, main

DTD = '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'

# Real, compiling ways to reach the network or read identifiers. Each must fail with these rules.
PLANTS = {
    'fetch with no web address written out': ('''import Foundation
func plantedFetch(_ address: URL) async throws -> Data {
    let (data, _) = try await URLSession.shared.data(from: address)
    return data
}''', {'url-loading'}),
    'Network.framework connection': ('''import Foundation
import Network
func plantedConnection() -> NWConnection {
    let connection = NWConnection(host: "example.invalid", port: 443, using: .tcp)
    connection.start(queue: .main)
    return connection
}''', {'import', 'network-framework'}),
    'BSD socket': ('''import Darwin
func plantedSocket() -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return result == 0 ? fd : -1
}''', {'sockets', 'socket-call'}),
    'ways around a name search': ('''import Foundation
import Darwin
@_silgen_name("connect") private func rawConnect(_ fd: Int32, _ address: UnsafeRawPointer?, _ length: UInt32) -> Int32
func plantedEvasions() throws {
    let fd = Darwin.socket(PF_INET, SOCK_DGRAM, 0)
    _ = rawConnect(fd, nil, 0)
    let sessionClass: AnyClass? = NSClassFromString("NSURLSession")
    print("\\(String(describing: sessionClass)) \\(NSFullUserName()) \\(ProcessInfo.processInfo.hostName)")
    let tool = Process()
    tool.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    tool.arguments = ["-s", "https://telemetry.example.invalid/ping"]
    try tool.run()
}''', {'url-loading', 'sockets', 'socket-call', 'identifier', 'dynamic-lookup', 'web-address', 'network-tool',
       'tool-path'}),
}


def rules(problems):
    return {re.search(r'\[([\w-]+)\]', problem).group(1) for problem in problems}


class PrivacyCheckTests(unittest.TestCase):
    def run_check(self, files):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative, text in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            return check(root)

    def problems(self, files):
        return self.run_check(files)[1]

    def swift(self, code):
        return self.problems({'Sources/HelmCore/Fixture.swift': code + '\n'})

    def test_ordinary_code_passes(self):
        self.assertEqual(self.swift('import Foundation\nimport AppKit\nfunc connect(to url: URL) {}\n'
                                    'enum E { case connect(URL) }\n'
                                    'func f() { send(.x); accept(row, state: &s); x.connect(to: u) }\n'
                                    'let schemes = ["smb", "afp", "ftp"]; let placeholder = "smb://"\n'
                                    '@_silgen_name("getxattr") func g() -> Int\n'
                                    'items.append(contentsOf: more); let home = environment["HOME"]\n'
                                    'for try await line in handle.bytes.lines { print(line) }'), [])
        self.assertEqual(self.problems({'App/Info.plist': DTD, 'App/Helm.entitlements': DTD + '<dict/>\n',
                                        'App/project.yml': 'packages:\n  HelmPackage:\n    path: ..\n',
                                        'Package.swift': 'let package = Package(name: "Helm", targets: targets)\n'}), [])

    def test_planted_code_fails(self):
        for name, (code, expected) in PLANTS.items():
            self.assertEqual(rules(self.swift(code)), expected, name)

    def test_network_fails(self):
        for code in ['URLSession.shared', 'let r = URLRequest(url: u)', 'import Network', '@preconcurrency import WebKit',
                     'internal import Network', '@_implementationOnly public import CFNetwork',
                     'import FoundationNetworking', 'import struct Network.NWConnection',
                     'NWPathMonitor()', 'Darwin.connect(fd, p, n)', 'getaddrinfo(h, nil, &hints, &res)',
                     'NetService(domain: "")', 'let u = "wss://x.invalid"', 'Data(contentsOf: u)',
                     'XMLDocument(contentsOf: u)', 'import Foundation; import Network', 'import LinkPresentation',
                     'LPMetadataProvider().startFetchingMetadata(for: u) { _, _ in }', 'AsyncImage(url: u)',
                     'for try await byte in u.resourceBytes {}', 'let d = try Data.init(contentsOf: u)',
                     'let s: String = try .init(contentsOf: u)', 'NSImage(byReferencing: u)',
                     'NSAttributedString(html: d, documentAttributes: nil)']:
            self.assertTrue(self.swift(code), code)

    def test_telemetry_identifiers_logging_and_hand_offs_fail(self):
        for code in ['import Sentry', 'SPUStandardUpdaterController(startingUpdater: true)', 'os_log("x")',
                     'Logger(subsystem: s)', 'import OSLog', '@preconcurrency import os.log', 'NSFullUserName()',
                     'ProcessInfo.processInfo.hostName', 'kIOPlatformUUIDKey', 'CSCopyMachineName()',
                     'NSUserActivity(activityType: t)', 'CSSearchableIndex.default()', 'NSUbiquitousKeyValueStore.default',
                     'NSAppleScript(source: s)', 'NSDocumentController.shared.noteNewRecentDocumentURL(u)',
                     'NSLogv(f, args)', 'vsyslog(LOG_ERR, f, args)', 'getpwuid_r(uid, &pw, buffer, size, &out)',
                     'ProcessInfo.processInfo.environment["USER"]', 'getenv("LOGNAME")',
                     'try FileManager.default.setUbiquitous(true, itemAt: a, destinationURL: b)',
                     'query[kSecAttrSynchronizable] = kCFBooleanTrue']:
            self.assertTrue(self.swift(code), code)

    def test_tools_and_dynamic_lookups_fail(self):
        for code in ['dlsym(h, "connect")', 'dlopen(path, RTLD_LAZY)', 'p.arguments = ["-c", "osascript -e x"]',
                     'p.executableURL = URL(fileURLWithPath: "/usr/bin/env")',
                     'p.executableURL = URL(fileURLWithPath: "/bin/sh")']:
            self.assertTrue(self.swift(code), code)
        self.assertEqual(self.swift('p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")'), [])

    def test_allowed_line_is_one_line_in_one_file(self):
        allowed = '        do { data = try Data(contentsOf: url) }\n'
        own = 'Sources/HelmPersistence/Tags/PreferenceDocumentFile.swift'
        self.assertEqual(self.problems({own: allowed}), [])
        self.assertTrue(self.problems({'Sources/HelmCore/Other.swift': allowed}))
        self.assertTrue(self.problems({own: '        do { data = try Data(contentsOf: remote) }\n'}))
        self.assertTrue(self.problems({own: allowed + 'URLSession.shared\n'}))

    def test_allowed_line_is_found_by_its_own_line_number(self):
        # A form feed is a line break to splitlines(), but not to the line numbers.
        own = 'Sources/HelmPersistence/Tags/PreferenceDocumentFile.swift'
        text = '// a\x0cb\n        do { data = try Data(contentsOf: url) }\nlet remote = try Data(contentsOf: web)\n'
        problems = self.problems({own: text})
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(':3:', problems[0])

    def test_allowed_lines_that_are_gone_are_listed(self):
        allowed = len(ALLOW)
        unused = self.run_check({'Sources/HelmCore/Fixture.swift': 'import Foundation\n'})[2]
        self.assertEqual(len(unused), allowed)
        unused = self.run_check({'Sources/HelmUI/Onboarding/AppMover.swift':
                                 'waiter.executableURL = URL(fileURLWithPath: "/bin/sh")\n'})[2]
        self.assertEqual(len(unused), allowed - 1)

    def test_app_target_and_manifest(self):
        for files in [{'App/Helm.entitlements': DTD + '<key>com.apple.security.network.client</key>\n'},
                      {'App/Info.plist': DTD + '<key>SUFeedURL</key>\n'},
                      {'App/Info.plist': DTD + '<key>CFBundleURLTypes</key>\n'},
                      {'App/Info.plist': DTD + '<string>http://example.invalid</string>\n'},
                      {'Package.swift': 'dependencies: [.package(url: "https://x.invalid/a", from: "1.0.0")]\n'},
                      {'Package.swift': 'dependencies: [.package(path: "../Other")]\n'},
                      {'Package.swift': 'targets: [.binaryTarget(name: "SDK", path: "SDK.xcframework")]\n'},
                      {'App/project.yml': 'packages:\n  Remote:\n    url: github.com/x/a\n'}]:
            self.assertTrue(self.problems(files), files)

    def test_main_fails_with_nothing_to_read(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([folder]), 1)
            # Package.swift and App/main.swift are Swift files, but not the sources this check is for.
            Path(folder, 'App').mkdir()
            Path(folder, 'App/main.swift').write_text('import Foundation\n')
            Path(folder, 'Package.swift').write_text('let package = Package(name: "Helm")\n')
            self.assertEqual(main([folder]), 1)
            Path(folder, 'Sources/HelmCore').mkdir(parents=True)
            Path(folder, 'Sources/HelmCore/Fixture.swift').write_text('import Foundation\n')
            self.assertEqual(main([folder]), 0)
        self.assertIn('no Swift files', out.getvalue())


if __name__ == '__main__':
    unittest.main()
