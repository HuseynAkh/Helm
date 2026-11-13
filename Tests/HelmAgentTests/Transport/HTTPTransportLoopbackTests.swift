import XCTest
@testable import HelmAgent

/// The real transport, with no stub, against a server on 127.0.0.1 inside the test process: what goes over the
/// wire, and one streamed turn in each provider's shape. A test skips, and says why, when the listener can't start
/// or the connection is refused by the system; error -1022 means App Transport Security blocked plain http here.
final class HTTPTransportLoopbackTests: XCTestCase {
    private typealias T = AgentTransportTesting
    private var servers: [AgentLoopbackServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    private func server(_ replies: [AgentLoopbackServer.Reply]) throws -> AgentLoopbackServer {
        do {
            let server = try AgentLoopbackServer(replies: replies)
            servers.append(server)
            return server
        } catch {
            let note = "Loopback test skipped: the listener couldn't start (\(error))."
            print(note)
            throw XCTSkip(note)
        }
    }

    /// Skips when the system, not the transport, stopped the connection.
    private func skipIfBlocked(_ failure: AgentTransportError?) throws {
        switch failure {
        case .insecure?:
            let note = "Loopback test skipped: error -1022, App Transport Security blocked plain http to 127.0.0.1 in this test runner."
            print(note)
            throw XCTSkip(note)
        case .unreachable?, .notRunning?:
            let note = "Loopback test skipped: couldn't connect to the listener on 127.0.0.1 (\(String(describing: failure)))."
            print(note)
            throw XCTSkip(note)
        default:
            return
        }
    }

    private func transport(_ profile: AgentProviderProfile, secrets: any AgentSecretStoring = MemorySecretStore(),
                           limits: AgentTransportLimits = AgentTransportTesting.roomy) -> HTTPTransport {
        HTTPTransport(liveProfile: profile, secrets: secrets, limits: limits)
    }

    // MARK: A streamed turn in each provider's shape

    private static let anthropicTurn = """
    event: message_start\r
    data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}\r
    \r
    event: content_block_delta\r
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}\r
    \r
    event: ping\r
    data: {"type":"ping"}\r
    \r
    event: message_delta\r
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\r
    \r
    event: message_stop\r
    data: {"type":"message_stop"}\r
    \r

    """

    private static let responsesTurn = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Hel"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"list_folder","arguments":"{}"}}

    event: response.completed
    data: {"type":"response.completed","response":{"status":"completed"}}


    """

    private static let chatTurn = """
    : keep-alive

    data: {"choices":[{"delta":{"content":"Hi"}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"list_folder","arguments":"{\\"folder\\":\\"r1\\"}"}}]}}]}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]


    """

    private static func expectedLines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    func testOneStreamedTurnInEachProvidersShapeArrivesLineForLine() async throws {
        for (name, turn) in [("anthropic", Self.anthropicTurn), ("responses", Self.responsesTurn), ("chat", Self.chatTurn)] {
            let server = try server([.events(turn, in: 4)])
            let profile = try T.ollama(port: server.port)
            let body = T.data("{\"model\":\"stand-in\",\"stream\":true,\"wire\":\"\(name)\"}")
            let outcome = await T.drain(transport(profile, limits: .local).stream(.chat, body: body))
            try skipIfBlocked(outcome.failure)

            XCTAssertNil(outcome.failure, name)
            XCTAssertNil(outcome.otherError, name)
            XCTAssertEqual(outcome.lines, Self.expectedLines(turn), name)
            let received = try XCTUnwrap(server.requests.first, name)
            XCTAssertEqual(server.requests.count, 1, name)
            XCTAssertEqual(received.requestLine, "POST /v1/chat/completions HTTP/1.1", name)
            XCTAssertEqual(received.body, body, name)
            XCTAssertEqual(received.header("Host"), "127.0.0.1:\(server.port)", name)
            XCTAssertEqual(received.header("Content-Type"), "application/json", name)
            XCTAssertEqual(received.header("Accept"), "text/event-stream", name)
            XCTAssertEqual(received.header("User-Agent"), "Helm", name)
            XCTAssertEqual(received.header("Accept-Language"), "en", name)
            XCTAssertNil(received.header("Origin"), name)
            XCTAssertNil(received.header("Cookie"), name)
            XCTAssertNil(received.header("Authorization"), name)
        }
    }

    func testALocalServersTokenGoesOnTheWire() async throws {
        let server = try server([.events("data: {}\n\ndata: [DONE]\n\n")])
        let profile = try T.lmStudio(port: server.port)
        let secrets = MemorySecretStore()
        try secrets.save(T.secret(), for: profile.secretID)
        let outcome = await T.drain(transport(profile, secrets: secrets).stream(.chat, body: T.data("{}")))
        try skipIfBlocked(outcome.failure)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(server.requests.first?.header("Authorization"), "Bearer " + T.key)
    }

    func testAFetchReadsTheWholeReply() async throws {
        let json = "{\"models\":[{\"name\":\"stand-in:latest\"}]}"
        let server = try server([.init(status: "200 OK", headers: ["Content-Type": "application/json"],
                                       pieces: [T.data(String(json.prefix(10))), T.data(String(json.dropFirst(10)))])])
        let profile = try T.ollama(port: server.port)
        let reply: AgentHTTPReply
        do {
            reply = try await transport(profile).fetch(.models)
        } catch let failure as AgentTransportError {
            try skipIfBlocked(failure)
            throw failure
        }
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.body, T.data(json))
        XCTAssertEqual(server.requests.first?.requestLine, "GET /api/tags HTTP/1.1")
        XCTAssertEqual(server.requests.first?.header("Accept"), "application/json")
    }

    // MARK: Refusals on the wire

    func testARedirectIsRefusedAndItsTargetNeverAsked() async throws {
        let target = try server([.events("data: stolen\n")])
        let first = try server([.init(status: "302 Found", headers: ["Location": "http" + "://127.0.0.1:\(target.port)/v1/chat/completions"],
                                      pieces: [T.data("moved")])])
        let outcome = await T.drain(transport(try T.ollama(port: first.port)).stream(.chat, body: T.data("{}")))
        try skipIfBlocked(outcome.failure)
        XCTAssertEqual(outcome.failure, .redirected)
        XCTAssertEqual(outcome.lines, [])
        XCTAssertEqual(first.requests.count, 1)
        // Give a follow-up the time it would need, then check that none came.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(target.requests.count, 0)
    }

    func testACookieSetByTheServerIsNotSentBack() async throws {
        let setting = AgentLoopbackServer.Reply(status: "200 OK",
                                                headers: ["Set-Cookie": "session=abc123; Path=/", "Content-Type": "application/json"],
                                                pieces: [T.data("{}")])
        let server = try server([setting, setting, .events("data: {}\n")])
        let transport = transport(try T.ollama(port: server.port))
        do {
            _ = try await transport.fetch(.models)
            _ = try await transport.fetch(.models)
        } catch let failure as AgentTransportError {
            try skipIfBlocked(failure)
            throw failure
        }
        _ = await T.drain(transport.stream(.chat, body: T.data("{}")))
        XCTAssertEqual(server.requests.count, 3)
        for request in server.requests {
            XCTAssertNil(request.header("Cookie"), request.requestLine)
        }
    }

    func testAnErrorStatusEndsTheStreamWithItsBody() async throws {
        let server = try server([.init(status: "404 Not Found", headers: ["Content-Type": "application/json"],
                                       pieces: [T.data("{\"error\":\"model 'x' not found\"}")])])
        let outcome = await T.drain(transport(try T.ollama(port: server.port)).stream(.chat, body: T.data("{}")))
        try skipIfBlocked(outcome.failure)
        XCTAssertEqual(outcome.failure, .http(status: 404, body: T.data("{\"error\":\"model 'x' not found\"}")))
    }

    func testNoServerOnThePortIsNotRunning() async throws {
        // A port that was just in use and is now closed.
        let closed = try server([])
        let port = closed.port
        closed.stop()
        let outcome = await T.drain(transport(try T.ollama(port: port)).stream(.chat, body: T.data("{}")))
        if outcome.failure == .insecure { try skipIfBlocked(.insecure) }
        XCTAssertEqual(outcome.failure, .notRunning)
    }
}
