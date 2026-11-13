import XCTest
import HelmCore
@testable import HelmAgent

/// The Responses wire used for OpenAI and Grok: the bytes of each body, what a recorded stream becomes, and that
/// every output item, reasoning included, goes back exactly as it came.
final class OpenAIResponsesAdapterTests: XCTestCase {
    private let adapter = OpenAIResponsesAdapter()

    /// The person's message, the model's three output items, and the call's result.
    static func history() throws -> [AgentJSON] {
        let adapter = OpenAIResponsesAdapter()
        return adapter.userItems(text: ProviderFixtures.message, toolResults: [])
            + (try ProviderFixtures.json("responses/stream-tool-items.json").arrayValue ?? [])
            + adapter.userItems(text: nil, toolResults: [
                AgentToolResult(callID: "call_12345xyz", name: "list_folder", json: #"{"source":"folder_listing","items":[]}"#)
            ])
    }

    private func input() throws -> AgentTurnInput {
        AgentTurnInput(system: ProviderFixtures.system, tools: [ProviderFixtures.tool], history: try Self.history())
    }

    // MARK: Bodies

    func testTurnBodyMatchesItsFixtureByteForByte() throws {
        let body = try adapter.turnBody(input(), model: ProviderFixtures.model)
        try ProviderFixtures.assertSameBytes(body, "responses/turn-request.json")
        try ProviderFixtures.assertNothingForbidden(body)
    }

    func testEveryBodyStoresNothingAndAsksForReasoningBack() throws {
        for body in [try adapter.turnBody(input(), model: ProviderFixtures.model),
                     try adapter.structuredBody(ProviderFixtures.ask, model: ProviderFixtures.model)] {
            let json = try AgentJSON(data: body)
            XCTAssertEqual(json["store"], .bool(false))
            XCTAssertEqual(json["include"], .array([.string("reasoning.encrypted_content")]))
            XCTAssertEqual(json["instructions"]?.stringValue?.isEmpty, false)
        }
    }

    func testTurnBodyHoldsFlatStrictToolsAndTheHistoryUnchanged() throws {
        let body = try AgentJSON(data: adapter.turnBody(input(), model: ProviderFixtures.model))
        XCTAssertEqual(Set(body.objectValue.map { Array($0.keys) } ?? []),
                       ["model", "instructions", "input", "tools", "store", "include", "stream", "max_output_tokens"])
        XCTAssertEqual(body["input"], .array(try Self.history()))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["tools"], .array([.object([
            "type": .string("function"), "name": .string("list_folder"), "description": .string("List what is in a folder."),
            "parameters": ProviderFixtures.tool.schema, "strict": .bool(true)])]))
    }

