import XCTest
import HelmCore
@testable import HelmAgent

/// The Chat Completions wire used for Gemini, Ollama, LM Studio and typed addresses: the bytes of each body, what
/// a recorded stream becomes, and that a model's message goes back with every field it came with.
final class ChatCompletionsAdapterTests: XCTestCase {
    private let hosted = ChatCompletionsAdapter(sendsMaxTokens: true)
    private let local = ChatCompletionsAdapter(sendsMaxTokens: false)

    /// The person's message, Gemini's message with two whole calls and a thought signature, and both results.
    static func history() throws -> [AgentJSON] {
        let adapter = ChatCompletionsAdapter(sendsMaxTokens: true)
        return adapter.userItems(text: ProviderFixtures.message, toolResults: [])
            + [try ProviderFixtures.json("chat/stream-whole-gemini-item.json")]
            + adapter.userItems(text: nil, toolResults: [
                AgentToolResult(callID: "function-call-1", name: "list_folder", json: #"{"source":"folder_listing","items":[]}"#),
                AgentToolResult(callID: "function-call-2", name: "find_items", json: #"{"source":"error","code":"bad_arguments"}"#,
                                isError: true)
            ])
    }

    private func input() throws -> AgentTurnInput {
        AgentTurnInput(system: ProviderFixtures.system, tools: [ProviderFixtures.tool], history: try Self.history())
    }

    // MARK: Bodies

    func testHostedTurnBodyMatchesItsFixtureByteForByte() throws {
        let body = try hosted.turnBody(input(), model: ProviderFixtures.model)
        try ProviderFixtures.assertSameBytes(body, "chat/turn-request-hosted.json")
        try ProviderFixtures.assertNothingForbidden(body)
        XCTAssertEqual(try AgentJSON(data: body)["max_tokens"], .number(16_000))
    }

    func testLocalTurnBodyMatchesItsFixtureAndHasNoTokenCeiling() throws {
        let body = try local.turnBody(input(), model: ProviderFixtures.model)
        try ProviderFixtures.assertSameBytes(body, "chat/turn-request-local.json")
        try ProviderFixtures.assertNothingForbidden(body)
        let json = try AgentJSON(data: body)
        XCTAssertNil(json["max_tokens"])
        XCTAssertNil(json["max_completion_tokens"])
        XCTAssertEqual(Set(json.objectValue.map { Array($0.keys) } ?? []), ["model", "messages", "tools", "stream"])
    }

    func testTheSystemPromptGoesFirstAndTheHistoryFollowsUnchanged() throws {
        let body = try AgentJSON(data: hosted.turnBody(input(), model: ProviderFixtures.model))
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.first, .object(["role": .string("system"), "content": .string(ProviderFixtures.system)]))
        XCTAssertEqual(Array(messages.dropFirst()), try Self.history())
        XCTAssertEqual(body["tools"], .array([.object(["type": .string("function"), "function": .object([
            "name": .string("list_folder"), "description": .string("List what is in a folder."),
            "parameters": ProviderFixtures.tool.schema])])]))
    }

