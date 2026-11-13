import XCTest
import HelmCore
@testable import HelmAgent

/// Claude's Messages wire: the bytes of each body, what a recorded stream becomes, and that a model's turn goes
/// back into the next request exactly as it came.
final class AnthropicMessagesAdapterTests: XCTestCase {
    private let adapter = AnthropicMessagesAdapter()

    /// A conversation one tool round in: the person's message, the model's turn with thinking and two calls, and
    /// the two results, one of them an error.
    static func history() throws -> [AgentJSON] {
        let adapter = AnthropicMessagesAdapter()
        return adapter.userItems(text: ProviderFixtures.message, toolResults: [])
            + [try ProviderFixtures.json("anthropic/stream-tool-item.json")]
            + adapter.userItems(text: nil, toolResults: [
                AgentToolResult(callID: "toolu_01A09q90qw90lq917835lq9", name: "list_folder",
                                json: #"{"source":"folder_listing","items":[]}"#),
                AgentToolResult(callID: "toolu_02B", name: "list_folder", json: #"{"source":"error","code":"unknown_id"}"#,
                                isError: true)
            ])
    }

    private func input() throws -> AgentTurnInput {
        AgentTurnInput(system: ProviderFixtures.system, tools: [ProviderFixtures.tool], history: try Self.history())
    }

    // MARK: Bodies

    func testTurnBodyMatchesItsFixtureByteForByte() throws {
        let body = try adapter.turnBody(input(), model: ProviderFixtures.model)
        try ProviderFixtures.assertSameBytes(body, "anthropic/turn-request.json")
        try ProviderFixtures.assertNothingForbidden(body)
    }

    func testTurnBodyHoldsWhatClaudeNeedsAndNothingElse() throws {
        let body = try AgentJSON(data: adapter.turnBody(input(), model: ProviderFixtures.model))
        XCTAssertEqual(Set(body.objectValue.map { Array($0.keys) } ?? []),
                       ["model", "max_tokens", "stream", "system", "messages", "tools", "cache_control"])
        XCTAssertEqual(body["max_tokens"], .number(16_000))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["system"], .string(ProviderFixtures.system))
        XCTAssertEqual(body["cache_control"], .object(["type": .string("ephemeral")]))
        let tool = try XCTUnwrap(body["tools"]?.arrayValue?.first)
        XCTAssertEqual(tool["input_schema"], ProviderFixtures.tool.schema)
        XCTAssertEqual(tool["strict"], .bool(true))
        XCTAssertNil(tool["type"])
    }

    func testHistoryGoesOutUnchanged() throws {
        let history = try Self.history()
        let body = try AgentJSON(data: adapter.turnBody(input(), model: ProviderFixtures.model))
        XCTAssertEqual(body["messages"], .array(history))
        // The thinking block keeps its empty text and its signature.
        let thinking = body["messages"]?.arrayValue?[1]["content"]?.arrayValue?.first
        XCTAssertEqual(thinking, .object(["type": .string("thinking"), "thinking": .string(""),
                                          "signature": .string("EqQBCkYIBRgCKkBexampleSignature")]))
    }

