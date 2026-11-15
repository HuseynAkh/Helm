// The listener for a ChatGPT sign-in's callback: the only file in Helm that may open a socket, and it only listens.
import Foundation

/// Listens on 127.0.0.1 for the one request a browser makes when a ChatGPT sign-in finishes, then stops.
///
/// What it holds to:
/// - An IPv4 stream socket bound to the loopback address alone, on a port the system picks, so nothing beyond this
///   Mac can reach it. It never connects anywhere.
/// - It listens before the browser opens, and for one sign-in at most `timeout` seconds.
/// - Each connection gets one request, read up to 8 KB of head and five seconds, and one answer, then it is closed.
///   Only a GET for the callback path whose query the sign-in accepts, that is with its state, ends the wait; any other
///   request is answered 400 or 404 and the wait goes on.
/// - The answer is a short page that says to go back to Helm. It loads nothing and asks to be kept nowhere.
/// - `stop()` ends the wait at once: a callback still awaited throws `.cancelled`. A listener is made for one sign-in
///   and doesn't start again once stopped.
public final class AgentLoopbackListener: AgentCallbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var stopped = false
    private var waiting = false

    /// The most a request's head may be.
    static let headBytes = 8_192
    /// Seconds a connection may take to send its request.
    static let connectionSeconds = 5
    /// How often the wait looks at the clock and at `stop()`, in milliseconds.
    static let tick: Int32 = 200

    public init() {}

    public func start() throws -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw AgentSignInFailure.unavailable }
        var on: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketDescriptor, 4) == 0, let port = Self.port(of: socketDescriptor) else {
            close(socketDescriptor)
            throw AgentSignInFailure.unavailable
        }
        _ = fcntl(socketDescriptor, F_SETFL, fcntl(socketDescriptor, F_GETFL) | O_NONBLOCK)
        let refused = locked { () -> Bool in
            guard !stopped, descriptor < 0 else { return true }
            descriptor = socketDescriptor
            return false
        }
        if refused {
            close(socketDescriptor)
            throw AgentSignInFailure.unavailable
        }
        return port
    }

    public func callback(path: String, timeout: Double,
                         accepts: @escaping @Sendable ([String: String]) -> Bool) async throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        return try await withCheckedThrowingContinuation { continuation in
            let ready = locked { () -> Int32? in
                guard !stopped, descriptor >= 0, !waiting else { return nil }
                waiting = true
                return descriptor
            }
            guard let socketDescriptor = ready else { return continuation.resume(throwing: AgentSignInFailure.cancelled) }
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: self.wait(on: socketDescriptor, path: path, deadline: deadline, accepts: accepts))
            }
        }
    }

    public func stop() {
        let closeNow = locked { () -> Int32? in
            stopped = true
            guard !waiting, descriptor >= 0 else { return nil }
            defer { descriptor = -1 }
            return descriptor
        }
        if let closeNow { close(closeNow) }
    }

    /// The address the socket is bound to, as text, for tests: always "127.0.0.1".
    var boundAddressForTesting: String? {
        let socketDescriptor = locked { descriptor }
        guard socketDescriptor >= 0 else { return nil }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) }
        }
        guard found == 0 else { return nil }
        let value = UInt32(bigEndian: address.sin_addr.s_addr)
        return [value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF].map(String.init).joined(separator: ".")
    }

    // MARK: Waiting

    private func wait(on socketDescriptor: Int32, path: String, deadline: Date,
                      accepts: @Sendable ([String: String]) -> Bool) -> Result<[String: String], Error> {
        defer {
            let closeNow = locked { () -> Bool in
                waiting = false
                guard descriptor == socketDescriptor else { return false }
                descriptor = -1
                return true
            }
            if closeNow { close(socketDescriptor) }
        }
        while true {
            if locked({ stopped }) { return .failure(AgentSignInFailure.cancelled) }
            if Date() >= deadline { return .failure(AgentSignInFailure.timedOut) }
            var watched = pollfd(fd: socketDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, Self.tick) > 0, watched.revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(socketDescriptor, nil, nil)
            guard client >= 0 else { continue }
            if let query = answer(client, path: path, accepts: accepts) { return .success(query) }
        }
    }

    /// Reads one request from `client`, answers it and closes it. The query, when this was the callback.
    private func answer(_ client: Int32, path: String, accepts: @Sendable ([String: String]) -> Bool) -> [String: String]? {
        defer { close(client) }
        // On macOS an accepted connection inherits the listening socket's O_NONBLOCK. A browser can connect a moment
        // before it sends the request, so the connection reads blocking, bounded by the time limit below.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Self.connectionSeconds, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard let head = Self.head(from: client), let request = AgentCallbackRequest(head: head) else {
            Self.reply(client, status: "400 Bad Request", page: nil)
            return nil
        }
        guard request.path == path else {
            Self.reply(client, status: "404 Not Found", page: nil)
            return nil
        }
        guard let query = request.query, accepts(query) else {
            Self.reply(client, status: "400 Bad Request", page: nil)
            return nil
        }
        Self.reply(client, status: "200 OK", page: AgentText.signInPage)
        return query
    }

    /// The request's head: everything up to the blank line, at most `headBytes`.
    private static func head(from client: Int32) -> String? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while bytes.count < headBytes {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            bytes += buffer[0..<count]
            if let end = bytes.firstRange(of: [13, 10, 13, 10]) {
                return String(bytes: bytes[..<end.lowerBound], encoding: .utf8)
            }
        }
        return nil
    }

    private static func reply(_ client: Int32, status: String, page: String?) {
        let body = page.map { text in
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>Helm</title></head><body><p>"
                + htmlEscaped(text) + "</p></body></html>"
        } ?? ""
        let head = ["HTTP/1.1 " + status, "Content-Type: text/html; charset=utf-8", "Content-Length: \(body.utf8.count)",
                    "Cache-Control: no-store", "Referrer-Policy: no-referrer",
                    "Content-Security-Policy: default-src 'none'", "Connection: close", "", ""].joined(separator: "\r\n")
        let bytes = Array((head + body).utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return }
            sent += count
        }
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func port(of socketDescriptor: Int32) -> Int? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) }
        }
        guard found == 0 else { return nil }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return port > 0 ? port : nil
    }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The parts of a request's head the listener needs: a GET's path and its query, each name once.
struct AgentCallbackRequest: Equatable {
    let path: String
    /// Nil for a query that names a field twice, or can't be read.
    let query: [String: String]?

    /// Nil for anything but `GET <target> HTTP/1.x`.
    init?(head: String) {
        guard let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[0] == "GET", words[2].hasPrefix("HTTP/1."), words[1].hasPrefix("/") else { return nil }
        let target = words[1]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            query = Self.fields(String(target[target.index(after: mark)...]))
        } else {
            path = String(target)
            query = [:]
        }
    }

    /// `a=1&b=2`, with `+` as a space and percent escapes read. Nil when a name comes twice or an escape is broken.
    static func fields(_ text: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decoded(parts[0]), !name.isEmpty, fields[name] == nil,
                  let value = decoded(parts.count > 1 ? parts[1] : "") else { return nil }
            fields[name] = value
        }
        return fields
    }

    private static func decoded(_ text: Substring) -> String? {
        String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