    func testStructuredBodyMatchesItsFixtureAndHasNoTools() throws {
        let body = try hosted.structuredBody(ProviderFixtures.ask, model: ProviderFixtures.model)
        try ProviderFixtures.assertSameBytes(body, "chat/structured-request.json")
        try ProviderFixtures.assertNothingForbidden(body)
        let json = try AgentJSON(data: body)
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["stream"])
        XCTAssertEqual(json["response_format"]?["json_schema"]?["schema"], ProviderFixtures.ask.schema)
    }

    // MARK: User turns

    func testOneToolMessagePerResultInCallOrderThenTheText() {
        let items = hosted.userItems(text: "Next", toolResults: [
            AgentToolResult(callID: "call_1", name: "list_folder", json: "{}"),
            AgentToolResult(callID: "call_2", name: "list_folder", json: "[]", isError: true)
        ])
        XCTAssertEqual(items, [
            ProviderFixtures.object(#"{"role": "tool", "tool_call_id": "call_1", "content": "{}"}"#),
            ProviderFixtures.object(#"{"role": "tool", "tool_call_id": "call_2", "content": "[]"}"#),
            ProviderFixtures.object(#"{"role": "user", "content": "Next"}"#)
        ])
    }

    // MARK: Streams

    func testFragmentedCallsAreJoinedAndTheMessageHasNullContent() throws {
        let played = try ProviderFixtures.play(hosted, fixture: "chat/stream-fragmented.sse")
        XCTAssertEqual(played.texts, ["Checking ", "the folder."])
        XCTAssertEqual(played.tools, ["list_folder"])
        XCTAssertEqual(played.result.stop, .toolUse)
        XCTAssertEqual(played.result.rawItems, [try ProviderFixtures.json("chat/stream-fragmented-item.json")])
        XCTAssertEqual(played.result.rawItems.first?["content"], .null)
        XCTAssertEqual(played.result.calls, [AgentToolCall(id: "call_abc", name: "list_folder",
                                                           arguments: Data(#"{"folder":"r1","depth":1,"after":""}"#.utf8))])
    }

    func testWholeCallsKeepTheirUnknownFieldsAndAStopWithCallsIsToolUse() throws {
        let played = try ProviderFixtures.play(hosted, fixture: "chat/stream-whole-gemini.sse")
        XCTAssertEqual(played.tools, ["list_folder", "find_items"])
        // Gemini ends a turn with calls as an ordinary stop.
        XCTAssertEqual(played.result.stop, .toolUse)
        XCTAssertEqual(played.result.rawItems, [try ProviderFixtures.json("chat/stream-whole-gemini-item.json")])
        XCTAssertEqual(played.result.calls.map(\.id), ["function-call-1", "function-call-2"])
    }

    func testAStreamedMessageGoesBackIntoTheNextRequestUnchanged() throws {
        let played = try ProviderFixtures.play(hosted, fixture: "chat/stream-whole-gemini.sse")
        let history = hosted.userItems(text: ProviderFixtures.message, toolResults: []) + played.result.rawItems
            + hosted.userItems(text: nil, toolResults: played.result.calls.map { AgentToolResult(callID: $0.id, name: $0.name, json: "{}") })
        let body = try AgentJSON(data: hosted.turnBody(AgentTurnInput(system: ProviderFixtures.system, tools: [], history: history),
                                                       model: ProviderFixtures.model))
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages[2], played.result.rawItems[0])
        XCTAssertEqual(messages[2]["tool_calls"]?.arrayValue?.first?["extra_content"]?["google"]?["thought_signature"],
                       .string("CiIBexampleThoughtSignature"))
        XCTAssertEqual(messages[3...].map { $0["tool_call_id"] }, [.string("function-call-1"), .string("function-call-2")])
    }

    func testSeveralWholeCallsInOneChunkAndTheMessagesOwnFieldsAreKept() throws {
        let played = try ProviderFixtures.play(local, fixture: "chat/stream-two-calls.sse")
        XCTAssertEqual(played.result.stop, .toolUse)
        XCTAssertEqual(played.result.calls.map(\.id), ["call_x1", "call_x2"])
        let message = try XCTUnwrap(played.result.rawItems.first)
        XCTAssertEqual(message["content"], .null)
        XCTAssertEqual(message["reasoning"], .string("The person wants two listings."))
        XCTAssertEqual(message["tool_calls"]?.arrayValue?.count, 2)
    }

    func testTwoWholeCallsUnderOneIndexAreTwoCalls() {
        let lines = [
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"list_folder","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"b","function":{"name":"find_items","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        ]
        XCTAssertEqual(ProviderFixtures.play(hosted, lines).result.calls.map(\.id), ["a", "b"])
    }

    func testPiecesThatRepeatTheirCallsIdUnderOneIndexStayWithThatCall() throws {
        let lines = [
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"list_folder","arguments":"{\"folder\":"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"arguments":"\"r1\"}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"b","function":{"name":"find_items","arguments":"{\"words\":"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"b","function":{"arguments":"\"x\"}"}}]},"finish_reason":"tool_calls"}]}"#
        ]
        let result = ProviderFixtures.play(hosted, lines).result
        XCTAssertEqual(result.stop, .toolUse)
        XCTAssertEqual(result.calls.map(\.id), ["a", "b"], "one call per id, not one per piece")
        XCTAssertEqual(try AgentJSON(data: try XCTUnwrap(result.calls.first).arguments), .object(["folder": .string("r1")]))
        XCTAssertEqual(try AgentJSON(data: try XCTUnwrap(result.calls.last).arguments), .object(["words": .string("x")]))
    }

    func testATextStreamEndsTheTurnWithItsText() throws {
        let played = try ProviderFixtures.play(hosted, fixture: "chat/stream-text.sse")
        XCTAssertEqual(played.result.stop, .endTurn)
        XCTAssertEqual(played.result.rawItems, [ProviderFixtures.object(#"{"role": "assistant", "content": "The plan is ready."}"#)])
    }

    func testARefusalKeepsNothingAndHandsOnNoCall() throws {
        let played = try ProviderFixtures.play(hosted, fixture: "chat/stream-refusal.sse")
        XCTAssertEqual(played.result.stop, .refusal)
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testLengthWithATrailingCallRunsNothing() throws {
        let played = try ProviderFixtures.play(hosted, fixture: "chat/stream-length.sse")
        XCTAssertEqual(played.result.stop, .maxTokens)
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testAContentFilterStopRunsNothing() {
        let lines = [#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"list_folder","arguments":"{}"}}]},"finish_reason":"content_filter"}]}"#]
        let result = ProviderFixtures.play(hosted, lines).result
        XCTAssertEqual(result.stop, .contentFilter)
        XCTAssertEqual(result.calls, [])
    }

    func testAMidStreamErrorFailsTheTurnLikeItsCode() throws {
        let played = try ProviderFixtures.play(hosted, fixture: "chat/stream-error.sse")
        XCTAssertEqual(played.result.stop, .failed(.overloaded))
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testAStreamWithNoEndingIsUnreadable() throws {
        let lines = try ProviderFixtures.lines("chat/stream-fragmented.sse")
            .filter { !$0.contains("finish_reason\":\"tool_calls") && !$0.contains("[DONE]") }
        XCTAssertEqual(ProviderFixtures.play(hosted, lines).result.stop, .failed(.unreadable))
    }

    func testAWholeMessageFromAServerThatIgnoredStreamIsRead() {
        let lines = [#"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}]}"#]
        let played = ProviderFixtures.play(local, lines)
        XCTAssertEqual(played.texts, ["Hello"])
        XCTAssertEqual(played.result.stop, .endTurn)
    }

    func testArgumentsSentAsAnObjectAreTakenWhole() throws {
        let lines = [#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"o","function":{"name":"list_folder","arguments":{"folder":"r1"}}}]},"finish_reason":"tool_calls"}]}"#]
        let call = try XCTUnwrap(ProviderFixtures.play(local, lines).result.calls.first)
        XCTAssertEqual(try AgentJSON(data: call.arguments), .object(["folder": .string("r1")]))
    }

    // MARK: Structured answers and errors

    func testAStructuredAnswerIsFoundInsideAFencedBlock() throws {
        let answer = try hosted.structuredAnswer(from: ProviderFixtures.data("chat/structured-reply.json"))
        XCTAssertEqual(try AgentJSON(data: answer), ProviderFixtures.object(#"{"sort": "newest", "queries": []}"#))
    }

    func testAStructuredRefusalOrErrorThrows() {
        let refusal = Data(#"{"choices":[{"message":{"role":"assistant","content":null,"refusal":"No."}}]}"#.utf8)
        XCTAssertThrowsError(try hosted.structuredAnswer(from: refusal)) { XCTAssertEqual($0 as? AgentFailure, .unreadable) }
        let error = Data(#"{"error":{"message":"m","type":"invalid_request_error","code":"model_not_found"}}"#.utf8)
        XCTAssertThrowsError(try hosted.structuredAnswer(from: error)) { XCTAssertEqual($0 as? AgentFailure, .noSuchModel) }
    }

    func testFailuresMapByStatusAndBody() throws {
        XCTAssertEqual(hosted.failure(status: 400, body: try ProviderFixtures.data("errors/gemini-bad-key.json")), .wrongKey)
        XCTAssertEqual(local.failure(status: 400, body: try ProviderFixtures.data("errors/ollama-no-tools.json")), .noTools)
        XCTAssertEqual(local.failure(status: 404, body: Data(#"{"error":"model 'qwen9' not found"}"#.utf8)), .noSuchModel)
    }

    func testGeminiWantingBillingIsOutOfCreditOnThisWireAsWithTheProviderKnown() {
        let body = Data(#"{"error":{"code":400,"message":"Billing required","status":"FAILED_PRECONDITION"}}"#.utf8)
        XCTAssertEqual(hosted.failure(status: 400, body: body), .outOfCredit)
        XCTAssertEqual(hosted.failure(status: 400, body: body), AgentErrorMapper.failure(status: 400, body: body, provider: .gemini))
        // The same answer arriving inside a stream.
        let lines = [#"data: {"error":{"code":400,"message":"Billing required","status":"FAILED_PRECONDITION"}}"#]
        XCTAssertEqual(ProviderFixtures.play(hosted, lines).result.stop, .failed(.outOfCredit))
    }
}