    func testNoToolsMeansNoToolsMember() throws {
        let body = try AgentJSON(data: adapter.turnBody(AgentTurnInput(system: "", tools: [], history: try Self.history()),
                                                        model: ProviderFixtures.model))
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["system"])
    }

    func testStructuredBodyMatchesItsFixtureAndHasNoTools() throws {
        let body = try adapter.structuredBody(ProviderFixtures.ask, model: ProviderFixtures.model)
        try ProviderFixtures.assertSameBytes(body, "anthropic/structured-request.json")
        try ProviderFixtures.assertNothingForbidden(body)
        let json = try AgentJSON(data: body)
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["stream"])
        XCTAssertEqual(json["output_config"], .object(["format": .object(["type": .string("json_schema"),
                                                                          "schema": ProviderFixtures.ask.schema])]))
    }

    func testAModelNameNoProviderCouldListIsRefused() {
        XCTAssertThrowsError(try adapter.turnBody(AgentTurnInput(system: "", tools: [], history: []), model: "a model")) {
            XCTAssertEqual($0 as? AgentFailure, .noSuchModel)
        }
    }

    // MARK: User turns

    func testResultsComeFirstInOneMessageThenTheText() {
        let items = adapter.userItems(text: "Thanks", toolResults: [
            AgentToolResult(callID: "a", name: "list_folder", json: "{}"),
            AgentToolResult(callID: "b", name: "find_items", json: #"{"source":"error"}"#, isError: true)
        ])
        XCTAssertEqual(items, [ProviderFixtures.object("""
        {"role": "user", "content": [
          {"type": "tool_result", "tool_use_id": "a", "content": "{}"},
          {"type": "tool_result", "tool_use_id": "b", "content": "{\\"source\\":\\"error\\"}", "is_error": true},
          {"type": "text", "text": "Thanks"}]}
        """)])
    }

    func testAnEmptyTurnIsNoItemAndEmptyTextIsLeftOut() {
        XCTAssertEqual(adapter.userItems(text: nil, toolResults: []), [])
        XCTAssertEqual(adapter.userItems(text: "", toolResults: []), [])
        let items = adapter.userItems(text: "", toolResults: [AgentToolResult(callID: "a", name: "list_folder", json: "{}")])
        XCTAssertEqual(items.first?["content"]?.arrayValue?.count, 1)
    }

    // MARK: Streams

    func testAToolStreamGivesTextCallsAndTheTurnAsItCame() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "anthropic/stream-tool.sse")
        XCTAssertEqual(played.texts, ["I'll look at ", "the folder."])
        XCTAssertEqual(played.tools, ["list_folder", "list_folder"])
        XCTAssertEqual(played.result.stop, .toolUse)
        XCTAssertEqual(played.result.rawItems, [try ProviderFixtures.json("anthropic/stream-tool-item.json")])
        XCTAssertEqual(played.result.calls.map(\.id), ["toolu_01A09q90qw90lq917835lq9", "toolu_02B"])
        // A fragmented call's input is its fragments joined, exactly as written.
        XCTAssertEqual(String(decoding: played.result.calls[0].arguments, as: UTF8.self),
                       #"{"folder": "r1", "depth": 1, "after": ""}"#)
        // A call that came whole in its first event keeps that input.
        XCTAssertEqual(try AgentJSON(data: played.result.calls[1].arguments),
                       ProviderFixtures.object(#"{"folder": "d7", "depth": 2, "after": ""}"#))
    }

    func testAStreamedTurnGoesBackIntoTheNextRequestUnchanged() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "anthropic/stream-tool.sse")
        var history = adapter.userItems(text: ProviderFixtures.message, toolResults: [])
        history += played.result.rawItems
        history += adapter.userItems(text: nil, toolResults: played.result.calls.map {
            AgentToolResult(callID: $0.id, name: $0.name, json: "{}")
        })
        let body = try AgentJSON(data: adapter.turnBody(AgentTurnInput(system: ProviderFixtures.system,
                                                                        tools: [ProviderFixtures.tool], history: history),
                                                        model: ProviderFixtures.model))
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages[1], played.result.rawItems[0])
        XCTAssertEqual(messages[2]["content"]?.arrayValue?.compactMap { $0["tool_use_id"]?.stringValue },
                       ["toolu_01A09q90qw90lq917835lq9", "toolu_02B"])
    }

    func testATextStreamEndsTheTurn() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "anthropic/stream-text.sse")
        XCTAssertEqual(played.texts.joined(), "The plan is ready for you to check.")
        XCTAssertEqual(played.result.stop, .endTurn)
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [ProviderFixtures.object("""
        {"role": "assistant", "content": [{"type": "text", "text": "The plan is ready for you to check."}]}
        """)])
    }

    func testARefusalKeepsNothingAndHandsOnNoCall() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "anthropic/stream-refusal.sse")
        XCTAssertEqual(played.result.stop, .refusal)
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testMaxTokensWithATrailingCallRunsNothing() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "anthropic/stream-max-tokens.sse")
        XCTAssertEqual(played.texts, ["Moving the photos."])
        XCTAssertEqual(played.result.stop, .maxTokens)
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testAMidStreamErrorFailsTheTurnLikeItsStatus() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "anthropic/stream-error.sse")
        XCTAssertEqual(played.result.stop, .failed(.overloaded))
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testAStreamCutOffBeforeItsStopReasonIsUnreadable() throws {
        let lines = try ProviderFixtures.lines("anthropic/stream-text.sse").filter { !$0.contains("message_delta") }
        XCTAssertEqual(ProviderFixtures.play(adapter, lines).result.stop, .failed(.unreadable))
    }

    func testABrokenOrTooDeepLineMakesTheTurnUnreadable() throws {
        var lines = try ProviderFixtures.lines("anthropic/stream-text.sse")
        lines.insert(#"data: {"type":"content_block_delta","index":0,"#, at: 4)
        XCTAssertEqual(ProviderFixtures.play(adapter, lines).result.stop, .failed(.unreadable))

        var deep = try ProviderFixtures.lines("anthropic/stream-text.sse")
        let nested = String(repeating: #"{"a":"#, count: 40) + "1" + String(repeating: "}", count: 40)
        deep.insert("data: " + nested, at: 4)
        XCTAssertEqual(ProviderFixtures.play(adapter, deep).result.stop, .failed(.unreadable))
    }

    func testInputThatIsNotJSONGoesToTheToolAsWrittenAndTheHistoryKeepsAnObject() {
        let lines = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"list_folder","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"folder\": "}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#
        ]
        let result = ProviderFixtures.play(adapter, lines).result
        XCTAssertEqual(result.stop, .toolUse)
        XCTAssertEqual(result.calls.map { String(decoding: $0.arguments, as: UTF8.self) }, [#"{"folder": "#])
        XCTAssertEqual(result.rawItems.first?["content"]?.arrayValue?.first?["input"], .object([:]))
    }

    // MARK: Structured answers and errors

    func testAStructuredAnswerIsTheFirstObjectInTheText() throws {
        let answer = try adapter.structuredAnswer(from: ProviderFixtures.data("anthropic/structured-reply.json"))
        XCTAssertEqual(try AgentJSON(data: answer), ProviderFixtures.object(
            #"{"sort": "relevance", "queries": [{"words": ["invoice"], "note": "a {brace} in a string"}]}"#))
    }

    func testAStructuredRefusalOrErrorThrows() throws {
        let refusal = Data(#"{"type":"message","content":[{"type":"text","text":"{\"sort\":\"x\"}"}],"stop_reason":"refusal"}"#.utf8)
        XCTAssertThrowsError(try adapter.structuredAnswer(from: refusal)) { XCTAssertEqual($0 as? AgentFailure, .unreadable) }
        let error = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
        XCTAssertThrowsError(try adapter.structuredAnswer(from: error)) { XCTAssertEqual($0 as? AgentFailure, .overloaded) }
        let words = Data(#"{"type":"message","content":[{"type":"text","text":"no json here"}],"stop_reason":"end_turn"}"#.utf8)
        XCTAssertThrowsError(try adapter.structuredAnswer(from: words)) { XCTAssertEqual($0 as? AgentFailure, .unreadable) }
    }

    func testFailuresMapByStatus() throws {
        XCTAssertEqual(adapter.failure(status: 401, body: Data()), .wrongKey)
        XCTAssertEqual(adapter.failure(status: 529, body: Data()), .overloaded)
        XCTAssertEqual(adapter.failure(status: 429, body: try ProviderFixtures.data("errors/claude-spend-limit.json")), .outOfCredit)
    }
}
