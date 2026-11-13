// The transport to the chosen model provider: the only file in Helm that may make a network connection.
import Foundation

/// Sends requests to one provider. Where a request goes is the profile's endpoint and the route's fixed path; a
/// caller gives a route and a body, and never an address or a header. The key is looked up in `secrets` under the
/// profile's own account when a request is sent.
///
/// The first label of the initializers is `liveProfile`, and the privacy check lets one file write it, so a
/// transport can't be made anywhere else.
///
/// What it holds to:
/// - One ephemeral session that keeps no cache, no cookies and no credentials. A model on this Mac is reached with
///   an empty proxy dictionary, so a web proxy set for the whole system never carries a local request.
/// - Every redirect is refused and is an error. A server's certificate is judged by macOS as for any app, and every
///   other question a server or a proxy asks is cancelled.
/// - A reply is read only when it comes from the endpoint's own host.
/// - The key is read the first time a request needs it, off the main thread, and kept until `shutdown()`. It is put
///   on a request in `sign` alone, in a header, and never on plain http unless it is a local server's own token. A
///   body that holds the key is never sent.
/// - A line may hold `limits.lineBytes`, a streamed reply `limits.responseBytes` and a fetched one
///   `limits.listBytes`; past a limit the request is cancelled. A request ends when nothing has arrived for
///   `limits.idleSeconds`, and after `limits.totalSeconds` in all.
/// - A request that was turned away for a while, or that heard nothing, is tried again at most `limits.retries`
///   times, and only before any of its reply was handed on.
public final class HTTPTransport: AgentTransport, @unchecked Sendable {
    private let profile: AgentProviderProfile
    private let secrets: any AgentSecretStoring
    private let limits: AgentTransportLimits
    private let session: URLSession

    // All of these hold the lock.
    private let lock = NSLock()
    private var cachedSecret: AgentSecret?
    private var isShut = false
    private var isClosed = false
    private var running: [UInt64: @Sendable () -> Void] = [:]
    private var lastTicket: UInt64 = 0

    public init(liveProfile profile: AgentProviderProfile, secrets: any AgentSecretStoring, limits: AgentTransportLimits) {
        self.profile = profile; self.secrets = secrets; self.limits = limits
        self.session = Self.makeSession(profile: profile, limits: limits, testProtocols: [])
    }

    /// For tests, which stand loaders of their own in for the network. Nothing else can carry a request then.
    init(liveProfile profile: AgentProviderProfile, secrets: any AgentSecretStoring, limits: AgentTransportLimits,
         testProtocols: [AnyClass]) {
        self.profile = profile; self.secrets = secrets; self.limits = limits
        self.session = Self.makeSession(profile: profile, limits: limits, testProtocols: testProtocols)
    }

    // MARK: AgentTransport