    func testStructuredBodyMatchesItsFixtureAndHasNoTools() throws {
        let body = try adapter.structuredBody(ProviderFixtures.ask, model: ProviderFixtures.model)
        try ProviderFixtures.assertSameBytes(body, "responses/structured-request.json")
        try ProviderFixtures.assertNothingForbidden(body)
        let json = try AgentJSON(data: body)
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["stream"])
        XCTAssertEqual(json["text"]?["format"]?["name"], .string("search_plan"))
        XCTAssertEqual(json["text"]?["format"]?["schema"], ProviderFixtures.ask.schema)
    }

    // MARK: User turns

    func testResultsAreKeyedByCallIDAndComeBeforeTheText() {
        let items = adapter.userItems(text: "And the rest?", toolResults: [
            AgentToolResult(callID: "call_a", name: "list_folder", json: "{}"),
            AgentToolResult(callID: "call_b", name: "find_items", json: #"{"source":"error"}"#, isError: true)
        ])
        XCTAssertEqual(items, [
            ProviderFixtures.object(#"{"type": "function_call_output", "call_id": "call_a", "output": "{}"}"#),
            ProviderFixtures.object(#"{"type": "function_call_output", "call_id": "call_b", "output": "{\"source\":\"error\"}"}"#),
            ProviderFixtures.object(#"{"role": "user", "content": "And the rest?"}"#)
        ])
        XCTAssertEqual(adapter.userItems(text: nil, toolResults: []), [])
    }

    // MARK: Streams

    func testAToolStreamKeepsTheFinishedItemsInOrder() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "responses/stream-tool.sse")
        XCTAssertEqual(played.texts, ["Let me look ", "first."])
        XCTAssertEqual(played.tools, ["list_folder"])
        XCTAssertEqual(played.result.stop, .toolUse)
        // The reasoning item is the one from `done`, with its whole encrypted content, not the partial one.
        XCTAssertEqual(played.result.rawItems, try ProviderFixtures.json("responses/stream-tool-items.json").arrayValue)
        XCTAssertEqual(played.result.calls, [AgentToolCall(id: "call_12345xyz", name: "list_folder",
                                                           arguments: Data(#"{"folder":"r1","depth":1,"after":""}"#.utf8))])
    }

    func testAStreamedTurnGoesBackIntoTheNextRequestUnchanged() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "responses/stream-tool.sse")
        let history = adapter.userItems(text: ProviderFixtures.message, toolResults: []) + played.result.rawItems
            + adapter.userItems(text: nil, toolResults: [AgentToolResult(callID: "call_12345xyz", name: "list_folder", json: "{}")])
        let body = try AgentJSON(data: adapter.turnBody(AgentTurnInput(system: ProviderFixtures.system, tools: [], history: history),
                                                        model: ProviderFixtures.model))
        let sent = try XCTUnwrap(body["input"]?.arrayValue)
        XCTAssertEqual(Array(sent[1...3]), played.result.rawItems)
        XCTAssertEqual(sent[1]["encrypted_content"], .string("gAAAAexampleEncryptedReasoningComplete"))
        XCTAssertEqual(sent[4]["call_id"], .string("call_12345xyz"))
    }

    func testCallsSentWholeAreTakenFromTheirFinishedItems() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "responses/stream-whole-call.sse")
        XCTAssertEqual(played.tools, ["list_folder", "find_items"])
        XCTAssertEqual(played.result.stop, .toolUse)
        XCTAssertEqual(played.result.calls.map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(played.result.rawItems.count, 3)
        XCTAssertEqual(played.result.rawItems.first?["type"], .string("reasoning"))
    }

    func testARefusalKeepsNothingAndHandsOnNoCall() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "responses/stream-refusal.sse")
        XCTAssertEqual(played.result.stop, .refusal)
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testMaxOutputTokensWithATrailingCallRunsNothing() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "responses/stream-max-tokens.sse")
        XCTAssertEqual(played.result.stop, .maxTokens)
        XCTAssertEqual(played.result.calls, [])
        XCTAssertEqual(played.result.rawItems, [])
    }

    func testAnIncompleteResponseForContentIsAFilterStop() {
        let lines = [#"data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"content_filter"}}}"#]
        XCTAssertEqual(ProviderFixtures.play(adapter, lines).result.stop, .contentFilter)
    }

    func testAMidStreamErrorFailsTheTurnLikeItsCode() throws {
        let played = try ProviderFixtures.play(adapter, fixture: "responses/stream-error.sse")
        XCTAssertEqual(played.result.stop, .failed(.rateLimited))
        XCTAssertEqual(played.result.calls, [])
    }

    func testAFailedResponseIsAFailure() {
        let lines = [#"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"x"}}}"#]
        XCTAssertEqual(ProviderFixtures.play(adapter, lines).result.stop, .failed(.overloaded))
    }

    func testAStreamWithoutAnEndingIsUnreadable() throws {
        let lines = try ProviderFixtures.lines("responses/stream-tool.sse").filter { !$0.contains("response.completed") }
        XCTAssertEqual(ProviderFixtures.play(adapter, lines).result.stop, .failed(.unreadable))
    }

    func testItemsOnlyInTheCompletedResponseAreUsed() {
        let lines = [#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}]}}"#]
        let result = ProviderFixtures.play(adapter, lines).result
        XCTAssertEqual(result.stop, .endTurn)
        XCTAssertEqual(result.rawItems.count, 1)
    }

    // MARK: Structured answers and errors

    func testAStructuredAnswerIsTheFirstObjectInTheText() throws {
        let answer = try adapter.structuredAnswer(from: ProviderFixtures.data("responses/structured-reply.json"))
        XCTAssertEqual(try AgentJSON(data: answer), ProviderFixtures.object(#"{"ranked": [{"row": 2, "why": ["name"]}]}"#))
    }

    func testAStructuredRefusalOrErrorThrows() {
        let refusal = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No."}]}]}"#.utf8)
        XCTAssertThrowsError(try adapter.structuredAnswer(from: refusal)) { XCTAssertEqual($0 as? AgentFailure, .unreadable) }
        let error = Data(#"{"status":"failed","error":{"code":"rate_limit_exceeded","message":"x"}}"#.utf8)
        XCTAssertThrowsError(try adapter.structuredAnswer(from: error)) { XCTAssertEqual($0 as? AgentFailure, .rateLimited) }
    }

    func testFailuresMapByStatus() throws {
        XCTAssertEqual(adapter.failure(status: 401, body: Data()), .wrongKey)
        XCTAssertEqual(adapter.failure(status: 429, body: try ProviderFixtures.data("errors/openai-quota.json")), .outOfCredit)
        XCTAssertEqual(adapter.failure(status: 503, body: Data()), .overloaded)
    }
}
