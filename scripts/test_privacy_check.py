import contextlib
import io
import re
import tempfile
import unittest
from pathlib import Path
from privacy_check import (AGENT_UI, ALLOW, ATS_SHAPE, CONTENT_FILES, CONTENT_READER, DECLARED, GUARDED, LISTENER_FILES,
                           MAY_BE_ABSENT, NETWORK_FILES, ONE_FILE, check, file_problems, layers, main)

DTD = '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'

# Real, compiling ways to reach the network or read identifiers. Each must fail with these rules.
PLANTS = {
    'fetch with no web address written out': ('''import Foundation
func plantedFetch(_ address: URL) async throws -> Data {
    let (data, _) = try await URLSession.shared.data(from: address)
    return data
}''', {'url-session', 'session-shape'}),
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
}''', {'url-other', 'sockets', 'socket-call', 'identifier', 'dynamic-lookup', 'web-address', 'network-tool',
       'tool-path'}),
}

TRANSPORT = 'Sources/HelmAgent/Transport/HTTPTransport.swift'
ENDPOINTS = 'Sources/HelmAgent/Transport/Endpoints.swift'
KEYCHAIN = 'Sources/HelmAgent/Secrets/KeychainSecretStore.swift'
SECRETS = 'Sources/HelmAgent/Contracts/AgentSecrets.swift'
LIVE_PARTS = 'Sources/HelmAgent/Runtime/AgentLiveParts.swift'
PLAN_CARD = 'Sources/HelmUI/Agent/AgentPlanCard.swift'
PANEL_MODEL = 'Sources/HelmUI/Agent/AgentPanelModel.swift'
WINDOW_AGENT = 'Sources/HelmUI/Window/BrowserWindowController+Agent.swift'
# Files with no leave of their own: one in HelmAgent, one of the AI panel's, a header file and one in HelmCore.
LOOP = 'Sources/HelmAgent/Loop/AgentSession.swift'
RUNNER = 'Sources/HelmAgent/Tools/AgentToolRunner.swift'
SEARCH_WINDOW = 'Sources/HelmUI/Window/BrowserWindowController+AISearch.swift'
CONTENTS = 'Sources/HelmCore/Contracts/AgentContents.swift'
EXTRACTOR = 'Sources/HelmUI/Contents/AgentContentExtractor.swift'
THREAD = 'Sources/HelmUI/Agent/AgentThreadViews.swift'
HEADER = 'Sources/HelmUI/Chrome/HeaderBarView.swift'
CORE = 'Sources/HelmCore/Fixture.swift'

# The transport as it is meant to be written: one session that keeps nothing, an address put together from the
# endpoint, every redirect refused, the server's trust left to macOS and every other challenge cancelled.
TRANSPORT_CODE = '''import Foundation
import HelmCore

public final class HTTPTransport: AgentTransport, @unchecked Sendable {
    private let profile: AgentProviderProfile
    private let secrets: any AgentSecretStoring
    private let session: URLSession
    private let guardian = AgentTransportGuardian()

    public convenience init(liveProfile profile: AgentProviderProfile, secrets: any AgentSecretStoring,
                            limits: AgentTransportLimits) {
        self.init(profile, secrets, limits, loaders: [])
    }

    convenience init(liveProfile profile: AgentProviderProfile, secrets: any AgentSecretStoring,
                     limits: AgentTransportLimits, testProtocols: [AnyClass]) {
        self.init(profile, secrets, limits, loaders: testProtocols)
    }

    private init(_ profile: AgentProviderProfile, _ secrets: any AgentSecretStoring, _ limits: AgentTransportLimits,
                 loaders: [AnyClass]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = limits.idleSeconds
        configuration.timeoutIntervalForResource = limits.totalSeconds
        if profile.endpoint.isLoopback { configuration.connectionProxyDictionary = [:] }
        if !loaders.isEmpty { configuration.protocolClasses = loaders }
        self.profile = profile
        self.secrets = secrets
        session = URLSession(configuration: configuration, delegate: guardian, delegateQueue: nil)
    }

    public func stream(_ route: AgentRoute, body: Data) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: try request(route, body: body))
                    guard let reply = response as? HTTPURLResponse, reply.url?.host == profile.endpoint.host else {
                        throw AgentTransportError.wrongHost
                    }
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    public func fetch(_ route: AgentRoute) async throws -> AgentHTTPReply {
        let (data, response) = try await session.data(for: try request(route, body: nil))
        guard let reply = response as? HTTPURLResponse else { throw AgentTransportError.unreachable }
        return AgentHTTPReply(status: reply.statusCode, body: data)
    }

    public func shutdown() async { session.invalidateAndCancel() }

    private func request(_ route: AgentRoute, body: Data?) throws -> URLRequest {
        guard let spec = AgentProviderCatalog.route(route, for: profile) else { throw AgentTransportError.unreachable }
        var parts = URLComponents()
        parts.scheme = profile.endpoint.isSecure ? "https" : "http"
        parts.host = profile.endpoint.host
        parts.port = profile.endpoint.port
        parts.path = profile.endpoint.basePath + spec.path
        guard let url = parts.url else { throw AgentTransportError.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        request.httpBody = body
        request.setValue("Helm", forHTTPHeaderField: "User-Agent")
        if let secret = try secrets.secret(for: profile.secretID) {
            request.setValue(secret.revealSecret(), forHTTPHeaderField: "x-api-key")
        }
        return request
    }
}

private final class AgentTransportGuardian: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let trust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        completionHandler(trust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
'''

ENDPOINT_CODE = '''import Foundation
import HelmCore

public enum AgentProviderCatalog {
    static let claudeBase = "https://api.anthropic.com"
    static let openAIBase = "https://api.openai.com/v1"
    static let geminiBase = "https://generativelanguage.googleapis.com/v1beta"
    static let grokBase = "https://api.x.ai/v1"
    static let loopbackHost = "127.0.0.1"
    public static func defaultPort(_ id: AgentProviderID) -> Int? { id == .ollama ? 11434 : id == .lmStudio ? 1234 : nil }
}
'''

# The one file with the keychain calls.
# The loopback listener as it is meant to be written: an IPv4 stream socket bound to 127.0.0.1, one request read and
# one answer sent on each connection it accepts.
LISTENER = 'Sources/HelmAgent/Transport/AgentLoopbackListener.swift'
LISTENER_CODE = '''import Foundation

public final class AgentLoopbackListener {
    public func start() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { close(descriptor); return 0 }
        let client = accept(descriptor, nil, nil)
        var buffer = [UInt8](repeating: 0, count: 1024)
        _ = recv(client, &buffer, buffer.count, 0)
        _ = send(client, buffer, 0, 0)
        close(client)
        return 0
    }
}
'''
HELP_LINKS = 'Sources/HelmAgent/Text/AgentHelpLinks.swift'
HELP_CODE = '''import Foundation

public enum AgentHelpLinks {
    static let chatGPTPlan = "https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites"
    static let chatGPTUsage = "https://chatgpt.com/settings/usage"
    static let openAIKey = "https://developers.openai.com/api/docs/quickstart"
    static let claudeKey = "https://platform.claude.com/docs/en/manage-claude/authentication#api-keys"
    static let geminiKey = "https://aistudio.google.com/docs/api-key"
    static let grokKey = "https://docs.x.ai/docs/quickstart"
    static let ollamaStart = "https://docs.ollama.com/quickstart"
    static let lmStudioServer = "https://lmstudio.ai/docs/developer/core/server"
}
'''

KEYCHAIN_CODE = '''import Foundation
import Security
import HelmCore

public struct KeychainSecretStore: AgentSecretStoring {
    public func secret(for id: AgentSecretID) throws -> AgentSecret? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
                                      kSecAttrAccount: id.account, kSecReturnData: true]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data else { return nil }
        return AgentSecret(pasted: String(decoding: data, as: UTF8.self))
    }
    public func save(_ secret: AgentSecret, for id: AgentSecretID) throws {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: id.account] as CFDictionary)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecValueData: Data(secret.revealSecret().utf8)] as CFDictionary, nil)
    }
}
'''

# What Sources/HelmAgent is made of, by the names its own types and methods have. All of it passes.
AGENT_CODE = '''import Foundation
import Security
import HelmCore
import struct Foundation.Data

enum E { case rename(X, to: Y) }
public enum AgentPlanStep: Hashable, Sendable {
    case newFolder(key: String, parent: AgentPlanTarget, name: ValidFileName)
    case move(AgentPlanItem, to: AgentPlanTarget)
    case copy(AgentPlanItem, to: AgentPlanTarget)
    case rename(AgentPlanItem, to: ValidFileName)
    case trash(AgentPlanItem)
}
public enum AgentPlanTitle: Hashable, Sendable {
    case organize(rootLabel: String), move(Int), copy(Int), rename(Int), trash(Int)
}
public enum AgentToolCode: String, Sendable { case unknown_tool, link, not_found, read_only, no_trash, name_taken }
func words(_ step: AgentPlanStep, _ title: AgentPlanTitle) -> String {
    switch step {
    case .rename(let item, let name): return item.name + name.rawValue
    case let .move(item, to: target): return "\\(item.name) \\(target)"
    default: return AgentToolCode.link.rawValue
    }
}
let step = AgentPlanStep.rename(item, to: name)
let title: AgentPlanTitle = .rename(3)
steps.append(.rename(item, to: name))
steps.append(rename(item, to: name))
public struct AgentTurnInput: Sendable {
    public var system: String
    public init(system: String, tools: [AgentToolSpec], history: [AgentJSON]) { self.system = system }
}
let ask = AgentStructuredAsk(system: AgentPrompt.system, user: text, schemaName: "plan", schema: schema)
public struct AgentRootInput: Sendable { public init(fromPerson text: String, origin: Origin) {} }
public struct AgentPersonInput: Sendable { public init(typedByPerson text: String, selectedPaths: [String]) {} }
public protocol AgentTransport: Sendable {
    func stream(_ route: AgentRoute, body: Data) -> AsyncThrowingStream<String, Error>
    func fetch(_ route: AgentRoute) async throws -> AgentHTTPReply
    func shutdown() async
}
public final class MemoryAgentDisk: AgentDisk, @unchecked Sendable {
    public func addLink(_ path: String, to target: String) {}
    public func remove(_ path: String) {}
}
disk.addLink("/home/helm/a", to: "/home/helm/b"); disk.remove("/home/helm/a"); self.remove(path)
await scope.remove(alias: "r2"); try secrets.remove(id); try secrets.save(secret, for: id)
let listing = await disk.list(folder, limit: 500, idleSeconds: 3); let item = await disk.item(at: path)
let canonical = await disk.canonicalPath(path); let facts = await disk.storage(of: folder)
func read(_ line: String) -> [AgentModelEvent] { reader.read(line) }
func open(_ thread: Int) {}; session.open(3); self.link(first, second); table.stat(handle)
let reopened = reopen(thread); let spread = spread(4); let thread = thread(3); let executed = execute(plan)
let moveItems = proposal.moves.flatMap(\\.items); let copyItems = proposal.copies.flatMap(\\.items)
let seconds = AgentLimits.diskSeconds; let section = Section.one; let secrets: any AgentSecretStoring = MemorySecretStore()
let environment = ProcessInfo.processInfo.environment["HOME"]
public enum AgentScopeRefusal: String, Error, Sendable { case notFound, notAFolder, system, hidden, insidePackage }
let input = AgentTurnInput(system: system, tools: tools, history: history); let prompt = AgentPrompt.system
private var streamTask: Task<Void, Never>?; let downloadTask = Task { await next() }
streamTask = Task { await run() }; self.streamTask?.cancel(); if let task = streamTask { task.cancel() }
try secrets.remove(id); scope.remove(alias: alias); items.remove(at: 0); let none = remove()
for try await line in stream.bytes.lines { reader.read(line) }; let count = report.lines.count
func evaluate(trust: Level) {}; evaluate(trust: .high)
// The model may read (and name back) what a folder holds. A link (never followed) is listed as a link, and the
// system (macOS) decides what a folder may show. Nothing is open (or kept open) between requests.
/// Process the lines one at a time. Rename (one item, one name) keeps a file's extension.
let note = "Names only: nothing is read (or sent) from inside a file. To rename (a file, a folder), ask."
let schema = "{\\"kind\\": \\"link\\", \\"system\\": \\"macOS\\"}"
'''

# What the AI panel is made of. All of it passes.
PANEL_CODE = '''#if os(macOS)
import AppKit
import SwiftUI
import HelmCore
import HelmAgent