    public func stream(_ route: AgentRoute, body: Data) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await self.tracked { try await self.streamLines(route, body: body) { continuation.yield($0) } }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.transportError(error))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    public func fetch(_ route: AgentRoute) async throws -> AgentHTTPReply {
        do {
            return try await tracked { try await self.fetchReply(route) }
        } catch let Hitch.rejected(status, body, _) {
            return AgentHTTPReply(status: status, body: body)
        } catch {
            throw Self.transportError(error)
        }
    }

    /// Cancels every request, forgets the key and closes the session. Requests made afterwards throw `.cancelled`.
    public func shutdown() async {
        refuseRequests()
    }

    /// What `shutdown()` does, done at once by a caller that can't wait for it.
    public func refuseRequests() {
        let (cancels, closeNow) = locked { () -> ([@Sendable () -> Void], Bool) in
            isShut = true
            cachedSecret = nil
            let closeNow = running.isEmpty && !isClosed
            if closeNow { isClosed = true }
            return (Array(running.values), closeNow)
        }
        cancels.forEach { $0() }
        if closeNow { session.invalidateAndCancel() }
    }

    /// The session's settings, for tests.
    var sessionConfiguration: URLSessionConfiguration { session.configuration }

    // MARK: The session

    private static let plainScheme = "http"
    private static let securePort = 443

    private static func makeSession(profile: AgentProviderProfile, limits: AgentTransportLimits,
                                    testProtocols: [AnyClass]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = limits.idleSeconds
        configuration.timeoutIntervalForResource = limits.totalSeconds
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        // Said outright, so the provider isn't told the system's version or the person's languages.
        configuration.httpAdditionalHeaders = ["User-Agent": "Helm", "Accept-Language": "en"]
        if profile.endpoint.isLoopback { configuration.connectionProxyDictionary = [:] }
        if !testProtocols.isEmpty { configuration.protocolClasses = testProtocols }
        return URLSession(configuration: configuration, delegate: Gate(), delegateQueue: nil)
    }

    /// Runs `work` as a task that `shutdown()` can cancel. The session is closed only once no such task is left, so
    /// no request is ever made on a closed session.
    private func tracked<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let ticket = try locked { () throws -> UInt64 in
            guard !isShut else { throw AgentTransportError.cancelled }
            lastTicket += 1
            running[lastTicket] = {}
            return lastTicket
        }
        defer { release(ticket) }
        let task = Task { try await work() }
        let shut = locked { () -> Bool in
            if !isShut { running[ticket] = { task.cancel() } }
            return isShut
        }
        if shut { task.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func release(_ ticket: UInt64) {
        let closeNow = locked { () -> Bool in
            running[ticket] = nil
            guard isShut, running.isEmpty, !isClosed else { return false }
            isClosed = true
            return true
        }
        if closeNow { session.invalidateAndCancel() }
    }

    // MARK: Requests

    private func spec(_ route: AgentRoute) throws -> AgentRouteSpec {
        guard let spec = AgentProviderCatalog.route(route, for: profile) else { throw AgentTransportError.unreachable }
        return spec
    }

    private func streamLines(_ route: AgentRoute, body: Data, emit: @escaping @Sendable (String) -> Void) async throws {
        let spec = try spec(route)
        let limits = self.limits
        let deadline = Self.deadline(after: limits.totalSeconds)
        try await withRetries(until: deadline) { handedOn in
            try await self.exchange(spec, body: body, accept: "text/event-stream", deadline: deadline) { bytes, response, watch in
                guard (200..<300).contains(response.statusCode) else {
                    let text = try await Self.collect(bytes, cap: limits.listBytes, watch: watch, cutsShort: true)
                    throw Hitch.rejected(status: response.statusCode, body: text, retryAfter: Self.retryAfter(response))
                }
                var reader = SSELineReader(lineCap: limits.lineBytes)
                var total = 0
                var sinceTouch = 0
                for try await byte in bytes {
                    total += 1
                    guard total <= limits.responseBytes else { throw AgentTransportError.tooLarge }
                    sinceTouch += 1
                    if sinceTouch >= Self.touchEvery { watch.touch(); sinceTouch = 0 }
                    let line: String?
                    do { line = try reader.take(byte) } catch { throw AgentTransportError.tooLarge }
                    if let line {
                        // A line, however short, is something heard, so a stream of small pieces isn't taken for
                        // silence.
                        watch.touch()
                        handedOn.raise()
                        emit(line)
                    }
                }
                if let last = reader.finish() {
                    handedOn.raise()
                    emit(last)
                }
            }
        }
    }

    /// The whole reply to a GET. A status that may be tried again throws, so `fetch` can answer it once tries run out.
    private func fetchReply(_ route: AgentRoute) async throws -> AgentHTTPReply {
        let spec = try spec(route)
        let limits = self.limits
        let deadline = Self.deadline(after: limits.totalSeconds)
        return try await withRetries(until: deadline) { _ in
            try await self.exchange(spec, body: nil, accept: "application/json", deadline: deadline) { bytes, response, watch in
                let status = response.statusCode
                let fine = (200..<300).contains(status)
                let body = try await Self.collect(bytes, cap: limits.listBytes, watch: watch, cutsShort: !fine)
                if Self.retriedStatuses.contains(status) {
                    throw Hitch.rejected(status: status, body: body, retryAfter: Self.retryAfter(response))
                }
                return AgentHTTPReply(status: status, body: body)
            }
        }
    }

    /// One request, with its time limits kept by a watch that runs beside it. The reply is checked before `consume`
    /// sees a byte of its body: a redirect and a reply from another host are errors.
    private func exchange<Value: Sendable>(
        _ spec: AgentRouteSpec, body: Data?, accept: String, deadline: UInt64,
        consume: @escaping @Sendable (URLSession.AsyncBytes, HTTPURLResponse, Watch) async throws -> Value
    ) async throws -> Value {
        let request = try await makeRequest(spec, body: body, accept: accept)
        let watch = Watch(limits: limits, deadline: deadline)
        let endpoint = profile.endpoint
        let session = self.session
        do {
            return try await withThrowingTaskGroup(of: Value?.self) { group in
                group.addTask {
                    // Nothing goes out once the transport is shut down or the request is stopped, even when the
                    // key was being read meanwhile.
                    try self.ensureOpen()
                    let (bytes, response) = try await session.bytes(for: request, delegate: watch)
                    watch.touch()
                    guard let reply = response as? HTTPURLResponse else { throw AgentTransportError.unreachable }
                    if watch.wasRedirected || (300..<400).contains(reply.statusCode) {
                        throw AgentTransportError.redirected
                    }
                    guard reply.url?.host?.lowercased() == endpoint.host else { throw AgentTransportError.wrongHost }
                    return try await consume(bytes, reply, watch)
                }
                group.addTask {
                    try await watch.keepTime()
                    return nil
                }
                guard let first = try await group.next(), let value = first else { throw AgentTransportError.cancelled }
                group.cancelAll()
                return value
            }
        } catch {
            throw watch.verdict(on: error, loopback: endpoint.isLoopback)
        }
    }

    private func makeRequest(_ spec: AgentRouteSpec, body: Data?, accept: String) async throws -> URLRequest {
        let endpoint = profile.endpoint
        var parts = URLComponents()
        parts.scheme = endpoint.isSecure ? AgentProviderCatalog.secureScheme : Self.plainScheme
        parts.host = endpoint.host
        if !(endpoint.isSecure && endpoint.port == Self.securePort) { parts.port = endpoint.port }
        parts.path = endpoint.basePath + spec.path
        if !spec.query.isEmpty {
            parts.queryItems = spec.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let address = parts.url else { throw AgentTransportError.unreachable }
        var request = URLRequest(url: address)
        request.httpMethod = spec.method
        request.timeoutInterval = limits.idleSeconds
        for (name, value) in AgentProviderCatalog.fixedHeaders(for: profile).sorted(by: { $0.key < $1.key }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard spec.auth != .none else { return request }
        // Checked before the key is looked up, so a key that may not go here is never even read.
        guard Self.mayCarryKey(profile) || !profile.needsKey else { throw AgentTransportError.insecure }
        let secret = try await key()
        // Reading the key can wait on macOS's keychain question: AI mode may have been turned off meanwhile.
        try ensureOpen()
        try Self.sign(&request, style: spec.auth, secret: secret, body: body, profile: profile)
        return request
    }

    /// Throws `.cancelled` once the transport is shut down or the request has been stopped.
    private func ensureOpen() throws {
        if Task.isCancelled { throw AgentTransportError.cancelled }
        try locked { if isShut { throw AgentTransportError.cancelled } }
    }

    // MARK: The key

    /// The profile's key: the one already read, or the store's, read off the main thread since macOS may ask the
    /// person for their keychain password. Nil when none is saved, which is asked first, without asking for the key.
    private func key() async throws -> AgentSecret? {
        if let cached = locked({ cachedSecret }) { return cached }
        let id = profile.secretID
        let store = secrets
        let found: AgentSecret? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard store.has(id) else { return continuation.resume(returning: nil) }
                    continuation.resume(returning: try store.secret(for: id))
                } catch AgentSecretError.denied {
                    continuation.resume(throwing: AgentTransportError.keyDenied)
                } catch {
                    continuation.resume(throwing: AgentTransportError.noKey)
                }
            }
        }
        if let found { locked { if !isShut { cachedSecret = found } } }
        return found
    }

    /// Whether a key may go to this profile's endpoint: https, or this Mac with a local provider's own token.
    private static func mayCarryKey(_ profile: AgentProviderProfile) -> Bool {
        profile.endpoint.isSecure || (profile.endpoint.isLoopback && profile.isLocal)
    }

    /// The one place a key is put on a request, in the header `style` names. A provider that needs a key has none to
    /// go without. A request whose `body` holds the key, as written or as JSON writes it, is refused.
    private static func sign(_ request: inout URLRequest, style: AgentAuthStyle, secret: AgentSecret?, body: Data?,
                             profile: AgentProviderProfile) throws {
        guard style != .none else { return }
        guard let secret else {
            if profile.needsKey { throw AgentTransportError.noKey }
            return
        }
        guard mayCarryKey(profile) else { throw AgentTransportError.insecure }
        let text = secret.revealSecret()
        if let body, holds(body, text) { throw AgentTransportError.keyInBody }
        switch style {
        case .xAPIKey: request.setValue(text, forHTTPHeaderField: "x-api-key")
        case .bearer: request.setValue("Bearer " + text, forHTTPHeaderField: "Authorization")
        case .googAPIKey: request.setValue(text, forHTTPHeaderField: "x-goog-api-key")
        case .none: return
        }
    }

    private static func holds(_ body: Data, _ text: String) -> Bool {
        var escaped = ""
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "/": escaped += "\\/"
            default: escaped.append(character)
            }
        }
        return body.range(of: Data(text.utf8)) != nil || body.range(of: Data(escaped.utf8)) != nil
    }

    // MARK: Trying again

    /// Turned away for a while: too many requests, the service overloaded or unavailable, or a gateway that gave up.
    private static let retriedStatuses: Set<Int> = [429, 503, 504, 529]
    /// Words in a reply that mean a spending or credit limit was reached, which waiting won't fix.
    /// The same words the error mapper reads as out of credit.
    private static let spendingWords = ["spend_limit", "insufficient_quota", "credit_balance", "usage_limit", "billing",
                                        "spend limit", "credit balance"]
    /// The longest wait a server may ask for before a try; one that asks for more isn't tried again.
    private static let longestWait = 30.0
    /// How many bytes may arrive between two notes to the watch that something arrived.
    private static let touchEvery = 1_024

    /// Runs `body`, and again after a hitch that may be tried again, while the whole request's `deadline` allows: a
    /// wait that would end past it isn't made, and the hitch stands as the answer.
    private func withRetries<Value>(until deadline: UInt64, _ body: (Flag) async throws -> Value) async throws -> Value {
        var tries = 0
        while true {
            let handedOn = Flag()
            do {
                return try await body(handedOn)
            } catch {
                guard !handedOn.isRaised, tries < limits.retries, let wait = Self.wait(after: error, tries: tries) else {
                    throw error
                }
                guard Self.deadline(after: wait) < deadline else { throw error }
                tries += 1
                try await Task.sleep(nanoseconds: Self.nanoseconds(wait))
            }
        }
    }

    /// The uptime, in nanoseconds, `seconds` from now.
    private static func deadline(after seconds: Double) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ nanoseconds(seconds)
    }

    /// How long to wait before trying again after `error`, or nil when it isn't tried again.
    private static func wait(after error: Error, tries: Int) -> Double? {
        guard let hitch = error as? Hitch else { return nil }
        switch hitch {
        case .quiet:
            return backoff(tries)
        case let .rejected(status, body, retryAfter):
            guard retriedStatuses.contains(status) else { return nil }
            let text = String(decoding: body, as: UTF8.self).lowercased()
            guard !spendingWords.contains(where: text.contains) else { return nil }
            guard let retryAfter else { return backoff(tries) }
            return retryAfter <= longestWait ? retryAfter : nil
        }
    }

    private static func backoff(_ tries: Int) -> Double { Double(tries + 1) }

    /// The `Retry-After` header in seconds. A date or anything else is left out.
    private static func retryAfter(_ response: HTTPURLResponse) -> Double? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(text.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return seconds
    }

    // MARK: Reading

    /// The reply's body. Past `cap` bytes it is cut at `cap` when `cutsShort`, and is too large otherwise.
    private static func collect(_ bytes: URLSession.AsyncBytes, cap: Int, watch: Watch, cutsShort: Bool) async throws -> Data {
        var data = Data()
        var sinceTouch = 0
        for try await byte in bytes {
            guard data.count < cap else {
                if cutsShort { break }
                throw AgentTransportError.tooLarge
            }
            data.append(byte)
            sinceTouch += 1
            if sinceTouch >= touchEvery { watch.touch(); sinceTouch = 0 }
        }
        return data
    }

    /// Every error a caller sees is an `AgentTransportError`.
    private static func transportError(_ error: Error) -> AgentTransportError {
        switch error {
        case let failure as AgentTransportError: return failure
        case let hitch as Hitch:
            switch hitch {
            case .quiet: return .timedOut
            case let .rejected(status, body, _): return .http(status: status, body: body)
            }
        case is CancellationError: return .cancelled
        default: return .unreachable
        }
    }

    private static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(0, min(seconds, 86_400)) * 1_000_000_000)
    }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Pieces

    /// What may end in another try: a status that says to wait, and silence.
    private enum Hitch: Error {
        case rejected(status: Int, body: Data, retryAfter: Double?)
        /// Nothing arrived for the idle limit.
        case quiet
    }

    /// Set once part of a reply has been handed on, after which a request is never tried again.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// How a server's questions are answered: its certificate is judged by macOS's own rules, and anything else, a
    /// password for the server or for a proxy included, is cancelled.
    private static func answer(_ challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge
    }

    /// The session's own delegate, for whatever reaches the session rather than a request's watch.
    private final class Gate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(HTTPTransport.answer(challenge), nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(HTTPTransport.answer(challenge), nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// One request's delegate and clock. It refuses redirects and questions as the gate does and notes them, and
    /// keeps the idle and total limits.
    private final class Watch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let idle: UInt64
        private let started: UInt64
        private let deadline: UInt64
        private var lastHeard: UInt64
        private var redirected = false
        private var cancelledProxy = false
        private var cancelledOther = false

        /// `deadline` is when the whole request ends, however many tries it takes.
        init(limits: AgentTransportLimits, deadline: UInt64) {
            let now = DispatchTime.now().uptimeNanoseconds
            idle = HTTPTransport.nanoseconds(limits.idleSeconds)
            started = now
            self.deadline = deadline
            lastHeard = now
        }

        var wasRedirected: Bool { held { redirected } }

        /// Something arrived.
        func touch() {
            let now = DispatchTime.now().uptimeNanoseconds
            held { lastHeard = now }
        }

        /// Returns only by being cancelled. Throws `.timedOut` when the whole request ran too long, and `.quiet` when
        /// nothing arrived for the idle limit.
        func keepTime() async throws {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                let quietAt = held { lastHeard &+ idle }
                if now >= deadline { throw AgentTransportError.timedOut }
                if now >= quietAt { throw Hitch.quiet }
                try await Task.sleep(nanoseconds: min(quietAt, deadline) - now)
            }
        }

        /// What `error`, thrown while the request ran, means. An error of the transport's own stands; a failure the
        /// system reported is read in the light of what this watch refused.
        func verdict(on error: Error, loopback: Bool) -> Error {
            if error is AgentTransportError || error is Hitch { return error }
            if error is CancellationError { return AgentTransportError.cancelled }
            let (redirected, proxy, other) = held { (self.redirected, cancelledProxy, cancelledOther) }
            if redirected { return AgentTransportError.redirected }
            if proxy { return AgentTransportError.proxyAuth }
            if other { return AgentTransportError.unreachable }
            guard let failure = error as? URLError else { return AgentTransportError.unreachable }
            switch failure.code {
            case .timedOut:
                return DispatchTime.now().uptimeNanoseconds >= deadline ? AgentTransportError.timedOut : Hitch.quiet
            case .cancelled: return AgentTransportError.cancelled
            case .cannotConnectToHost: return loopback ? AgentTransportError.notRunning : AgentTransportError.unreachable
            case .appTransportSecurityRequiresSecureConnection: return AgentTransportError.insecure
            case .dataLengthExceedsMaximum: return AgentTransportError.tooLarge
            default: return AgentTransportError.unreachable
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let disposition = HTTPTransport.answer(challenge)
            if disposition == .cancelAuthenticationChallenge {
                let proxy = challenge.protectionSpace.isProxy()
                held { if proxy { cancelledProxy = true } else { cancelledOther = true } }
            }
            completionHandler(disposition, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            held { redirected = true }
            completionHandler(nil)
        }

        private func held<Value>(_ body: () -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
}
