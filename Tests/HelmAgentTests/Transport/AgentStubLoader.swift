import Foundation

/// A loader that stands in for the network in transport tests. Each request it is handed is recorded, then answered
/// by the steps the current test scripted for it. Nothing leaves the process.
final class AgentStubLoader: URLProtocol, URLAuthenticationChallengeSender, @unchecked Sendable {
    /// A request as the loader received it.
    struct Seen {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        /// A header by name, in any case.
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    enum Step {
        /// The status line and headers. `from` stands in another address for the reply's own.
        case respond(status: Int, headers: [String: String], from: URL?)
        case send(Data)
        /// The same bytes `count` times.
        case sendRepeated(Data, count: Int)
        case pause(Double)
        case redirect(to: URL, status: Int)
        /// A server, or a proxy, that asks for a password.
        case challenge(proxy: Bool)
        case finish
        case fail(URLError.Code)
    }

    // MARK: What the current test set up

    private static let lock = NSLock()
    private static var script: (URLRequest) -> [Step] = { _ in [.fail(.cannotConnectToHost)] }
    private static var requests: [Seen] = []
    private static var answers: [String] = []
    private static var stopCount = 0

    /// Sets how every request is answered and forgets what earlier tests recorded.
    static func reset(_ answer: @escaping (URLRequest) -> [Step]) {
        held { script = answer; requests = []; answers = []; stopCount = 0 }
    }

    static var seen: [Seen] { held { requests } }
    /// How each challenge was answered: "cancel", "credential", "without", "default" or "reject".
    static var challengeAnswers: [String] { held { answers } }
    /// How many requests were stopped by the session before they finished.
    static var stops: Int { held { stopCount } }

    private static func held<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: URLProtocol

    private let queue = DispatchQueue(label: "agent-stub-loader")
    private var stopped = false
    private var finished = false
    private var pendingSteps: [Step] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let seen = Seen(method: request.httpMethod ?? "GET", url: request.url ?? URL(fileURLWithPath: "/"),
                        headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        let steps = Self.held { () -> [Step] in
            Self.requests.append(seen)
            return Self.script(request)
        }
        queue.async { self.pendingSteps = steps; self.next() }
    }

    override func stopLoading() {
        queue.async {
            if !self.stopped, !self.finished { Self.held { Self.stopCount += 1 } }
            self.stopped = true
        }
    }

    /// Runs the steps in order on the loader's queue, until one waits or the request is stopped.
    private func next() {
        while !stopped, !pendingSteps.isEmpty {
            let step = pendingSteps.removeFirst()
            switch step {
            case let .respond(status, headers, from):
                let address = from ?? request.url ?? URL(fileURLWithPath: "/")
                let response = HTTPURLResponse(url: address, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            case let .send(data):
                client?.urlProtocol(self, didLoad: data)
            case let .sendRepeated(data, count):
                for _ in 0..<count where !stopped { client?.urlProtocol(self, didLoad: data) }
            case let .pause(seconds):
                queue.asyncAfter(deadline: .now() + seconds) { self.next() }
                return
            case let .redirect(target, status):
                let address = request.url ?? URL(fileURLWithPath: "/")
                let response = HTTPURLResponse(url: address, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            case let .challenge(proxy):
                let space: URLProtectionSpace
                if proxy {
                    space = URLProtectionSpace(proxyHost: "proxy.example.com", port: 8080, type: "https", realm: "proxy",
                                               authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
                } else {
                    space = URLProtectionSpace(host: request.url?.host ?? "", port: 443, protocol: "https", realm: "server",
                                               authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
                }
                let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                           previousFailureCount: 0, failureResponse: nil, error: nil,
                                                           sender: self)
                client?.urlProtocol(self, didReceive: challenge)
                return
            case .finish:
                finished = true
                client?.urlProtocolDidFinishLoading(self)
                return
            case let .fail(code):
                finished = true
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
        }
    }

    // MARK: Answers to a challenge

    private func answered(_ answer: String, failing: Bool) {
        Self.held { Self.answers.append(answer) }
        queue.async {
            if failing {
                self.finished = true
                self.client?.urlProtocol(self, didFailWithError: URLError(.userCancelledAuthentication))
            } else {
                self.next()
            }
        }
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { answered("credential", failing: false) }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { answered("without", failing: false) }
    func cancel(_ challenge: URLAuthenticationChallenge) { answered("cancel", failing: true) }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { answered("default", failing: false) }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { answered("reject", failing: false) }

    // MARK: Bodies

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
