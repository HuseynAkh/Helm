import Foundation

/// A tiny HTTP server on 127.0.0.1, inside the test process, for the transport's loopback tests. It answers each
/// connection with one scripted reply, records what it was sent, and closes the connection. It listens on a port the
/// system picks and only on the loopback address, so nothing outside this Mac can reach it.
final class AgentLoopbackServer: @unchecked Sendable {
    struct Received {
        let requestLine: String
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// A reply: its status line and headers, then each piece of the body, written with a short pause between them.
    struct Reply {
        var status: String
        var headers: [String: String]
        var pieces: [Data]

        static func events(_ text: String, in parts: Int = 3) -> Reply {
            let bytes = Array(text.utf8)
            let size = max(1, (bytes.count + parts - 1) / parts)
            let pieces = stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
            return Reply(status: "200 OK", headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
                         pieces: pieces)
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case socket(String, Int32)
        var description: String {
            switch self {
            case let .socket(step, code): return "\(step) failed with errno \(code)"
            }
        }
    }

    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var received: [Received] = []
    private var replies: [Reply]
    private var closed = false

    init(replies: [Reply]) throws {
        self.replies = replies
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket("socket", errno) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.socket("bind", code)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.socket("listen", code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.socket("getsockname", code)
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "agent-loopback-server"
        thread.start()
    }

    var requests: [Received] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func stop() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    deinit { stop() }

    private func acceptLoop() {
        while true {
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let worker = Thread { [weak self] in
                self?.serve(connection)
                Darwin.close(connection)
            }
            worker.start()
        }
    }

    private func serve(_ connection: Int32) {
        guard let request = readRequest(connection) else { return }
        let reply: Reply = {
            lock.lock(); defer { lock.unlock() }
            received.append(request)
            return replies.isEmpty ? Reply(status: "404 Not Found", headers: [:], pieces: []) : replies.removeFirst()
        }()
        var head = "HTTP/1.1 \(reply.status)\r\nConnection: close\r\n"
        for (name, value) in reply.headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        guard send(Data(head.utf8), on: connection) else { return }
        for piece in reply.pieces {
            usleep(20_000)
            guard send(piece, on: connection) else { return }
        }
    }

    private func readRequest(_ connection: Int32) -> Received? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let count = Darwin.recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            headEnd = data.range(of: separator)
        }
        guard let end = headEnd else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[end.upperBound...])
        let length = headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0
        while body.count < length {
            let count = Darwin.recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return Received(requestLine: requestLine, headers: headers, body: body)
    }

    private func send(_ data: Data, on connection: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(connection, base + sent, raw.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}