struct AgentReplyView: View {
    let reply: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: reply)
            Text(AgentText.consent(destination))
            Button(AgentText.apply) { model.press(AgentText.apply) }
        }
        .padding(.init(top: 4, leading: 8, bottom: 4, trailing: 8))
    }
}
textView.isAutomaticLinkDetectionEnabled = false
textView.isAutomaticDataDetectionEnabled = false
chips.append(.init(label: root.label, kind: root.storage.kind)); ids.insert(.init()); let unlinked = true
let leftOut = plan.leftOut[.link] ?? 0
#endif
'''


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

    def planted(self, relative, code):
        """The problems with `code` as the file `relative`, read from memory: what holds for one file by itself."""
        return file_problems(relative, code + '\n')

    def expect(self, rule, code, fails=(), passes=()):
        """`code` fails `rule` as each file in `fails`, and doesn't as each file in `passes`."""
        for relative in fails:
            self.assertIn(rule, rules(self.planted(relative, code)), f'{relative}: {code}')
        for relative in passes:
            self.assertNotIn(rule, rules(self.planted(relative, code)), f'{relative}: {code}')

    def fails(self, rule, relative, code):
        self.expect(rule, code, fails=[relative])

    def passes(self, rule, relative, code):
        self.expect(rule, code, passes=[relative])

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
        # What Helm does today, in the places it does it. None of it is AI mode's module or the AI panel.
        self.assertEqual(self.planted(HEADER, 'NSWorkspace.shared.open(url); NotificationCenter.default.post(note)\n'
                                      'let app = NSApplication.shared; let cell = table.makeView(withIdentifier: id, owner: nil)\n'
                                      'Text("Open"); Link("Help", destination: page); let ids = raw.map(TabID.init)\n'
                                      'var code: SecCode?; SecCodeCopySelf([], &code); let kind = TabID.self\n'
                                      'let task = Process(); try FileManager.default.removeItem(at: url)\n'
                                      'try data.write(to: url); let values = try url.resourceValues(forKeys: keys)\n'
                                      'open(path, O_RDONLY); rename(old, new); stat(path, &info); unlink(path)\n'
                                      'let home = "/home/helm"; let parts = ["Users", "Shared"]\n'
                                      '/// `file:///Users/me/My%20Files` becomes `/Users/me/My Files`.'), [])

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
                     'NSAttributedString(html: d, documentAttributes: nil)', 'Data(contentsOf/* */: u)',
                     'let d = try Data(contentsOf /** u */ : u)']:
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

    def test_each_framework_and_hand_off_fails_by_name(self):
        for name in ['Network', 'NetworkExtension', 'FoundationNetworking', 'CFNetwork', 'WebKit', 'SafariServices',
                     'LinkPresentation', 'MultipeerConnectivity', 'CloudKit', 'CoreSpotlight', 'Intents', 'IntentsUI',
                     'AuthenticationServices', 'StoreKit', 'GameKit', 'MapKit', 'CoreLocation', 'AdSupport', 'AdServices',
                     'AppTrackingTransparency', 'iAd', 'MetricKit', 'SystemConfiguration', 'CoreWLAN', 'CoreBluetooth',
                     'IOBluetooth', 'ExternalAccessory', 'IOKit', 'OSAKit', 'ScriptingBridge', 'FileProvider', 'NetFS',
                     'DiskArbitration']:
            self.expect('import', f'import {name}', fails=(CORE, HEADER))
            self.expect('import', f'import\n{name}', fails=(CORE, HEADER))
            self.expect('import', f'import /* x */ {name}', fails=(CORE, HEADER))
            self.expect('import', f'import {name}Extras\n// import {name}', passes=(CORE, HEADER))
        # However the import is written. Sources/HelmAgent may import three modules and no others.
        written = (['import %s', '@preconcurrency import %s', '@_exported @testable import %s', 'import Foundation; import %s',
                    '    import %s', 'import\t%s', 'import\n%s', 'import /* x */ %s', 'import // x\n    %s',
                    '@preconcurrency\nimport %s', 'public /* x */ import %s']
                   + [access + ' import %s' for access in ('public', 'package', 'internal', 'fileprivate', 'private')]
                   + ['import ' + kind + ' %s.Thing'
                      for kind in ('struct', 'class', 'enum', 'func', 'var', 'let', 'typealias', 'protocol')])
        for form in written:
            self.expect('import', form % 'GameKit', fails=(CORE, HEADER, LOOP))
            for name in ('AppKit', 'Combine', 'Dispatch', 'HelmFileSystem', 'HelmUI', 'HelmCoreMore', 'FoundationXML'):
                self.expect('agent-no-write', form % name, fails=(LOOP, TRANSPORT, KEYCHAIN), passes=[HEADER])
            for name in ('Foundation', 'Security', 'HelmCore'):
                self.assertEqual(self.planted(LOOP, form % name), [], form)
        for code in ['NSUserActivity(activityType: kind)', 'CSSearchableIndex.default()',
                     'INInteraction(intent: intent, response: nil)', 'INVoiceShortcutCenter.shared',
                     'NSUbiquitousKeyValueStore.default', 'CKContainer.default()',
                     'CKDatabase.Scope.private', 'CKRecord(recordType: kind)', 'CKQuery(recordType: kind, predicate: all)',
                     'CKShare(rootRecord: record)', 'manager.url(forUbiquityContainerIdentifier: nil)',
                     'manager.ubiquityIdentityToken', 'try manager.startDownloadingUbiquitousItem(at: url)',
                     'try manager.evictUbiquitousItem(at: url)', 'try manager.setUbiquitous(true, itemAt: a, destinationURL: b)',
                     'query[kSecAttrSynchronizable] = true', 'NSFileProviderManager.default', 'NetFSMountURLSync(url, nil)',
                     'NSDocumentController.shared', 'controller.noteNewRecentDocumentURL(url)',
                     'LSSharedFileListCreate(nil, kind, nil)', 'NSAppleScript(source: text)', 'OSAScript(source: text)',
                     'AESendMessage(&event, &reply, mode, time)',
                     'NSDistributedNotificationCenter.default()', 'DistributedNotificationCenter.default()',
                     'CFNotificationCenterGetDistributedCenter()', 'NSXPCConnection(serviceName: name)',
                     'SMJobBless(domain, label, authorization, &error)']:
            self.expect('hand-off', code, fails=(CORE, HEADER))

    def test_cloud_and_server_hand_offs_fail(self):
        for code in ['try FileManager.default.evictUbiquitousItem(at: url)', 'let evict = manager.evictUbiquitousItem',
                     'NSFileProviderManager(for: domain)', 'let manager: NSFileProviderManager? = .init(for: domain)',
                     'NetFSMountURLSync(url, nil, nil, nil, nil, nil, &mounts)', 'NetFSMountURLAsync(url, nil)',
                     '// NetFSMountURLSync mounts it', 'let name = "NSFileProviderManager"',
                     'try FileManager.default.startDownloadingUbiquitousItem(at: url)']:
            self.expect('hand-off', code, fails=(CORE, HEADER, 'Sources/HelmFileSystem/Providers/CloudAvailability.swift', LOOP))
        for code in ['import FileProvider', 'import NetFS', 'import DiskArbitration', '@preconcurrency import NetFS',
                     'import Foundation; import DiskArbitration', 'import class FileProvider.NSFileProviderManager']:
            self.expect('import', code, fails=(CORE, HEADER, 'Sources/HelmApp/macOS/AppController.swift'))

    def test_tools_and_dynamic_lookups_fail(self):
        for code in ['dlsym(h, "connect")', 'dlopen(path, RTLD_LAZY)', 'p.arguments = ["-c", "osascript -e x"]',
                     'p.executableURL = URL(fileURLWithPath: "/usr/bin/env")',
                     'p.executableURL = URL(fileURLWithPath: "/bin/sh")']:
            self.assertTrue(self.swift(code), code)
        self.assertEqual(self.swift('p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")'), [])

    def test_lookups_by_a_name_built_at_run_time_fail_everywhere(self):
        for code in ['guard let type = Bundle.main.classNamed(name) as? NSObject.Type else { return }',
                     'let found = bundle.classNamed (["NSURL", "Session"].joined())',
                     '_ = type.perform(Selector(["shared", "Session"].joined()))', 'let pick = Selector("sharedSession")',
                     'object.perform(Selector(("removeItemAtPath:error:")), with: path)', '_ = type.perform( Selector(name))']:
            self.expect('dynamic-lookup', code, fails=(HEADER, CORE, 'Sources/HelmApp/macOS/AppController.swift', LOOP,
                                                       TRANSPORT))
        for code in ['button.action = #selector(open)', 'item.action = #selector(NSResponder.cancelOperation(_:))',
                     'let names = bundle.classNames', 'view.performClick(nil)', 'try await model.perform(step)']:
            self.expect('dynamic-lookup', code, passes=(HEADER, CORE, 'Sources/HelmApp/macOS/AppController.swift'))

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
        # The Info.plist key may be absent, so it is never listed.
        allowed = len(ALLOW) - len(MAY_BE_ABSENT)
        unused = self.run_check({'Sources/HelmCore/Fixture.swift': 'import Foundation\n'})[2]
        self.assertEqual(len(unused), allowed)
        self.assertFalse(set(unused) & MAY_BE_ABSENT)
        unused = self.run_check({'Sources/HelmUI/Onboarding/AppMover.swift':
                                 'waiter.executableURL = URL(fileURLWithPath: "/bin/sh")\n'})[2]
        self.assertEqual(len(unused), allowed - 1)
        unused = self.run_check({ENDPOINTS: ENDPOINT_CODE, TRANSPORT: TRANSPORT_CODE})[2]
        self.assertEqual(len(unused), allowed - 4)

    def test_allow_list_is_pinned(self):
        # A new exemption is a change to this list too, so it can't arrive unseen.
        endpoints = 'Sources/HelmAgent/Transport/Endpoints.swift'
        mover = 'Sources/HelmUI/Onboarding/AppMover.swift'
        self.assertEqual(ALLOW, [
            ('read-url', 'Sources/HelmPersistence/JSONFileStore.swift',
             'init(url: URL, read: @escaping @Sendable (URL) async throws -> Data = { try Data(contentsOf: $0) }) {'),
            ('read-url', 'Sources/HelmPersistence/Tags/PreferenceDocumentFile.swift',
             'do { data = try Data(contentsOf: url) }'),
            ('read-url', 'Sources/HelmApp/macOS/HostSmokeDriver.swift',
             'guard let text = try? String(contentsOf: script, encoding: .utf8) else '
             '{ finish(code: 2, "cannot read script"); return }'),
            ('dynamic-lookup', mover,
             'guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else '
             '{ return false }'),
            ('dynamic-lookup', mover,
             'guard let symbol = dlsym(security, "SecTranslocateIsTranslocatedURL") else { return false }'),
            ('read-url', mover, 'guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),'),
            ('tool-path', mover, 'waiter.executableURL = URL(fileURLWithPath: "/bin/sh")'),
            ('web-address', endpoints, 'static let claudeBase = "https://api.anthropic.com"'),
            ('web-address', endpoints, 'static let openAIBase = "https://api.openai.com/v1"'),
            ('web-address', endpoints, 'static let geminiBase = "https://generativelanguage.googleapis.com/v1beta"'),
            ('web-address', endpoints, 'static let grokBase = "https://api.x.ai/v1"'),
            ('web-address', endpoints, 'static let openAISignInBase = "https://auth.openai.com"'),
            ('web-address', HELP_LINKS, 'static let chatGPTPlan = "https://help.openai.com/en/articles/20001542-using-your-'
                                        'chatgpt-plan-in-other-apps-and-sites"'),
            ('web-address', HELP_LINKS, 'static let chatGPTUsage = "https://chatgpt.com/settings/usage"'),
            ('web-address', HELP_LINKS, 'static let openAIKey = "https://developers.openai.com/api/docs/quickstart"'),
            ('web-address', HELP_LINKS,
             'static let claudeKey = "https://platform.claude.com/docs/en/manage-claude/authentication#api-keys"'),
            ('web-address', HELP_LINKS, 'static let geminiKey = "https://aistudio.google.com/docs/api-key"'),
            ('web-address', HELP_LINKS, 'static let grokKey = "https://docs.x.ai/docs/quickstart"'),
            ('web-address', HELP_LINKS, 'static let ollamaStart = "https://docs.ollama.com/quickstart"'),
            ('web-address', HELP_LINKS, 'static let lmStudioServer = "https://lmstudio.ai/docs/developer/core/server"'),
            ('session-shape', 'Sources/HelmUI/Host/AgentNewFileContents.swift',
             'return try? string.data(from: whole, documentAttributes: '
             '[.documentType: NSAttributedString.DocumentType.officeOpenXML])'),
            ('identifier', 'Sources/HelmUI/Properties/PropertiesReader.swift',
             'guard let entry = getpwuid(id), let name = entry.pointee.pw_name else { return nil }'),
            ('network-key', 'App/Info.plist', '<key>NSAppTransportSecurity</key>'),
        ])
        self.assertEqual(NETWORK_FILES, {'Sources/HelmAgent/Transport/HTTPTransport.swift'})
        self.assertEqual(LISTENER_FILES, {'Sources/HelmAgent/Transport/AgentLoopbackListener.swift'})
        self.assertEqual(MAY_BE_ABSENT, {('network-key', 'App/Info.plist', '<key>NSAppTransportSecurity</key>')})
        self.assertEqual(ATS_SHAPE, {'NSAllowsLocalNetworking': True})
        self.assertIs(ATS_SHAPE['NSAllowsLocalNetworking'], True)

    def test_one_file_homes_are_pinned(self):
        agent, panel = 'Sources/HelmAgent/', 'Sources/HelmUI/Agent/'
        keychain = agent + 'Secrets/KeychainSecretStore.swift'
        transport = agent + 'Transport/HTTPTransport.swift'
        self.assertEqual([(homes, folder) for _, homes, folder in ONE_FILE], [
            ({keychain}, None),
            ({keychain}, agent),
            ({agent + 'Contracts/AgentSecrets.swift', keychain, transport}, None),
            ({transport}, None),
            ({agent + 'Runtime/AgentLiveParts.swift', 'Sources/HelmApp/macOS/AppController+Agent.swift'}, None),
            ({panel + 'AgentPlanCard.swift'}, None),
            ({panel + 'AgentPanelModel.swift'}, None),
            ({panel + 'AgentPanelModel.swift', 'Sources/HelmUI/Window/BrowserWindowController+Agent.swift'}, None),
            ({agent + 'Runtime/AgentLiveParts.swift'}, None),
            ({panel + 'AgentPanelModel.swift', 'Sources/HelmUI/Window/BrowserWindowController+AISearch.swift'}, None),
        ])
        self.assertEqual(GUARDED, [
            ('tickedByPerson', 'AgentApprovedPlan', {panel + 'AgentPlanCard.swift'}),
            ('typedByPerson', 'AgentPersonInput', {panel + 'AgentPanelModel.swift'}),
            ('fromPerson', 'AgentRootInput', {panel + 'AgentPanelModel.swift',
                                              'Sources/HelmUI/Window/BrowserWindowController+Agent.swift'}),
            ('liveProfile', 'HTTPTransport', {agent + 'Runtime/AgentLiveParts.swift'}),
            ('switchedOnByPerson', 'AgentContentPermit', {panel + 'AgentPanelModel.swift',
                                                          'Sources/HelmUI/Window/BrowserWindowController+AISearch.swift'}),
        ])
        self.assertEqual(CONTENT_FILES, {'Sources/HelmUI/Contents/AgentContentExtractor.swift'})
        self.assertEqual(CONTENT_READER, 'Sources/HelmUI/Contents/AgentContentReader.swift')
        self.assertEqual(AGENT_UI, (panel, 'Sources/HelmUI/Host/AISearchRunner.swift',
                                    'Sources/HelmUI/Host/AISearchPredicates.swift',
                                    'Sources/HelmUI/Window/BrowserWindowController+AISearch.swift'))

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

    def test_a_tree_with_ai_mode_in_it_passes(self):
        files = {
            TRANSPORT: TRANSPORT_CODE, KEYCHAIN: KEYCHAIN_CODE, LOOP: AGENT_CODE, THREAD: PANEL_CODE,
            ENDPOINTS: ENDPOINT_CODE + 'static let openAISignInBase = "https://auth.openai.com"\n',
            LISTENER: LISTENER_CODE, HELP_LINKS: HELP_CODE,
            SECRETS: 'public struct AgentSecret: Sendable { public func revealSecret() -> String { text } }\n',
            LIVE_PARTS: 'let transport = HTTPTransport(liveProfile: profile, secrets: secrets, limits: .cloud)\n',
            PLAN_CARD: 'struct AgentApprovedPlan { fileprivate init(tickedByPerson ticked: Set<Int>, planID: UUID) {} }\n'
                       'let approved = AgentApprovedPlan(tickedByPerson: ticked, planID: plan.id)\n',
            PANEL_MODEL: 'let input = AgentPersonInput(typedByPerson: text, selectedPaths: paths)\n'
                         'let folder = AgentRootInput(fromPerson: text, origin: .typed)\n',
            WINDOW_AGENT: 'let folder = AgentRootInput(fromPerson: path, origin: .tab)\n',
            'App/Info.plist': '<?xml version="1.0" encoding="UTF-8"?>\n' + DTD + '<plist version="1.0">\n<dict>\n'
                              '\t<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n'
                              '\t\t<true/>\n\t</dict>\n</dict>\n</plist>\n',
        }
        scanned, problems, unused = self.run_check(files)
        self.assertEqual(len(scanned), len(files))
        self.assertEqual(problems, [])
        self.assertFalse([entry for entry in unused if entry[0] in ('web-address', 'network-key')])
        # Each of these files has leave for one thing, and only where it is.
        for place in (TRANSPORT, ENDPOINTS, KEYCHAIN, SECRETS, LIVE_PARTS, PLAN_CARD, PANEL_MODEL, WINDOW_AGENT, LISTENER,
                      HELP_LINKS):
            self.assertTrue(self.planted(CORE, files[place]), place)
            self.assertTrue(self.planted(place.replace('.swift', '+More.swift'), files[place]), place)

    # The transport file and the addresses.

    def test_transport_file_passes_and_its_lines_fail_anywhere_else(self):
        self.assertEqual(self.planted(TRANSPORT, TRANSPORT_CODE), [])
        self.expect('url-session', TRANSPORT_CODE, fails=(
            LOOP, 'Sources/HelmAgent/Transport/SSELineReader.swift', 'Sources/HelmAgent/Providers/LiveModelClient.swift',
            THREAD, HEADER, CORE, 'Sources/HelmApp/macOS/AppController+Agent.swift', 'App/main.swift'))
        # One name is enough, by whatever road it is reached.
        for code in ['let session: URLSession? = nil', 'typealias Session = URLSession',
                     'let configuration = URLSessionConfiguration.ephemeral', 'var request = URLRequest(url: url)',
                     'let request: URLRequest = .init(url: url)', 'guard let reply = response as? HTTPURLResponse else { return }',
                     'func read(_ bytes: URLSession.AsyncBytes) {}', 'let bytes: AsyncBytes', 'extension URLSessionTask {}',
                     '// URLSession would do it', 'let name = "URLSessionConfiguration"']:
            self.expect('url-session', code, fails=(LOOP, THREAD, CORE), passes=[TRANSPORT])

    def test_transport_file_still_fails_for_everything_else(self):
        for rule, code in [
                ('socket-call', 'let fd = socket(AF_INET, SOCK_STREAM, 0)'), ('sockets', 'var address = sockaddr_in()'),
                ('import', 'import Network'), ('network-framework', 'let monitor = NWPathMonitor()'),
                ('read-url', 'let page = try Data(contentsOf: url)'), ('read-url', 'let page = try String(contentsOf: url)'),
                ('session-shape', 'let session = URLSession.shared'),
                ('session-shape', 'let session: URLSession = .shared'),
                ('session-shape', 'typealias Session = URLSession; let session = Session.shared'),
                ('session-shape', 'let session = URLSession(configuration: .default)'),
                ('session-shape', 'let configuration = URLSessionConfiguration.default'),
                ('session-shape', 'let configuration: URLSessionConfiguration = .default'),
                ('session-shape', 'let configuration = URLSessionConfiguration.background(withIdentifier: "helm")'),
                ('session-shape', 'let configuration: URLSessionConfiguration = .background(withIdentifier: "helm")'),
                ('session-shape', 'completionHandler(.useCredential, URLCredential(trust: trust))'),
                ('session-shape', 'completionHandler(.useCredential, .init(trust: trust))'),
                ('session-shape', 'session.dataTask(with: request).resume()'),
                ('session-shape', 'let start = session.dataTask'),
                ('session-shape', 'session.downloadTask(with: request).resume()'),
                ('session-shape', 'session.uploadTask(with: request, from: body).resume()'),
                ('session-shape', 'session.webSocketTask(with: url).resume()'),
                ('session-shape', 'session.streamTask(withHostName: host, port: 443).resume()'),
                ('session-shape', 'let (file, _) = try await session.download(for: request)'),
                ('session-shape', 'let (data, _) = try await session.data(from: url)'),
                ('session-shape', 'let (bytes, _) = try await session.bytes(from: url)'),
                ('session-shape', 'public typealias AgentNetSession = URLSession'),
                ('session-shape', 'typealias Reply = (Data, HTTPURLResponse)'),
                ('session-shape', 'typealias Sent = URLRequest'), ('session-shape', 'typealias Bytes = AsyncBytes'),
                ('session-shape', 'let session = URLSession.value(forKey: "sharedSession")'),
                ('session-shape', 'configuration.httpCookieStorage = .shared'),
                ('session-shape', 'let session = type(of: session).shared'),
                ('session-shape', 'let session: URLSession = .`shared`'),
                ('session-shape', 'let (data, _) = try await session.`data`(from: url)'),
                ('session-shape', 'let (file, _) = try await session.`download`(from: url)'),
                ('session-shape', 'let (bytes, _) = try await session . `bytes` (from: url)'),
                ('session-shape', '_ = (URLSession.self as AnyObject).value(forKey: "shared" + "Session")'),
                ('session-shape', 'configuration.setValue(nil, forKey: "urlCache")'),
                ('session-shape', '_ = session.perform(NSSelectorFromString("x"))'),
                ('session-shape', 'let pick = Selector(("sharedSession"))'), ('session-shape', 'let pick = #selector(f)'),
                ('session-shape', 'URLCredential(trust/* */: trust)'), ('session-shape', 'final class HelmSession: URLSession {}'),
                ('session-shape', 'extension URLSession { static var helm: URLSession { .shared } }'),
                ('session-shape', 'extension URLSessionConfiguration {}'),
                ('session-shape', 'typealias Credential = URLCredential'),
                ('url-other', 'for try await line in url.lines { print(line) }'),
                ('web-address', 'static let other = "https://example.invalid/v1"'),
                ('web-address', 'static let claudeBase = "https://api.anthropic.com"'),
                ('web-address', 'let local = "http://127.0.0.1:11434"'),
                ('url-other', 'let old = NSURLConnection(request: request, delegate: nil)'),
                ('url-other', 'final class Loader: URLProtocol {}'), ('url-other', 'configuration.urlCache = URLCache.shared'),
                ('url-other', 'let jar = HTTPCookieStorage.shared'), ('url-other', 'let request = NSMutableURLRequest(url: url)'),
                ('url-other', 'for try await byte in url.resourceBytes {}'), ('url-other', 'func read(_ bytes: URL.AsyncBytes) {}'),
                ('unified-log', 'Logger(subsystem: "helm", category: "ai").info("sent")'),
                ('agent-no-write', 'try FileManager.default.removeItem(at: url)'), ('agent-no-write', 'import Darwin'),
                ('agent-no-read', 'let text = try String(contentsOfFile: path)'),
                ('one-file', 'SecTrustEvaluateWithError(trust, nil)'), ('one-file', 'SecItemCopyMatching(query, &result)'),
                ('one-file', 'let transport = HTTPTransport(liveProfile: profile, secrets: secrets, limits: .cloud)'),
                ('build-path', 'let cache = "/Users/me/Library/Caches/helm"')]:
            self.fails(rule, TRANSPORT, TRANSPORT_CODE + code)

    def test_transport_file_must_exist(self):
        loop = {LOOP: 'import Foundation\n'}
        self.assertEqual(rules(self.problems(loop)), {'url-session'})
        self.assertIn(TRANSPORT, self.problems(loop)[0])
        self.assertEqual(self.problems(dict(loop, **{TRANSPORT: TRANSPORT_CODE})), [])
        # The same file somewhere else is not the transport file.
        moved = dict(loop, **{'Sources/HelmAgent/Transport/Transport.swift': '// The transport.\n'})
        self.assertEqual(rules(self.problems(moved)), {'url-session'})
        # Nothing to miss before the module exists.
        self.assertEqual(self.swift('import Foundation'), [])

    def test_provider_addresses_pass_only_as_written_and_only_in_endpoints(self):
        self.assertEqual(self.planted(ENDPOINTS, ENDPOINT_CODE), [])
        for relative in (TRANSPORT, 'Sources/HelmAgent/Providers/AnthropicMessagesAdapter.swift',
                         'Sources/HelmAgent/Transport/Endpoints+More.swift', 'Sources/HelmUI/Settings/AISettings.swift', CORE):
            found = self.planted(relative, ENDPOINT_CODE)
            self.assertEqual(rules(found), {'web-address'}, relative)
            self.assertEqual(len(found), 4, relative)
        for line in ['static let mistralBase = "https://api.mistral.ai/v1"',
                     'static let claudeBase = "https://api.anthropic.com.example.invalid"',
                     'static let claudeBase = "http://api.anthropic.com"',
                     'static let claudeBase = "https://api.anthropic.com" + "/v2"',
                     'public static let claudeBase = "https://api.anthropic.com"',
                     'static let ollamaBase = "http://127.0.0.1:11434"', 'static let socketBase = "wss://api.openai.com/v1"',
                     '// See https://docs.anthropic.com/en/api', 'static let claudeBase = "https://api.anthropic.com" // Claude']:
            self.fails('web-address', ENDPOINTS, ENDPOINT_CODE + line)

    # The loopback listener, OpenAI's sign-in host and the help pages.

    def test_listener_file_passes_and_its_socket_fails_anywhere_else(self):
        self.assertEqual(self.planted(LISTENER, LISTENER_CODE), [])
        elsewhere = (TRANSPORT, LOOP, ENDPOINTS, 'Sources/HelmAgent/Transport/AgentLoopbackListener+More.swift',
                     'Sources/HelmAgent/SignIn/AgentChatGPTSignIn.swift', THREAD, HEADER, CORE,
                     'Sources/HelmUI/Settings/AISetupModel.swift', 'Sources/HelmApp/macOS/AppController+Agent.swift')
        self.expect('sockets', LISTENER_CODE, fails=elsewhere)
        self.expect('socket-call', LISTENER_CODE, fails=elsewhere)
        for code in ['let descriptor = socket(AF_INET, SOCK_STREAM, 0)', 'var address = sockaddr_in()',
                     'let family = PF_INET', '// An AF_INET socket']:
            self.expect('sockets' if 'socket(' not in code else 'socket-call', code, fails=(TRANSPORT, LOOP, CORE),
                        passes=[LISTENER])

    def test_listener_still_fails_for_everything_but_listening_on_this_mac(self):
        for rule, code in [
                ('socket-call', 'let result = connect(descriptor, pointer, length)'),
                ('socket-call', 'let other = Darwin.socket(AF_INET, SOCK_STREAM, 0)'),
                ('socket-call', '_ = Darwin.bind(descriptor, pointer, length)'),
                ('sockets', 'var address = sockaddr_in6()'), ('sockets', 'let family = AF_INET6'),
                ('sockets', 'let datagrams = socket(AF_INET, SOCK_DGRAM, 0)'), ('sockets', 'let sent = sendto(fd, b, n, 0, p, l)'),
                ('sockets', 'let heard = recvfrom(fd, b, n, 0, p, &l)'), ('sockets', 'getaddrinfo(host, nil, &hints, &found)'),
                ('sockets', 'address.sin_addr.s_addr = inet_addr("10.0.0.1")'),
                ('listener-loopback', 'address.sin_addr.s_addr = INADDR_ANY'),
                ('listener-loopback', 'address.sin_addr.s_addr = INADDR_BROADCAST'),
                ('listener-loopback', 'let host = "0.0.0.0"'), ('listener-loopback', 'let host = "localhost"'),
                ('listener-loopback', 'let unix = socket(AF_UNIX, SOCK_STREAM, 0)'),
                ('listener-loopback', 'setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, size)'),
                ('url-session', 'let session = URLSession(configuration: .ephemeral)'), ('import', 'import Network'),
                ('network-framework', 'let listener = try NWListener(using: .tcp)'),
                ('web-address', 'let page = "https://example.invalid/done"'),
                ('agent-no-read', 'let text = try String(contentsOfFile: path)'),
                ('agent-no-write', 'try FileManager.default.removeItem(at: url)')]:
            self.fails(rule, LISTENER, LISTENER_CODE + code)
        # The listener's own rule holds there alone.
        self.passes('listener-loopback', TRANSPORT, 'let host = "localhost"')

    def test_sign_in_host_and_help_pages_pass_only_as_written_and_only_in_their_files(self):
        host = 'static let openAISignInBase = "https://auth.openai.com"'
        self.assertEqual(self.planted(ENDPOINTS, ENDPOINT_CODE + host), [])
        self.assertEqual(self.planted(HELP_LINKS, HELP_CODE), [])
        for relative in (TRANSPORT, LOOP, HELP_LINKS, 'Sources/HelmUI/Settings/AISettings.swift', CORE):
            self.assertEqual(rules(self.planted(relative, host)), {'web-address'}, relative)
        for relative in (ENDPOINTS, TRANSPORT, LISTENER, 'Sources/HelmUI/Settings/AISettings.swift',
                         'Sources/HelmUI/Onboarding/AIModeScreen.swift', CORE):
            found = self.planted(relative, HELP_CODE)
            self.assertEqual(rules(found), {'web-address'}, relative)
            self.assertEqual(len(found), 8, relative)
        for line in ['static let authorize = "https://auth.openai.com/api/accounts/authorize"',
                     'static let openAISignInBase = "http://auth.openai.com"',
                     'static let openAISignInBase = "https://auth.openai.com.example.invalid"']:
            self.fails('web-address', ENDPOINTS, ENDPOINT_CODE + line)
        for line in ['static let mistralKeys = "https://console.mistral.ai/api-keys"',
                     'static let claudeKey = "https://platform.claude.com/settings/keys"',
                     'static let chatGPTUsage = "https://chatgpt.com/settings/usage?from=helm"',
                     'static let ollamaStart = "https://docs.ollama.com/quickstart" // Ollama',
                     '// See https://docs.ollama.com/faq']:
            self.fails('web-address', HELP_LINKS, HELP_CODE + line)

    def test_session_shapes_fail_everywhere(self):
        for code in ['URLSession.shared.data(for: request)', 'URLSession .shared', 'URLSessionConfiguration.default',
                     'URLSessionConfiguration.background(withIdentifier: "helm")', '.background(withIdentifier: "helm")',
                     'URLCredential(trust: trust)', 'URLCredential.init(trust: trust)', 'let make = URLCredential.init(trust:)',
                     'URLCredential(forTrust: trust)', 'session.dataTask(with: url)', 'session.dataTaskPublisher(for: url)',
                     'session.downloadTask(with: url)', 'session.uploadTask(with: request, fromFile: file)',
                     'session.webSocketTask(with: url)', 'session.streamTask(with: service)',
                     'try await session.download(from: url)', 'try await session.upload(for: request, from: body)',
                     '// dataTask(with:) is the old way', 'let name = "downloadTask"',
                     'let make = URLSessionConfiguration.background', 'try await session.download(resumeFrom: data)',
                     'let key = "sharedSession"',
                     'let key = "defaultSessionConfiguration"', 'let key = "backgroundSessionConfigurationWithIdentifier:"',
                     'let key = "credentialForTrust:"', 'let (data, _) = try await HelmSession.shared.data(from: url)',
                     'let (bytes, _) = try await session.bytes(from: url)', 'try await session.`data`(from: url)',
                     'URLCredential(trust /* it */ : trust)', 'let make = session.`dataTask`',
                     'let start = session.streamTask', 'let name = "streamTask"', 'items.dataTask (with: url)']:
            self.expect('session-shape', code, fails=(CORE, HEADER, LOOP, TRANSPORT))
        # A property may have a task-making call's name, and a parameter may be called trust.
        for code in ['private var streamTask: Task<Void, Never>?', 'let downloadTask = Task { await fetchThumbnails() }',
                     'self.streamTask = Task { await run() }', 'self.streamTask?.cancel()', 'if let task = streamTask { task.cancel() }',
                     'func evaluate(trust: Level) {}; evaluate(trust: .high)', '// The streamTask is cancelled on stop.',
                     'let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .xml, options: 0)']:
            self.expect('session-shape', code, passes=(CORE, HEADER, LOOP, TRANSPORT))
        for code in ['func lines(_ bytes: FileHandle.AsyncBytes) {}', 'for try await line in handle.bytes.lines {}',
                     'let count = report.lines.count', 'if fit.lines == 1 { return }']:
            self.expect('url-session', code, passes=(CORE, HEADER, LOOP))
            self.expect('url-other', code, passes=(CORE, HEADER, LOOP, TRANSPORT))
        for code in ['for try await line in url.lines { print(line) }', 'let lines = fileURL.lines',
                     'for try await line in URL(string: text)!.lines {}', 'let first = try await address.lines.first { _ in true }']:
            self.expect('url-other', code, fails=(CORE, HEADER, LOOP, TRANSPORT))
        for code in ['NSURLRequest(url: url)', 'NSMutableURLRequest(url: url)', 'let name = "NSURLSession"',
                     'NSURLConnection(request: request, delegate: nil)', 'NSURLDownload(request: request, delegate: nil)',
                     'URLCache(memoryCapacity: 0, diskCapacity: 0)', 'final class Loader: URLProtocol {}',
                     'let jar: HTTPCookieStorage? = nil', 'CFHTTPMessageCreateRequest(nil, method, url, version)',
                     'CFNetworkCopySystemProxySettings()', 'AsyncImage(url: url)', 'LPMetadataProvider()',
                     'for try await byte in url.resourceBytes {}', 'func take(_ bytes: URL.AsyncBytes) {}']:
            self.expect('url-other', code, fails=(CORE, HEADER, LOOP, TRANSPORT))
        # `.shared` and `.default` with no type are a session's only where a session can be named.
        for code in ['let app: NSApplication = .shared', 'let center: NotificationCenter = .default',
                     'cell = table.makeView(withIdentifier: id, owner: nil)', 'Task(priority: .background) {}']:
            self.expect('session-shape', code, passes=(CORE, HEADER, LOOP))
        for code in ['completionHandler(.performDefaultHandling, nil)', 'Task(priority: .background) {}',
                     'DispatchQueue.global(qos: .default).async { work() }', 'Task.detached(priority: .default) { work() }',
                     'let configuration = URLSessionConfiguration.ephemeral', 'let trust = method == serverTrust',
                     'let (data, response) = try await session.data(for: request)',
                     'let (bytes, response) = try await session.bytes(for: request)',
                     '// Cookies are off by default. The key is never shared.']:
            self.passes('session-shape', TRANSPORT, code)

    # AI mode's module.

    def test_helm_agent_passes_by_its_own_names(self):
        for relative in (LOOP, 'Sources/HelmAgent/Contracts/AgentPlanContracts.swift',
                         'Sources/HelmAgent/Scripted/MemoryAgentDisk.swift', TRANSPORT):
            self.assertEqual(self.planted(relative, AGENT_CODE), [], relative)
        self.assertEqual(self.planted(LOOP, 'enum E { case rename(X, to: Y) }'), [])

    def test_helm_agent_names_no_way_to_change_a_file_or_start_a_tool(self):
        for code in [
                # Each word of the rule.
                'try FileManager.default.removeItem(atPath: path)', 'let handle = FileHandle(forWritingAtPath: path)',
                'NSFileCoordinator().coordinate(writingItemAt: url, error: nil) { _ in }',
                'let wrapper = FileWrapper(regularFileWithContents: data)', 'OutputStream(toFileAtPath: path, append: false)',
                'UserDefaults.standard.set(true, forKey: "aiMode")', 'NSKeyedArchiver.archiveRootObject(plan, toFile: path)',
                'try manager.removeItem(at: url)', 'try manager.moveItem(at: old, to: new)',
                'try manager.copyItem(at: old, to: new)',
                'try manager.replaceItem(at: old, withItemAt: new, backupItemName: nil, resultingItemURL: nil)',
                'try manager.replaceItemAt(old, withItemAt: new)', 'try manager.trashItem(at: url, resultingItemURL: nil)',
                'try manager.createDirectory(at: url, withIntermediateDirectories: true)',
                'manager.createFile(atPath: path, contents: data)', 'try data.write(to: url)',
                'try text.write(toFile: path, atomically: true, encoding: .utf8)', 'setxattr(path, name, value, size, 0, 0)',
                'removexattr(path, name, 0)', 'renamex_np(old, new, 0)', 'let task = NSTask()', 'let tool = Process()',
                'posix_spawn(&pid, path, nil, nil, arguments, nil)', 'NSWorkspace.shared.open(url)',
                'unlink(path)', 'creat(path, 0o644)', 'mkdir(path, 0o755)', 'rmdir(path)', 'symlink(target, path)',
                'link(old, new)', 'truncate(path, 0)', 'chmod(path, 0o600)', 'chflags(path, 0)', 'copyfile(old, new, nil, 0)',
                'clonefile(old, new, 0)', 'removefile(path, nil, 0)', 'system("say done")', 'popen("say done", "r")',
                'let child = fork()', 'execv(path, arguments)', 'execve(path, arguments, environment)', 'execl(path, name)',
                'execvp(name, arguments)', 'rename(old, new)', 'import Darwin', 'import HelmFileSystem',
                'import HelmOperations', 'import HelmUI',
                # The same things by another spelling: `.init(`, the type left out, an alias, nothing called, a
                # comment, a string, the module's name in front, a space or a line break before the bracket.
                'let files = FileManager.init()', 'let files: FileManager = .default', 'typealias Files = FileManager',
                'let remove = FileManager.removeItem', 'let handle: FileHandle? = .init(forWritingAtPath: path)',
                'let out: OutputStream? = .init(toFileAtPath: path, append: true)', 'typealias Store = UserDefaults',
                'CFPreferencesSetAppValue(key, value, app)', '// FileManager would do it', 'let name = "NSFileManager"',
                'let tool = Process.init()', 'let tool: Process = .init()', 'typealias Tool = Process',
                'try Process.run(url, arguments: [])', 'let tools: [Process] = []', '// Process() starts a tool',
                'let save = data.write', 'try data.write(to: url, options: .atomic)', 'let save = data.write(to:options:)',
                'extension Data { func keep(_ url: URL) throws { try write(to: url) } }', 'try url.setResourceValues(values)',
                'fsetxattr(fd, name, value, size, 0, 0)', 'posix_spawnp(&pid, name, nil, nil, arguments, nil)',
                'unlinkat(folder, path, 0)', 'ftruncate(fd, 0)', 'fchmod(fd, 0o600)', 'Darwin.unlink(path)',
                'Foundation.unlink(path)', 'Glibc.unlink(path)', 'Darwin .unlink(path)', '`unlink`(path)', 'unlink (path)',
                'unlink\n    (path)', 'unlink /* gone */ (path)', '_ = paths.map { unlink($0) }', 'let text = "\\(unlink (path))"',
                '// unlink(path) would remove it', 'let call = "mkdir(path, 0o755)"', 'syscall(SYS_unlink, path)',
                'return rename(old, new)', 'rename (old, new)', 'rename(\n    old,\n    new\n)', 'rename(strdup(old), strdup(new))',
                'rename(flag ? old : other, new)', 'Darwin.rename(old, new)', '// rename(old, new) moves it',
                'let call = "rename(old, new)"', 'renameat(folder, old, folder, new)', 'import AppKit', 'import System',
                'import Combine', '@testable import HelmPersistence', '@_exported import HelmSearch', 'import func Darwin.unlink',
                'import Foundation; import Darwin', 'internal import HelmCoreExtras', 'Darwin.remove(path)',
                'CoreFoundation.unlink(path)', 'let task = try NSUserUnixTask(url: url)',
                'files.perform(Selector(("removeItemAtPath:error:")), with: path, with: nil)',
                'try manager.createDirectoryAtPath(path)', '#if canImport(Darwin)', 'let module = "Glibc"', '#if canImport(Musl)',
                'let channel = DispatchIO(type: .stream, path: path, oflag: 0, mode: 0, queue: queue) { _ in }',
                'renameatx_np(folder, old, folder, new, 0)', 'let coordinator = NSFileCoordinator()',
                'let archive = NSKeyedArchiver(requiringSecureCoding: true)', 'try text.write(toFile: path)',
                'extension NSString { func keep(_ path: String) { write(toFile: path, atomically: true) } }']:
            # The rule is HelmAgent's alone. Elsewhere these are Helm's ordinary work.
            self.expect('agent-no-write', code,
                        fails=(LOOP, 'Sources/HelmAgent/Scripted/MemoryAgentDisk.swift', TRANSPORT, KEYCHAIN),
                        passes=(HEADER, 'Sources/HelmOperations/Execute/OperationExecutor.swift'))

    def test_helm_agent_reaches_no_file_through_core_foundation(self):
        reads = ['CFURLCopyResourcePropertyForKey(url, kCFURLFileSizeKey, &value, nil)',
                 'CFURLSetResourcePropertyForKey(url, kCFURLIsHiddenKey, kCFBooleanTrue, nil)',
                 'CFURLSetResourcePropertyForKey(url, kCFURLIsUserImmutableKey, kCFBooleanTrue, nil)',
                 'let there = CFURLResourceIsReachable(url, nil)',
                 'let mark = CFURLCreateBookmarkData(nil, url, [], nil, nil, nil)',
                 'CFURLSetTemporaryResourcePropertyForKey(url, key, value)', 'let values = CFURLCopyResourcePropertiesForKeys (url, keys, nil)']
        for code in reads:
            self.expect('agent-no-read', code, fails=(LOOP, 'Sources/HelmAgent/Scope/AgentScopeGate.swift', TRANSPORT),
                        passes=(HEADER, 'Sources/HelmFileSystem/Live/LiveFileSystem.swift'))
        for code in ['let file = tmpfile()', 'let bundle = CFBundleCreate(nil, url)',
                     'let bundles = CFBundleCreateBundlesFromDirectory(nil, url, nil)']:
            self.expect('agent-no-write', code, fails=(LOOP, 'Sources/HelmAgent/Scripted/MemoryAgentDisk.swift', TRANSPORT),
                        passes=(HEADER, 'Sources/HelmOperations/Execute/OperationExecutor.swift'))
        # The module's own names that start the same way pass.
        for code in ['let kind: CFURLPathStyle', 'let url = URL(fileURLWithPath: path)']:
            self.expect('agent-no-read', code, passes=(LOOP,))

    def test_the_live_parts_are_named_only_by_the_runtime_and_the_app(self):
        app = 'Sources/HelmApp/macOS/AppController+Agent.swift'
        for code in ['let client = AgentLiveParts.makeClient(profile, "claude-opus-5-5", store)',
                     'let parts = AgentRuntimeParts(secrets: s, makeClient: AgentLiveParts.makeClient)',
                     'let make = AgentLiveParts.makeSession', 'typealias Live = AgentLiveParts',
                     '// AgentLiveParts builds the client', 'let name = "AgentLiveParts"']:
            self.expect('one-file', code, passes=(LIVE_PARTS, app), fails=(
                'Sources/HelmUI/Probe/ProbeOne.swift', 'Sources/HelmAgent/Runtime/AgentRuntime.swift', LOOP, PANEL_MODEL,
                'Sources/HelmApp/macOS/AppController.swift', 'Sources/HelmApp/macOS/HostSmokeDriver+Agent.swift', CORE))
        self.passes('one-file', LOOP, 'let parts: AgentRuntimeParts')
        self.passes('one-file', LOOP, '// as Runtime/AgentLiveParts.swift does')

    def test_helm_agent_names_no_way_to_open_or_look_up_a_file(self):
        for code in [
                'let text = try String(contentsOfFile: path)', 'try manager.contentsOfDirectory(atPath: path)',
                'let stream = InputStream(fileAtPath: path)', 'getxattr(path, name, nil, 0, 0, 0)', 'listxattr(path, nil, 0, 0)',
                'let walk = manager.enumerator(atPath: path)', 'fopen(path, "r")', 'open(path, O_RDONLY)',
                'read(fd, &buffer, 1)', 'mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)', 'opendir(path)', 'readdir(folder)',
                'stat(path, &info)', 'lstat(path, &info)', 'realpath(path, nil)',
                # By another spelling.
                'let text: String = try .init(contentsOfFile: path, encoding: .utf8)', 'NSData(contentsOfFile: path)',
                'let load = String.init(contentsOfFile:)', 'NSData(contentsOfMappedFile: path)',
                'let stream: InputStream? = .init(fileAtPath: path)', 'typealias Source = InputStream',
                'fgetxattr(fd, name, nil, 0, 0, 0)', 'let values = try url.resourceValues(forKeys: [.fileSizeKey])',
                'let there = try url.checkResourceIsReachable()', 'let query = NSMetadataQuery()',
                'openat(folder, path, O_RDONLY)', 'fstat(fd, &info)', 'pread(fd, &buffer, 1, 0)', 'readlink(path, &buffer, 1)',
                'freopen(path, "r", stdin)', 'Darwin.open(path, O_RDONLY)', 'Foundation.stat(path, &info)',
                '`open`(path, O_RDONLY)', 'open (path, O_RDONLY)', 'open\n    (path, O_RDONLY)', 'open /* it */ (path, O_RDONLY)',
                'let fd = paths.map { open($0, O_RDONLY) }', 'let text = "\\(open (path, O_RDONLY))"',
                '// open(path, O_RDONLY) would read it', 'let call = "stat(path, &info)"', '// contentsOfFile reads it',
                'let name = "NSInputStream"', 'let plan = NSKeyedUnarchiver.unarchiveObject(withFile: path)',
                'let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()',
                'try (url as NSURL).checkResourceIsReachableAndReturnError(nil)',
                'let values = try url.promisedItemResourceValues(forKeys: keys)', 'fts_open(paths, FTS_PHYSICAL, nil)',
                'Security.open(path, O_RDONLY)', 'try url.getResourceValue(&value, forKey: key)',
                'try url.getPromisedItemResourceValue(&value, forKey: key)', 'let there = try url.checkPromisedItemIsReachable()',
                'flistxattr(fd, nil, 0, 0)',
                'let names = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)']:
            self.expect('agent-no-read', code,
                        fails=(LOOP, 'Sources/HelmAgent/Scope/AgentScopeGate.swift', TRANSPORT, KEYCHAIN),
                        passes=(HEADER, 'Sources/HelmFileSystem/Live/LiveFileSystem.swift'))

    def test_each_c_call_fails_bare_and_passes_as_anything_else(self):
        writes = ['unlink', 'unlinkat', 'creat', 'mkdir', 'mkdirat', 'rmdir', 'symlink', 'symlinkat', 'link', 'linkat', 'truncate',
                  'ftruncate', 'chmod', 'fchmod', 'lchmod', 'fchmodat', 'chflags', 'fchflags', 'lchflags', 'copyfile', 'fcopyfile',
                  'clonefile', 'fclonefileat', 'clonefileat', 'removefile', 'system', 'popen', 'fork', 'vfork', 'execl', 'execle',
                  'execlp', 'execv', 'execve', 'execvp', 'execvP', 'exect', 'fexecve', 'syscall', 'chown', 'lchown', 'fchown',
                  'fchownat', 'utimes', 'futimes', 'lutimes', 'futimens', 'utimensat', 'setattrlist', 'fsetattrlist',
                  'exchangedata', 'mkstemp', 'mkstemps', 'mkdtemp', 'mkdtemps', 'mkostemp', 'mkostemps', 'mkfifo', 'mknod',
                  'remove']
        reads = ['fopen', 'freopen', 'fdopen', 'open', 'openat', 'open_dprotected_np', 'read', 'pread', 'readv', 'preadv', 'mmap',
                 'opendir', 'fdopendir', 'readdir', 'readdir_r', 'scandir', 'fts_open', 'ftw', 'nftw', 'stat', 'lstat', 'fstat',
                 'fstatat', 'realpath', 'readlink', 'readlinkat', 'statfs', 'fstatfs', 'statvfs', 'fstatvfs', 'getattrlist',
                 'fgetattrlist', 'getattrlistat', 'getattrlistbulk', 'getdirentries', 'access', 'faccessat', 'glob', 'pathconf',
                 'fpathconf']
        for rule, names in (('agent-no-write', writes), ('agent-no-read', reads)):
            for name in names:
                for code in [f'{name}(path)', f'_ = {name}(path)', f'if {name}(path) == 0 {{ return }}', f'`{name}`(path)',
                             f'{name} (path)', f'{name}\n    (path)', f'let text = "\\({name} (path))"',
                             f'// {name}(path) is the call', f'let call = "{name}(path)"']:
                    self.expect(rule, code, fails=(LOOP, TRANSPORT), passes=[HEADER])
                # A method, a longer name, a declaration, a label, a plain word and a sentence are not the call.
                for code in [f'disk.{name}(path)', f'self.{name}(path)', f're{name}(path)', f'{name}d(path)',
                             f'func {name}(_ path: String) {{}}', f'make({name}: path)', f'case {name}, other',
                             f'let {name} = AgentToolCode.{name}', f'// The model may {name} (or not) what it is given.',
                             f'let note = "Nothing here will {name} (or try to) a file."']:
                    self.expect(rule, code, passes=(LOOP, TRANSPORT))
        # Through a module's name it is the same call.
        for module in ['Darwin', 'Glibc', 'Musl', 'Foundation', 'CoreFoundation', 'Dispatch', 'ObjectiveC', 'Security']:
            for code in [f'{module}.unlink(path)', f'{module} .unlink(path)', f'{module}.`unlink`(path)',
                         f'{module}.unlink (path)']:
                self.fails('agent-no-write', LOOP, code)
            for code in [f'{module}.open(path, O_RDONLY)', f'{module}\n    .stat(path, &info)', f'{module}.open (path, O_RDONLY)',
                         f'// {module}.open(path, O_RDONLY) is the call']:
                self.fails('agent-no-read', LOOP, code)
            for code in [f'{module}.rename(old, new)', f'{module}.rename (old, new)', f'let call = "{module}.rename(old, new)"']:
                self.fails('agent-no-write', LOOP, code)

    def test_c_calls_handed_on_by_name_fail(self):
        for rule, code in [
                ('agent-no-write', '_ = path.withCString(unlink)'), ('agent-no-write', '_ = (unlink)(path)'),
                ('agent-no-write', 'let move = rename; _ = move(old, new)'), ('agent-no-write', 'let gone = paths.map(remove)'),
                ('agent-no-write', 'let call = `unlink`'), ('agent-no-write', 'run(first, unlink)'),
                ('agent-no-write', 'run(handler: chmod)'), ('agent-no-write', 'let call = Darwin.unlink'),
                ('agent-no-read', 'let look = lstat; _ = look(path, &info)'), ('agent-no-read', '_ = path.withCString(access)'),
                ('agent-no-read', 'let call = open')]:
            self.fails(rule, LOOP, code)
            self.passes(rule, HEADER, code)
        # A name declared, given a value, written as a label, read as a member or listed after `case`, a value passed
        # under its own name, and the calls Swift doesn't offer.
        for code in ['public var system: String', 'init(system: String) { self.system = system }',
                     'let input = AgentTurnInput(system: system, tools: tools)', 'let open = AgentToolCode.link',
                     'case notFound, system, hidden', 'enum E { case link, other }', 'if let link { use(link.name) }',
                     'let link: AgentToolCode = .link; let same = code == link', 'guard let read else { return }',
                     'let call = self.unlink', 'if link != nil { return }', 'func remove(_ id: String) {}',
                     'let text = "the call unlink"', '// unlink is the call']:
            self.passes('agent-no-write', LOOP, code)
            self.passes('agent-no-read', LOOP, code)
        for code in ['try data.`write`(to: url)', 'try data . write(to: url)', 'try `write`(to: url)',
                     'try NSFileVersion.removeOtherVersionsOfItem(at: url)',
                     'NSAppleEventDescriptor(bundleIdentifier: app).sendEvent(options: [], timeout: 1)',
                     'remove(path)', '_ = remove(path)', 'remove (path)', 'Darwin.remove(path)', '// remove(path) is the call']:
            self.expect('agent-no-write', code, fails=(LOOP, TRANSPORT), passes=[HEADER])
        for code in ['self.remove(path)', 'try secrets.remove(id)', 'items.remove(at: 0)', 'remove()',
                     'func remove(_ path: String) {}', '// To remove (a file, a folder) is one step.']:
            self.passes('agent-no-write', LOOP, code)
        for code in ['let info = Bundle(path: path)?.infoDictionary', 'let app = Bundle(url: url)',
                     'let app = Bundle.init(path: path)', 'let item = NSMetadataItem(url: url)',
                     '_ = (path as NSString).completePath(into: nil, caseSensitive: true, matchesInto: nil, filterTypes: nil)',
                     'let real = try URL(resolvingAliasFileAt: url)', 'let mark = try url.bookmarkData()',
                     'let back = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)',
                     'let app = Bundle(path /* it */: path)']:
            self.expect('agent-no-read', code, fails=(LOOP, TRANSPORT), passes=[HEADER])
        self.passes('agent-no-read', LOOP, 'let own = Bundle.main; let other = Bundle(for: AgentSession.self)')

    def test_c_rename_is_told_from_the_plan_step(self):
        for code in ['enum E { case rename(X, to: Y) }', 'case rename(AgentPlanItem, to: ValidFileName)',
                     'case organize(rootLabel: String), move(Int), copy(Int), rename(Int), trash(Int)',
                     'steps.append(.rename(item, to: name))', 'let step = AgentPlanStep.rename(item, to: name)',
                     'case .rename(let item, let name): return item.name', 'case let .rename(item, name): return item.name',
                     'return rename(item, to: name)', 'rename(item,\n       to: name)', 'rename(to: name, item)',
                     'func rename(_ item: AgentPlanItem, _ name: ValidFileName) {}', 'let renamed = renames(old, new)',
                     'table.rename(old, new)', 'rename(old)', '// Rename (one item, one name) keeps the extension.',
                     '// To rename (a file, a folder) is one step.', 'let hint = "rename (a file, a folder)"']:
            self.passes('agent-no-write', LOOP, code)
        for code in ['rename(old, new)', 'rename(old,new)', 'rename( old , new )', 'if rename(old, new) != 0 { return }',
                     'rename(old, new, flags)', 'rename(paths[0], paths[1])', 'rename(a.withCString { $0 }, b)',
                     'rename(flag ? a : b, c)', 'rename(f(x: a), b)', 'rename("a", "b")', 'rename("a: b", "c")',
                     'rename (old, new)', 'rename\n    (old, new)', '`rename`(old, new)', 'Foundation.rename(old, new)',
                     'rename (paths[0], paths[1])', 'rename (old.withCString { $0 }, new)', 'rename ([a: b, c: d][a]!, e)',
                     'rename (pick(a, from: b), c)', 'rename (\n    old, // the first\n    new)',
                     'let text = "\\(rename (old, new))"', '// rename(old, new) is the call', 'let call = "rename(old, new)"']:
            self.fails('agent-no-write', LOOP, code)
        # A call the raw text and the code both show is one problem, not two.
        for code in ['rename(old, new)', 'Foundation.rename(old, new)', 'unlink(path)', 'open(path, O_RDONLY)']:
            self.assertEqual(len(self.planted(LOOP, code)), 1, code)

    def test_spaced_calls_fail_in_code_and_pass_in_a_sentence(self):
        for call in ['unlink (path)', 'open (path, 0)', 'read (fd, &buffer, 1)', 'link (old, new)', 'system ("say")',
                     'stat (path, &info)', 'truncate (path, 0)']:
            rule = 'agent-no-read' if call.split()[0] in ('open', 'read', 'stat') else 'agent-no-write'
            self.fails(rule, LOOP, call)
            self.fails(rule, LOOP, 'let text = "\\(' + call + ')"')
            self.fails(rule, LOOP, 'let text = "a" // "\n' + call)
            self.passes(rule, LOOP, '// A sentence: ' + call + ' is what it says.')
            self.passes(rule, LOOP, '/* A sentence: ' + call + ' is what it says. */')
            self.passes(rule, LOOP, 'let text = "A sentence: ' + call.replace('"', '') + ' is what it says."')
            self.passes(rule, LOOP, 'let text = """\nA sentence: ' + call.replace('"', '') + '\n"""')

    # The files that draw a model's text.

    def test_panel_draws_text_plain_and_opens_nothing(self):
        for relative in (THREAD, 'Sources/HelmUI/Agent/AgentPlanCard.swift'):
            self.assertEqual(self.planted(relative, PANEL_CODE), [], relative)
        for code in ['textView.isAutomaticLinkDetectionEnabled = false; other()', 'view.isAutomaticLinkDetectionEnabled = false }',
                     'view.isAutomaticLinkDetectionEnabled = false // off', 'if code == .link { count += 1 }',
                     'let skipped = plan.leftOut[.link] ?? 0', 'switch code { case .link: return 1 default: return 0 }']:
            self.passes('agent-ui-plain', THREAD, code)
        for code in [
                'Text(LocalizedStringKey(reply))', 'let text = try AttributedString(markdown: reply)',
                'Link("Open", destination: url)', 'let detector = try NSDataDetector(types: types)',
                'textView.isAutomaticLinkDetectionEnabled = true', '@Environment(\\.openURL) private var openURL',
                'NSWorkspace.shared.open(url)', 'NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])',
                # By another spelling.
                'Text(LocalizedStringKey.init(reply))', 'let key: LocalizedStringKey = .init(reply)',
                'typealias Key = LocalizedStringKey', 'Text(.init(reply))', 'Text( .init( reply ) )', 'Button(.init(title)) {}',
                'Text(.init(stringLiteral: reply))', 'Text(LocalizedStringResource(stringLiteral: reply))',
                'let text: AttributedString = try .init(markdown: reply)', 'NSAttributedString(markdown: data, options: options)',
                'let options = AttributedString.MarkdownParsingOptions()', '// Markdown in a reply', 'let kind = "MARKDOWN"',
                'Link.init(destination: url) { Text(verbatim: name) }', 'let link: Link<Text> = .init("Open", destination: url)',
                'typealias Jump = Link<Text>', 'Link (name, destination: url)', 'ShareLink(item: url)',
                'textView.isAutomaticLinkDetectionEnabled=true', 'textView.isAutomaticLinkDetectionEnabled = on',
                'textView.isAutomaticLinkDetectionEnabled = !off', 'textView.isAutomaticDataDetectionEnabled = true',
                'textView.toggleAutomaticLinkDetection(nil)', 'view.dataDetectorTypes = .link',
                'let action: OpenURLAction', 'let open = NSWorkspace.shared', 'NSSharingServicePicker(items: [url])',
                'LSOpenCFURLRef(url as CFURL, nil)', 'let tool = Process()', 'let tool: Process = .init()',
                'Text(.init(reply), tableName: nil)', 'let words: LocalizedStringResource = "Open"',
                'Text(.init(stringInterpolation: parts))', 'textView.toggleAutomaticDataDetection(nil)', 'let tool = NSTask()',
                'let share = NSSharingService.sharingServices(forItems: [url])', 'textView.isAutomaticDataDetectionEnabled = on',
                'Text(.init((reply)))', 'Text(.init( ( reply ) ))', '`Link`("x", destination: url)',
                'let jump: `Link`<Text> = .init("x", destination: url)',
                'var text = AttributedString(reply); text.link = URL(string: reply)', 'text[range].link = url',
                'let container = AttributeContainer().link(url)', 'NSAttributedString(string: reply, attributes: [.link: url])',
                'let key = NSAttributedString.Key.link', 'let kind = AttributeScopes.FoundationAttributes.LinkAttribute.self',
                'view.isAutomaticLinkDetectionEnabled = false || true', 'view.isAutomaticLinkDetectionEnabled = false ? a : b',
                'view.enabledTextCheckingTypes = NSTextCheckingResult.CheckingType.link.rawValue', 'view.checkTextInDocument(nil)',
                'NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)',
                'NSPerformService("Mail/Send Selection", board)']:
            # The rest of HelmUI opens files and help pages as before.
            self.expect('agent-ui-plain', code,
                        fails=(THREAD, 'Sources/HelmUI/Agent/AgentPanelView.swift', 'Sources/HelmUI/Agent/AgentPlanCard.swift',
                               'Sources/HelmUI/Host/AISearchRunner.swift', 'Sources/HelmUI/Host/AISearchPredicates.swift',
                               'Sources/HelmUI/Window/BrowserWindowController+AISearch.swift'),
                        passes=(HEADER, 'Sources/HelmUI/Host/ServerConnector.swift', WINDOW_AGENT))

    # What one file may say.

    def test_keychain_calls_stay_in_one_file(self):
        self.assertEqual(self.planted(KEYCHAIN, KEYCHAIN_CODE), [])
        # A key that syncs to other devices stays out, in this file too.
        self.fails('hand-off', KEYCHAIN, KEYCHAIN_CODE + 'let synced = kSecAttrSynchronizable')
        for code in ['SecItemCopyMatching(query as CFDictionary, &found)', 'SecItemAdd(query as CFDictionary, nil)',
                     'SecItemUpdate(query, change)', 'SecItemDelete(query)', 'let find = SecItemCopyMatching',
                     'SecKeychainFindGenericPassword(nil, 0, nil, 0, nil, nil, nil, nil)', '// SecItemAdd saves it',
                     'let name = "SecItemCopyMatching"']:
            self.expect('one-file', code, passes=[KEYCHAIN], fails=(
                'Sources/HelmAgent/Secrets/MemorySecretStore.swift', TRANSPORT, LOOP, 'Sources/HelmUI/Settings/AISetupModel.swift',
                'Sources/HelmApp/macOS/AppController+Agent.swift', 'Sources/HelmUI/Host/PermissionCenter.swift', CORE))
        # The rest of the Security framework is out of HelmAgent's reach, and Helm's own use of it is not.
        for code in ['SecTrustEvaluateWithError(trust, nil)', 'SecTrustSetAnchorCertificates(trust, anchors)',
                     'let trust: SecTrust? = space.serverTrust', 'let query = [kSecClass: kSecClassGenericPassword]',
                     'var code: SecCode?', 'SecRandomCopyBytes(nil, 16, &bytes)']:
            self.expect('one-file', code, fails=(TRANSPORT, LOOP, 'Sources/HelmAgent/Secrets/MemorySecretStore.swift'),
                        passes=(KEYCHAIN, 'Sources/HelmUI/Host/PermissionCenter.swift'))
        for code in ['import Security', 'let secrets: any AgentSecretStoring', 'let seconds = AgentLimits.diskSeconds',
                     'let id = AgentSecretID(provider: .claude, host: host, port: 443)', 'let part = Section.first']:
            self.passes('one-file', LOOP, code)

    def test_a_key_is_shown_in_three_files(self):
        for code in ['public func revealSecret() -> String { text }', 'let text = secret.revealSecret()',
                     'request.setValue(secret.revealSecret(), forHTTPHeaderField: name)',
                     'let show = AgentSecret.revealSecret', 'keys.map { $0.revealSecret() }',
                     'let text = secret . revealSecret ()', 'extension AgentSecret { var text: String { revealSecret() } }',
                     '// revealSecret is how a key is read', 'let name = "revealSecret"']:
            self.expect('one-file', code, passes=(SECRETS, KEYCHAIN, TRANSPORT), fails=(
                'Sources/HelmAgent/Secrets/MemorySecretStore.swift', 'Sources/HelmAgent/Runtime/AgentRuntime.swift',
                'Sources/HelmAgent/Providers/LiveModelClient.swift', 'Sources/HelmAgent/Contracts/AgentTransport.swift', LOOP,
                'Sources/HelmUI/Settings/AISetupModel.swift', PANEL_MODEL, 'Sources/HelmApp/macOS/HostSmokeDriver+AgentSetup.swift',
                CORE))

    def test_guarded_labels_fail_outside_their_files(self):
        # For each label: the call's arguments, the initializer by its full name, and its declaration.
        written = {
            'tickedByPerson': ('(tickedByPerson: ticked, planID: plan.id)', 'init(tickedByPerson:planID:)',
                               'fileprivate init(tickedByPerson ticked: Set<Int>, planID: UUID) {}'),
            'typedByPerson': ('(typedByPerson: text, selectedPaths: paths)', 'init(typedByPerson:selectedPaths:)',
                              'public init(typedByPerson text: String, selectedPaths: [String]) {}'),
            'fromPerson': ('(fromPerson: text, origin: .typed)', 'init(fromPerson:origin:)',
                           'public init(fromPerson text: String, origin: Origin) {}'),
            'liveProfile': ('(liveProfile: profile, secrets: secrets, limits: .cloud)', 'init(liveProfile:secrets:limits:)',
                            'public init(liveProfile profile: AgentProviderProfile, secrets: any AgentSecretStoring, '
                            'limits: AgentTransportLimits) {}'),
            'switchedOnByPerson': ('(switchedOnByPerson: .panel)', 'init(switchedOnByPerson:)',
                                   'public init(switchedOnByPerson origin: Origin) {}'),
        }
        self.assertEqual(set(written), {label for label, _, _ in GUARDED})
        # The files that declare the initializers, every file that may call one of them, and files that do neither.
        places = ['Sources/HelmAgent/Contracts/AgentSessionContracts.swift',
                  'Sources/HelmAgent/Contracts/AgentScopeContracts.swift', TRANSPORT, PLAN_CARD, PANEL_MODEL, WINDOW_AGENT,
                  LIVE_PARTS, LOOP,
                  'Sources/HelmAgent/Scripted/StandInConversation.swift', 'Sources/HelmAgent/Runtime/AgentRuntime.swift', THREAD,
                  'Sources/HelmUI/Agent/AgentPlanApplier.swift', 'Sources/HelmUI/Window/BrowserWindowController.swift',
                  'Sources/HelmApp/macOS/HostSmokeDriver+Agent.swift', CORE, 'App/main.swift', SEARCH_WINDOW, CONTENTS,
                  CONTENT_READER, 'Sources/HelmUI/Host/AISearchRunner.swift', 'Sources/HelmApp/macOS/AppController+Agent.swift']
        for label, kind, homes in GUARDED:
            arguments, full_name, declaration = written[label]
            self.assertTrue(homes < set(places), label)
            for code in [
                    f'let value = {kind}{arguments}',                                   # Type(label:)
                    f'let value = {kind}.init{arguments}',
                    f'send(.init{arguments})',                                          # .init(label:)
                    f'let value: {kind} = .init{arguments}',                            # the type left to inference
                    f'func make() -> {kind} {{ .init{arguments} }}',
                    f'let values: [{kind}] = [.init{arguments}]',
                    f'typealias Made = {kind}; let value = Made{arguments}',            # through an alias
                    'let value = ' + kind + arguments.replace(label + ':', label + ' :'),
                    'let value = ' + kind + arguments.replace(label + ':', '`' + label + '`:'),
                    'let value = ' + kind + arguments.replace(label + ': ', label + ':\n    '),
                    f'let make = {kind}.{full_name}',                                   # nothing called yet
                    f'let make = {kind}.init',                                          # and no label written at all
                    f'let made = pairs.map({kind}.init)',
                    f'let make = {kind}\n    .init',
                    f'let kind = {kind}.self',
                    f'typealias Made = {kind}',
                    f'typealias Made = HelmAgent.{kind}',
                    'let value = ' + kind + arguments.replace(label + ':', label + '/* */:'),  # a comment before the colon
                    'let value = ' + kind + arguments.replace(label + ':', label + ' /** a */ :'),
                    f'let text = "{label}:"']:                                         # a string counts too
                self.expect('one-file', code, fails=[place for place in places if place not in homes], passes=homes)
            # A comment counts too, except in the file that declares the initializer, which may say what the label is for.
            declared = DECLARED.get(label)
            for code in [f'// {kind}{arguments}', f'/// The label {label}: belongs to one file.',
                         f'/// Made only by `{kind}{full_name[4:]}`.', f'public struct {kind} {{  // the label {label}: is kept']:
                self.expect('one-file', code, fails=[place for place in places if place not in homes and place != declared],
                            passes=sorted(homes | {declared} - {None}))
            if declared:
                for code in [f'let text = "{label}:"', f'let value = {kind}{arguments}', f'let make = {kind}.init']:
                    self.fails('one-file', declared, code)
            # The declaration has no colon after the label, and the type's name alone is anyone's to use.
            for code in [declaration, f'var sent: [{kind}] = []; func take(_ value: {kind}?) {{}}',
                         f'let name = {label}; let other = {label}Text; let third = my{kind}.init']:
                self.expect('one-file', code, passes=places)

    def test_the_declaring_files_are_pinned(self):
        agent = 'Sources/HelmAgent/'
        self.assertEqual(DECLARED, {'fromPerson': agent + 'Contracts/AgentScopeContracts.swift',
                                    'typedByPerson': agent + 'Contracts/AgentSessionContracts.swift',
                                    'liveProfile': agent + 'Transport/HTTPTransport.swift',
                                    'switchedOnByPerson': 'Sources/HelmCore/Contracts/AgentContents.swift'})
        self.assertEqual(self.planted(DECLARED['switchedOnByPerson'], 'public struct AgentContentPermit: Hashable {  '
                                      '// the label switchedOnByPerson: is allowed only in the two switches\n'
                                      '    public init(switchedOnByPerson origin: Origin) {}\n}'), [])
        # The comments the declarations carry pass there.
        self.assertEqual(self.planted(DECLARED['fromPerson'], 'public struct AgentRootInput: Sendable {  '
                                      '// the label fromPerson: is allowed only in AgentPanelModel.swift\n'
                                      '    public init(fromPerson text: String, origin: Origin) {}\n}'), [])
        self.assertEqual(self.planted(DECLARED['typedByPerson'], 'public struct AgentPersonInput: Sendable {  '
                                      '// the label typedByPerson: is allowed only in AgentPanelModel.swift\n'
                                      '    public init(typedByPerson text: String, selectedPaths: [String]) {}\n}'), [])
        self.assertEqual(self.planted(TRANSPORT, TRANSPORT_CODE + '// the label liveProfile: is allowed only in '
                                      'Runtime/AgentLiveParts.swift'), [])

    def test_only_the_transport_hands_a_session_its_own_loader(self):
        for code in ['configuration.protocolClasses = loaders', 'configuration.protocolClasses?.insert(loader, at: 0)',
                     'let path = \\URLSessionConfiguration.protocolClasses',
                     'configuration.setValue(loaders, forKey: "protocolClasses")',
                     '// protocolClasses is how a test stands in']:
            self.expect('one-file', code, passes=[TRANSPORT],
                        fails=(LIVE_PARTS, LOOP, 'Sources/HelmAgent/Transport/SSELineReader.swift', THREAD, CORE))

    # Paths from the Mac that built it.

    def test_only_one_file_looks_inside_files(self):
        # The frameworks that read inside files, and their reading types, however they arrive: by their own import or
        # through an umbrella such as Quartz.
        for code in ['import PDFKit', 'import Vision', '@preconcurrency import AVFoundation', 'import AVKit', 'import Speech',
                     'import VisionKit', 'internal import Vision',
                     'import Quartz\nlet document = PDFDocument(data: data)', 'let text = page.string; let page: PDFPage? = nil',
                     'let handler = VNImageRequestHandler(url: url)', 'let request = VNRecognizeTextRequest()',
                     'let labels = VNClassifyImageRequest()', 'let asset = AVURLAsset(url: url)',
                     'let frames = AVAssetImageGenerator(asset: asset)', 'let reader = try AVAssetReader(asset: asset)',
                     'let speech = SFSpeechRecognizer()', 'typealias Page = PDFPage']:
            self.expect('content-read', code,
                        fails=(LOOP, RUNNER, 'Sources/HelmAgent/Scripted/MemoryAgentDisk.swift', CONTENT_READER,
                               'Sources/HelmUI/Host/AISearchRunner.swift', 'Sources/HelmUI/Window/BrowserWindowController.swift',
                               'Sources/HelmFileSystem/Agent/FileSystemAgentDisk.swift', CONTENTS, CORE,
                               'Sources/HelmApp/macOS/HostSmokeDriver.swift', THREAD),
                        passes=sorted(CONTENT_FILES))
        # Words that only look like them.
        for code in ['let vision = "Read contents"', 'let pdf = AISearchKind.pdf', 'import Quartz', 'let assets = 2',
                     '// Vision reads it on this Mac']:
            self.expect('content-read', code, passes=(LOOP, CONTENT_READER, HEADER, CORE))

    def test_helm_agent_still_cant_open_a_file_to_read_its_contents(self):
        # What a read_contents written inside AI mode's own module would need. Each way fails there by more than one
        # rule, and the module can't import a framework that would do it.
        for code, expected in [
                ('let text = try String(contentsOfFile: path, encoding: .utf8)', {'agent-no-read'}),
                ('let handle = FileHandle(forReadingAtPath: path)', {'agent-no-write'}),
                ('let data = try Data(contentsOf: URL(fileURLWithPath: path))', {'read-url'}),
                ('let fd = open(path, O_RDONLY); _ = read(fd, &buffer, 4096)', {'agent-no-read'}),
                ('import PDFKit\nlet document = PDFDocument(url: URL(fileURLWithPath: path))', {'agent-no-write', 'content-read'}),
                ('import Vision\nlet handler = VNImageRequestHandler(url: url)', {'agent-no-write', 'content-read'}),
                ('import AVFoundation\nlet asset = AVURLAsset(url: url)', {'agent-no-write', 'content-read'}),
                ('let summary = AgentContentExtractor.summary(of: request, deadline: .now())', {'content-read'}),
                ('let file = AgentContentFile.open(request)', {'content-read'})]:
            for place in (LOOP, RUNNER, 'Sources/HelmAgent/Search/AISearchSession.swift'):
                found = rules(self.planted(place, code))
                self.assertTrue(expected <= found, f'{place}: {code}: {found}')
        # Asking for summaries through the protocol, with a permit it was handed, names nothing that opens a file.
        self.assertEqual(self.planted(RUNNER, 'let found = await reading.reader.summaries(of: requests, '
                                      'permit: reading.permit, seconds: seconds)'), [])

    def test_with_the_switch_off_nothing_can_read(self):
        # Reading takes a permit, and only the two switches may make one: not the conversation, not the tool runner,
        # not the search runner, not the app's wiring nor a smoke step.
        make = 'let permit = AgentContentPermit(switchedOnByPerson: .panel)'
        self.expect('one-file', make,
                    fails=(LOOP, RUNNER, 'Sources/HelmUI/Host/AISearchRunner.swift', CONTENT_READER, EXTRACTOR,
                           'Sources/HelmApp/macOS/AppController+Agent.swift', 'Sources/HelmApp/macOS/HostSmokeDriver+Agent.swift',
                           'Sources/HelmAgent/Scripted/StandInConversation.swift', CORE),
                    passes=(PANEL_MODEL, SEARCH_WINDOW))
        for code in ['let permit: AgentContentPermit = .init(switchedOnByPerson: .search)',
                     'let make = AgentContentPermit.init', 'typealias Pass = AgentContentPermit']:
            self.expect('one-file', code, fails=(LOOP, RUNNER, 'Sources/HelmUI/Host/AISearchRunner.swift'),
                        passes=(PANEL_MODEL, SEARCH_WINDOW))
        # The file that looks inside files is called only by the reader, which takes the permit.
        for code in ['let summary = AgentContentExtractor.summary(of: request, deadline: deadline)',
                     'let file = AgentContentFile.open(request)', 'let bytes = AgentContentVideoBytes(file: file, contentType: kind)']:
            self.expect('content-read', code,
                        fails=('Sources/HelmUI/Host/AISearchRunner.swift', PANEL_MODEL, SEARCH_WINDOW, LOOP, CORE,
                               'Sources/HelmApp/macOS/AppController+Agent.swift'),
                        passes=(CONTENT_READER, EXTRACTOR))

    def test_rich_text_is_never_read_as_html_or_a_web_archive(self):
        # The two types that load what they link to, however they are named, anywhere under Sources.
        for code in ['let options = [NSAttributedString.DocumentReadingOptionKey.documentType: '
                     'NSAttributedString.DocumentType.html]',
                     'let read = try NSAttributedString(data: data, options: [.documentType: .html], documentAttributes: nil)',
                     'let kind = NSAttributedString.DocumentType.webArchive',
                     'let kind: NSAttributedString.DocumentType = .webArchive',
                     'options[.documentType] = DocumentType . html', 'let read = [.documentType: .`html`]',
                     'let kind = NSHTMLTextDocumentType', 'let kind = NSWebArchiveTextDocumentType',
                     'let kind = NSAttributedString.DocumentType(rawValue: "NSHTML")', 'let kind = DocumentType("NSWebArchive")',
                     'let kind = NSAttributedString.DocumentType.init(rawValue: name)', 'let raw = "NSHTML"',
                     'let raw = "NSWebArchive"', '// Read as DocumentType.html when the bytes are a web page',
                     'case "webarchive": return .webArchive']:
            self.expect('html-document', code, fails=(CORE, HEADER, LOOP, EXTRACTOR, CONTENT_READER,
                                                      'Sources/HelmUI/Host/AgentNewFileContents.swift'))
        # In the file that reads documents, `.html` with its type left out, and a type made from a raw value, too.
        # In the file that reads documents, `.html` with its type left out, and a type made from a raw value, too. That
        # file has no use for the HTML file type either.
        for code in ['case "htm": return .html', 'let kind: NSAttributedString.DocumentType = .init(rawValue: ext)',
                     'let kind = UTType.html']:
            self.expect('html-document', code, fails=[EXTRACTOR], passes=(CORE, HEADER))
        # What only looks like them.
        for code in ['let types = ["public.html", "public.css"]', '// never read as HTML',
                     'let kind = NSAttributedString.DocumentType.officeOpenXML', 'case "rtf": return .rtf',
                     'let documents = bundle?.object(forInfoDictionaryKey: "CFBundleDocumentTypes")',
                     'let archive = "a web archive"', 'let html = page.htmlString', 'let status = Status(rawValue: raw)']:
            self.expect('html-document', code, passes=(CORE, HEADER, EXTRACTOR))

    def test_the_reader_names_the_type_of_each_document_it_reads(self):
        # An attributed string made from bytes with no type would have macOS guess it, HTML included.
        for code in ['let read = try NSAttributedString(data: data, options: [:], documentAttributes: nil)',
                     'let read = try NSAttributedString(data: data, options: options, documentAttributes: nil)',
                     'let read = try NSAttributedString.init(data: data, options: [.characterEncoding: 4], '
                     'documentAttributes: nil)',
                     'let read: NSAttributedString = try .init(data: data, options: [:], documentAttributes: nil)',
                     'try NSMutableAttributedString().read(from: data, options: [:], documentAttributes: nil)',
                     'let read = try NSAttributedString(\n    data: data,\n    options: [:],\n    documentAttributes: nil)',
                     'let read = try NSAttributedString(data: data, options: [/* .documentType: */ :], '
                     'documentAttributes: nil)',
                     'let read = try NSAttributedString(data: data, options: ["documentType": kind], '
                     'documentAttributes: nil)']:
            self.expect('html-document', code, fails=[EXTRACTOR], passes=(CORE, CONTENT_READER))
        for code in ['let read = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)',
                     'let read = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], '
                     'documentAttributes: nil)',
                     'let read = try NSAttributedString(\n    data: data,\n    options: [\n        .documentType: type\n    ],\n'
                     '    documentAttributes: nil)',
                     'let read = try NSAttributedString(rtf: data, documentAttributes: nil)',
                     'let text = NSAttributedString(string: words)', '// NSAttributedString(data:) with no type guesses it',
                     'let handler = VNImageRequestHandler(data: data, options: [:])',
                     'let image = CGImageSourceCreateWithData(data as CFData, nil)']:
            self.expect('html-document', code, passes=(EXTRACTOR, CORE))
        # The extractor as it is written.
        extractor = Path(__file__).resolve().parent.parent / EXTRACTOR
        self.assertNotIn('html-document', rules(self.planted(EXTRACTOR, extractor.read_text())))

    def test_build_paths_fail_in_strings_under_sources(self):
        for code in ['let home = "/Users/me/Documents"', 'let shared = "/Users/Shared"', 'let prefix = "/Users/"',
                     'let temporary = "/private/var/folders/zz/T/helm"', 'let build = "/tmp/DerivedData/Helm-abc/Build"',
                     'let home = #"/Users/me"#', 'let home = ##"C:\\Users /Users/me"##',
                     'let home = """\n    /Users/me/Documents\n    """',
                     'let home = "\\(name) lives in /Users/\\(name)"', 'let home = "\\(pick("/Users/me"))"',
                     'let home = "a \\"quoted\\" /Users/me"', 'let both = "a//b /Users/me"',
                     'let both = "/* not a comment */ /Users/me"',
                     'let odd = "x" // it\'s "odd\nlet home = "/Users/me"', 'let mark = #/"/#; let home = "/Users/me"',
                     'f("/var/folders/x", "y")', 'let home = URL(fileURLWithPath: "/Users/me")',
                     'let home = "/\\u{55}sers/me"', 'let home = "\\u{2F}Users\\u{002f}me"', 'let built = #filePath',
                     'let built = #file', 'f(path: #filePath)']:
            self.expect('build-path', code, fails=(CORE, LOOP, HEADER, 'Sources/HelmApp/AppEnvironment.swift',
                                                   'Sources/Helm/main.swift'))
        for code in ['// Not from `/Users/you`.', '/// `file:///Users/me/My%20Files` becomes `/Users/me/My Files`.',
                     '/* "/Users/me" is in a comment */', '/* a /* nested "/Users/me" */ comment */',
                     'let home = "/home/helm"', 'let parts = ["Users", "Shared"]', 'let users = "Users/"; let root = "/"',
                     'let name = "x" // then "/Users/me" in a comment', 'let folders = "var/folders"; let data = "DerivedData"',
                     'let ratio = a /Users/ b', 'let text = "\\(count /* "/Users/me" */)"',
                     'let mark = #/"/Users/me/#; let home = "Home"', 'let id = #fileID', 'let line = #line',
                     'let escaped = "\\u{55}sers"', '// #filePath is where it was built']:
            self.expect('build-path', code, passes=(CORE, LOOP, HEADER))
        # The rule reads Sources/ alone.
        self.expect('build-path', 'let home = "/Users/me/Documents"', passes=('App/main.swift', 'Package.swift'))

    def test_layers_tell_code_from_strings_and_comments(self):
        # Each case is the text, its code and its strings, one under the other.
        for text, code, strings in [
                ('let a = "b c" // d "e"\nf()',
                 'let a = "   "         \nf()',
                 '         b c          \n   '),
                ('a /* b /* "c" */ d */ e',
                 'a                     e',
                 '                       '),
                ('let a = "b//c" + "/*d*/"',
                 'let a = "    " + "     "',
                 '         b//c     /*d*/ '),
                ('let a = "b \\(c("d", e)) f"',
                 'let a = "  \\(c(" ", e))  "',
                 '         b      d       f '),
                ('let a = "\\(b + "\\(c)")"; "d"',
                 'let a = "\\(b + "\\(c)")"; " "',
                 '                          d '),
                ('let a = "b \\" c"; d()',
                 'let a = "      "; d()',
                 '         b \\" c      '),
                ('let a = #"b " \\(c) "#; d()',
                 'let a = #"         "#; d()',
                 '          b " \\(c)        '),
                ('let a = #"b \\#(c) d"#',
                 'let a = #"  \\#(c)  "#',
                 '          b       d  '),
                ('let a = """\n  b "c" d\n  """; e()',
                 'let a = """\n         \n  """; e()',
                 '           \n  b "c" d\n          '),
                # A one-line string that never closes ends with its line.
                ('let a = "b\nc()',
                 'let a = " \nc()',
                 '         b\n   '),
                # A quote inside a regular expression opens no string.
                ('let a = #/"/# + b // c',
                 'let a =       + b     ',
                 '                      '),
                ('a("\\((b))") /* c',
                 'a("\\((b))")     ',
                 '                ')]:
            self.assertEqual(layers(text), (code, strings), text)

    # App Transport Security.

    def test_transport_security_has_two_shapes(self):
        def plist(body):
            return {'App/Info.plist': '<?xml version="1.0" encoding="UTF-8"?>\n' + DTD + '<plist version="1.0">\n<dict>\n'
                    '\t<key>CFBundleName</key>\n\t<string>$(PRODUCT_NAME)</string>\n' + body + '</dict>\n</plist>\n'}
        key = '\t<key>NSAppTransportSecurity</key>\n'
        local = '\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n'
        allowed = key + '\t<dict>\n' + local + '\t</dict>\n'
        # No key, or the key with local networking alone.
        self.assertEqual(self.problems(plist('')), [])
        self.assertEqual(self.problems(plist(allowed)), [])
        self.assertEqual(self.problems(plist(allowed.replace('\t', '    '))), [])
        self.assertEqual(self.run_check(plist(allowed))[2], self.run_check(plist(''))[2])
        for body in [
                key + '\t<dict>\n\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t</dict>\n',
                key + '\t<dict>\n' + local + '\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t</dict>\n',
                key + '\t<dict>\n' + local + '\t\t<key>NSExceptionDomains</key>\n\t\t<dict/>\n\t</dict>\n',
                key + '\t<dict>\n' + local + '\t\t<key>NSAllowsArbitraryLoadsInWebContent</key>\n\t\t<false/>\n\t</dict>\n',
                key + '\t<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<false/>\n\t</dict>\n',
                key + '\t<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<integer>1</integer>\n\t</dict>\n',
                key + '\t<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<string>YES</string>\n\t</dict>\n',
                key + '\t<dict/>\n', key + '\t<true/>\n',
                key + '\t<array>\n\t\t<string>NSAllowsLocalNetworking</string>\n\t</array>\n',
                key + '\t<dict>\n\t\t<key>NSExceptionDomains</key>\n\t\t<dict/>\n\t</dict>\n' + allowed,
                allowed + allowed,
                allowed + '\t<!-- NSAppTransportSecurity -->\n',
                '\t<key>Other</key>\n\t<dict>\n' + allowed + '\t</dict>\n',
                '\t<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>\n',
                '\t<key>NSAppTransportSecurity</key> <!-- local models -->\n\t<dict>\n' + local + '\t</dict>\n',
                '\t<key>NSAllowsArbitraryLoads</key>\n\t<true/>\n',
                allowed + '</dict>\n<dict>\n',
                # Character references and CDATA a property list reader reads as the key's name.
                '\t<key>NSAppTransport&#83;ecurity</key>\n\t<dict>\n\t\t<key>NSAllowsArbitrary&#76;oads</key>\n\t\t<true/>\n'
                '\t</dict>\n',
                '\t<key>NSAppTransport&#x53;ecurity</key>\n\t<dict>\n' + local + '\t</dict>\n',
                '\t<key><![CDATA[NSAppTransportSecurity]]></key>\n\t<dict>\n' + local + '\t</dict>\n',
                key + '\t<dict>\n' + local + '\t\t<key>NSAllowsArbitrary&#76;oads</key>\n\t\t<true/>\n\t</dict>\n',
                '\t<key>NSAppTransport&#83;ecurity</key>\n\t<dict>\n\t\t<key>NSExceptionDomains</key>\n\t\t<dict/>\n'
                '\t</dict>\n' + allowed,
                allowed + '\t<key>NSAppTransport&#83;ecurity</key>\n\t<dict>\n' + local + '\t</dict>\n',
                '\t<key>CFBundle&#85;RLTypes</key>\n\t<array/>\n']:
            self.assertEqual(rules(self.problems(plist(body))), {'network-key'}, body)
        for relative, text in [('App/Helm.entitlements', DTD + '<plist version="1.0">\n<dict>\n'
                                '\t<key>com.apple.security.network.&#99;lient</key>\n\t<true/>\n</dict>\n</plist>\n'),
                               ('App/Other.plist', DTD + '<plist version="1.0">\n<dict>\n\t<key>Inner</key>\n\t<dict>\n'
                                '\t\t<key>NSBonjour&#83;ervices</key>\n\t\t<array/>\n\t</dict>\n</dict>\n</plist>\n')]:
            self.assertEqual(rules(self.problems({relative: text})), {'network-key'}, relative)
        # The key belongs to Info.plist alone.
        for relative in ('App/Helm.entitlements', 'App/Other.plist', 'App/Resources/Info.plist'):
            self.assertEqual(rules(self.problems({relative: plist(allowed)['App/Info.plist']})), {'network-key'}, relative)
        self.assertEqual(rules(self.problems({'App/project.yml': 'info:\n  properties:\n    NSAppTransportSecurity:\n'
                                              '      NSAllowsLocalNetworking: true\n'})), {'network-key'})


if __name__ == '__main__':
    unittest.main()
