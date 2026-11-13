import XCTest
import HelmCore
@testable import HelmAgent

/// What went wrong, as one fixed failure: statuses and error bodies from each provider, errors inside a stream,
/// and transport errors.
final class AgentErrorMapperTests: XCTestCase {
    private func status(_ code: Int, _ fixture: String? = nil, _ provider: AgentProviderID) throws -> AgentFailure {
        let body = try fixture.map { try ProviderFixtures.data("errors/\($0).json") } ?? Data()
        return AgentErrorMapper.failure(status: code, body: body, provider: provider)
    }

    func testGeminisBadKeyAt400IsWrongKey() throws {
        XCTAssertEqual(try status(400, "gemini-bad-key", .gemini), .wrongKey)
        // The same body as a plain object, not wrapped in a list.
        let plain = Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#.utf8)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: plain, provider: .gemini), .wrongKey)
    }

    func testAnOrdinary400IsABadRequest() throws {
        XCTAssertEqual(try status(400, "claude-bad-request", .claude), .badRequest)
        XCTAssertEqual(try status(400, nil, .gemini), .badRequest)
    }

    func testGeminiWantingBillingIsOutOfCredit() {
        let body = Data(#"{"error":{"code":400,"message":"Billing required","status":"FAILED_PRECONDITION"}}"#.utf8)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: body, provider: .gemini), .outOfCredit)
    }

    func testASpendLimit429IsOutOfCreditAndAnOrdinaryOneIsRateLimited() throws {
        XCTAssertEqual(try status(429, "claude-spend-limit", .claude), .outOfCredit)
        XCTAssertEqual(try status(429, "openai-quota", .openAI), .outOfCredit)
        XCTAssertEqual(try status(429, "openai-quota", .grok), .outOfCredit)
        XCTAssertEqual(try status(429, "claude-rate-limit", .claude), .rateLimited)
        XCTAssertEqual(try status(429, nil, .other), .rateLimited)
    }

    func testAModelThatCantUseToolsIsNoTools() throws {
        XCTAssertEqual(try status(400, "ollama-no-tools", .ollama), .noTools)
        let plain = Data(#"{"error":"registry.ollama.ai/library/gemma3:4b does not support tools"}"#.utf8)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: plain, provider: .ollama), .noTools)
    }

    func testStatusesMapToTheirFailures() throws {
        let table: [(Int, AgentFailure)] = [(401, .wrongKey), (403, .wrongKey), (402, .outOfCredit), (404, .noSuchModel),
                                            (408, .timedOut), (413, .tooLarge), (422, .badRequest), (500, .overloaded),
                                            (502, .overloaded), (503, .overloaded), (504, .timedOut), (529, .overloaded),
                                            (302, .unreadable)]
        for (code, failure) in table {
            XCTAssertEqual(try status(code, nil, .claude), failure, "status \(code)")
        }
    }

    func testAPromptTooLongIsTooLarge() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 1200000 tokens > 1000000 maximum"}}"#.utf8)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: body, provider: .claude), .tooLarge)
    }

    func testABodyThatIsNotJSONIsReadAsText() {
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: Data("model does not support tools".utf8), provider: .lmStudio), .noTools)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: Data("<html>bad</html>".utf8), provider: .other), .badRequest)
    }

    // MARK: Transport errors

    func testConnectionRefusedOnLoopbackIsNotRunning() {
        XCTAssertEqual(AgentErrorMapper.failure(.notRunning, provider: .ollama), .notRunning)
        XCTAssertEqual(AgentErrorMapper.failure(.notRunning, provider: .lmStudio), .notRunning)
        XCTAssertEqual(AgentErrorMapper.failure(.unreachable, provider: .ollama), .notRunning)
        // A cloud provider that can't be reached is unreachable, never "not running".
        XCTAssertEqual(AgentErrorMapper.failure(.unreachable, provider: .claude), .unreachable)
        XCTAssertEqual(AgentErrorMapper.failure(.notRunning, provider: .other), .unreachable)
    }

    func testAProxyThatWantsAPasswordIsUnreachable() {
        for provider in AgentProviderID.allCases {
            XCTAssertEqual(AgentErrorMapper.failure(.proxyAuth, provider: provider), .unreachable)
        }
    }

    func testEveryOtherTransportErrorHasItsCase() throws {
        let table: [(AgentTransportError, AgentFailure)] = [
            (.redirected, .unreachable), (.wrongHost, .unreachable), (.insecure, .unreachable), (.tooLarge, .unreadable),
            (.timedOut, .timedOut), (.cancelled, .cancelled), (.noKey, .noKey), (.keyDenied, .keyDenied),
            (.keyInBody, .unreadable), (.http(status: 401, body: Data()), .wrongKey)
        ]
        for (error, failure) in table {
            XCTAssertEqual(AgentErrorMapper.failure(error, provider: .claude), failure, "\(error)")
        }
        XCTAssertEqual(AgentErrorMapper.failure(.http(status: 400, body: try ProviderFixtures.data("errors/gemini-bad-key.json")),
                                                provider: .gemini), .wrongKey)
    }

    func testAnyErrorIsOneFailure() {
        XCTAssertEqual(AgentErrorMapper.failure(of: AgentFailure.noKey, provider: .claude), .noKey)
        XCTAssertEqual(AgentErrorMapper.failure(of: CancellationError(), provider: .claude), .cancelled)
        XCTAssertEqual(AgentErrorMapper.failure(of: AgentTransportError.proxyAuth, provider: .claude), .unreachable)
        XCTAssertEqual(AgentErrorMapper.failure(of: URLError(.badURL), provider: .claude), .unreachable)
    }

    // MARK: Errors inside a stream

    func testStreamErrorsMapLikeTheirReplies() {
        let cases: [(String, AgentFailure)] = [
            (#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, .overloaded),
            (#"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#, .rateLimited),
            (#"{"type":"error","code":"insufficient_quota","message":"x"}"#, .outOfCredit),
            (#"{"error":{"code":502,"message":"Provider disconnected unexpectedly"}}"#, .overloaded),
            (#"{"error":{"code":"context_length_exceeded","message":"x"}}"#, .tooLarge),
            (#"{"error":"something new"}"#, .overloaded)
        ]
        for (text, failure) in cases {
            XCTAssertEqual(AgentErrorMapper.failure(streamError: ProviderFixtures.object(text)), failure, text)
        }
    }
}
