import XCTest
import HelmCore
@testable import HelmAgent

/// The live client against a transport that records what it is sent and answers from recorded streams: a whole
/// tool round trip on each wire, a structured question, the model list, and the turns it must refuse.
final class LiveModelClientTests: XCTestCase {
    private struct Played {
        var texts: [String] = []
        var tools: [String] = []
        var result: AgentTurnResult?
    }

    private func profile(_ id: AgentProviderID) throws -> AgentProviderProfile {
        switch id {
        case .claude, .openAI, .gemini, .grok: return AgentProviderProfile(id: id, endpoint: try AgentEndpoint(fixed: id))
        case .ollama, .lmStudio: return AgentProviderProfile(id: id, endpoint: try AgentEndpoint(localPort: 11434))
        case .other: return AgentProviderProfile(id: id, endpoint: try AgentEndpoint(typed: "models.example.com/v1"))
        }
    }

    private func play(_ client: LiveModelClient, _ input: AgentTurnInput) async throws -> Played {
        var played = Played()
        for try await event in client.turn(input) {
            XCTAssertNil(played.result, "nothing comes after the result")
            switch event {
            case .text(let text): played.texts.append(text)
            case .toolStarted(let name): played.tools.append(name)
            case .finished(let result): played.result = result
            }
        }
        return played
    }

    private func lines(_ name: String) throws -> Result<[String], AgentTransportError> { .success(try ProviderFixtures.lines(name)) }

    /// A Responses turn that only says something.
    private let responsesText: Result<[String], AgentTransportError> = .success([
        #"data: {"type":"response.output_text.delta","delta":"Done."}"#,
        #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
        #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"#
    ])

    // MARK: A tool round trip on each wire

    private func roundTrip(_ provider: AgentProviderID, first: Result<[String], AgentTransportError>,
                           second: Result<[String], AgentTransportError>, firstTools: [String]) async throws {
        let transport = ProviderRecordingTransport(streams: [first, second])
        let client = LiveModelClient(profile: try profile(provider), model: ProviderFixtures.model, transport: transport)
        var history = client.userItems(text: ProviderFixtures.message, toolResults: [])

        let one = try await play(client, AgentTurnInput(system: ProviderFixtures.system, tools: [ProviderFixtures.tool], history: history))
        let turn = try XCTUnwrap(one.result)
        XCTAssertEqual(turn.stop, .toolUse, "\(provider)")
        XCTAssertEqual(one.tools, firstTools, "\(provider)")
        XCTAssertFalse(turn.calls.isEmpty)
        history += turn.rawItems
        history += client.userItems(text: nil, toolResults: turn.calls.map {
            AgentToolResult(callID: $0.id, name: $0.name, json: #"{"source":"folder_listing","items":[]}"#)
        })

        let two = try await play(client, AgentTurnInput(system: ProviderFixtures.system, tools: [ProviderFixtures.tool], history: history))
        XCTAssertEqual(two.result?.stop, .endTurn, "\(provider)")
        XCTAssertEqual(two.result?.calls, [])

        let sent = transport.sent
        XCTAssertEqual(sent.map(\.route), [.chat, .chat])
        // The second request carries the first turn's items unchanged, then the results, under the call ids.
        let field = provider == .claude ? "messages" : (provider == .openAI || provider == .grok ? "input" : "messages")
        var carried = try XCTUnwrap(sent[1].json[field]?.arrayValue)
        if field == "messages", provider != .claude { carried.removeFirst() }
        XCTAssertEqual(carried, history, "\(provider)")
        let text = String(decoding: sent[1].body, as: UTF8.self)
        for call in turn.calls { XCTAssertTrue(text.contains(call.id), "\(provider) \(call.id)") }
        for request in sent {
            try ProviderFixtures.assertNothingForbidden(request.body)
            XCTAssertEqual(request.json["stream"], .bool(true))
        }
    }

    func testAToolRoundTripOnClaudesWire() async throws {
        try await roundTrip(.claude, first: lines("anthropic/stream-tool.sse"), second: lines("anthropic/stream-text.sse"),
                            firstTools: ["list_folder", "list_folder"])
    }

    func testAToolRoundTripOnTheResponsesWire() async throws {
        try await roundTrip(.openAI, first: lines("responses/stream-tool.sse"), second: responsesText, firstTools: ["list_folder"])
        try await roundTrip(.grok, first: lines("responses/stream-whole-call.sse"), second: responsesText,
                            firstTools: ["list_folder", "find_items"])
    }

    func testAToolRoundTripOnTheChatCompletionsWire() async throws {
        try await roundTrip(.gemini, first: lines("chat/stream-whole-gemini.sse"), second: lines("chat/stream-text.sse"),
                            firstTools: ["list_folder", "find_items"])
        try await roundTrip(.ollama, first: lines("chat/stream-fragmented.sse"), second: lines("chat/stream-text.sse"),
                            firstTools: ["list_folder"])
    }

    func testAHostedChatServerGetsATokenCeilingAndALocalOneDoesNot() async throws {
        for (provider, ceiling) in [(AgentProviderID.gemini, true), (.other, true), (.ollama, false), (.lmStudio, false)] {
            let transport = ProviderRecordingTransport(streams: [try lines("chat/stream-text.sse")])
            let client = LiveModelClient(profile: try profile(provider), model: ProviderFixtures.model, transport: transport)
            _ = try await play(client, AgentTurnInput(system: "", tools: [], history: client.userItems(text: "Hi", toolResults: [])))
            XCTAssertEqual(transport.sent.first?.json["max_tokens"] != nil, ceiling, "\(provider)")
        }
    }

    // MARK: Turns that are refused

    func testARepeatedCallIDFinishesUnreadableWithNoCallHandedOn() async throws {
        let repeated: [String] = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_same","name":"list_folder","input":{"folder":"r1","depth":1,"after":""}}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_same","name":"list_folder","input":{"folder":"r2","depth":1,"after":""}}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"data: {"type":"message_stop"}"#
        ]
        let client = LiveModelClient(profile: try profile(.claude), model: ProviderFixtures.model,
                                     transport: ProviderRecordingTransport(streams: [.success(repeated)]))
        let played = try await play(client, AgentTurnInput(system: "", tools: [ProviderFixtures.tool], history: []))
        XCTAssertEqual(played.result?.stop, .failed(.unreadable))
        XCTAssertEqual(played.result?.calls, [])
        XCTAssertEqual(played.result?.rawItems, [])
    }

    private func chatCall(id: String) -> [String] {
        [#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"\#(id)","type":"function","function":{"name":"list_folder","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
         "data: [DONE]"]
    }

    func testACallIDOf129CharactersFinishesUnreadableWithNoCallHandedOn() async throws {
        let tooLong = String(repeating: "c", count: 129), longest = String(repeating: "c", count: 128)
        let transport = ProviderRecordingTransport(streams: [.success(chatCall(id: tooLong)), .success(chatCall(id: longest))])
        let client = LiveModelClient(profile: try profile(.lmStudio), model: ProviderFixtures.model, transport: transport)
        let input = AgentTurnInput(system: "", tools: [ProviderFixtures.tool], history: [])

        let refused = try await play(client, input)
        XCTAssertEqual(refused.result?.stop, .failed(.unreadable))
        XCTAssertEqual(refused.result?.calls, [])
        XCTAssertEqual(refused.result?.rawItems, [])

        let kept = try await play(client, input)
        XCTAssertEqual(kept.result?.stop, .toolUse)
        XCTAssertEqual(kept.result?.calls.map(\.id), [longest])
    }

    func testARefusalHandsOnNoCall() async throws {
        let client = LiveModelClient(profile: try profile(.openAI), model: ProviderFixtures.model,
                                     transport: ProviderRecordingTransport(streams: [try lines("responses/stream-refusal.sse")]))
        let played = try await play(client, AgentTurnInput(system: "", tools: [ProviderFixtures.tool], history: []))
        XCTAssertEqual(played.result?.stop, .refusal)
        XCTAssertEqual(played.result?.calls, [])
    }

    func testAFailedRequestThrowsItsFailure() async throws {
        let spend = try ProviderFixtures.data("errors/claude-spend-limit.json")
        let cases: [(AgentProviderID, AgentTransportError, AgentFailure)] = [
            (.claude, .http(status: 429, body: spend), .outOfCredit), (.ollama, .notRunning, .notRunning),
            (.claude, .proxyAuth, .unreachable), (.gemini, .noKey, .noKey)
        ]
        for (provider, error, failure) in cases {
            let client = LiveModelClient(profile: try profile(provider), model: ProviderFixtures.model,
                                         transport: ProviderRecordingTransport(streams: [.failure(error)]))
            do {
                _ = try await play(client, AgentTurnInput(system: "", tools: [], history: []))
                XCTFail("\(error) should fail the turn")
            } catch {
                XCTAssertEqual(error as? AgentFailure, failure, "\(provider)")
            }
        }
    }

    func testABadModelNameIsNeverSent() async throws {
        let transport = ProviderRecordingTransport(streams: [try lines("anthropic/stream-text.sse")])
        let client = LiveModelClient(profile: try profile(.claude), model: "two words", transport: transport)
        do {
            _ = try await play(client, AgentTurnInput(system: "", tools: [], history: []))
            XCTFail("a model name with a space should be refused")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .noSuchModel)
        }
        XCTAssertEqual(transport.sent.count, 0)
    }

    // MARK: Structured questions

    func testAStructuredAskSendsNoToolsAndReadsTheAnswer() async throws {
        let cases: [(AgentProviderID, String, AgentJSON)] = [
            (.claude, "anthropic/structured-reply.json",
             ProviderFixtures.object(#"{"sort": "relevance", "queries": [{"words": ["invoice"], "note": "a {brace} in a string"}]}"#)),
            (.openAI, "responses/structured-reply.json", ProviderFixtures.object(#"{"ranked": [{"row": 2, "why": ["name"]}]}"#)),
            (.gemini, "chat/structured-reply.json", ProviderFixtures.object(#"{"sort": "newest", "queries": []}"#))
        ]
        for (provider, fixture, expected) in cases {
            let transport = ProviderRecordingTransport(streams: [try lines(fixture)])
            let client = LiveModelClient(profile: try profile(provider), model: ProviderFixtures.model, transport: transport)
            let answer = try await client.structured(ProviderFixtures.ask)
            XCTAssertEqual(try AgentJSON(data: answer), expected, "\(provider)")
            let sent = try XCTUnwrap(transport.sent.first)
            XCTAssertEqual(sent.route, .chat)
            XCTAssertNil(sent.json["tools"], "\(provider)")
            XCTAssertNil(sent.json["stream"], "\(provider)")
            try ProviderFixtures.assertNothingForbidden(sent.body)
        }
    }

    func testAStructuredAskThatFailsThrowsItsFailure() async throws {
        let client = LiveModelClient(profile: try profile(.claude), model: ProviderFixtures.model,
                                     transport: ProviderRecordingTransport(streams: [.failure(.http(status: 529, body: Data()))]))
        do {
            _ = try await client.structured(ProviderFixtures.ask)
            XCTFail("an overloaded provider should fail the ask")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .overloaded)
        }
    }

    // MARK: Models

    func testModelsComeFromTheModelsRoute() async throws {
        let transport = ProviderRecordingTransport(fetches: [.models: .success(AgentHTTPReply(status: 200, body: try ProviderFixtures.data("models/claude.json")))])
        let client = LiveModelClient(profile: try profile(.claude), model: ProviderFixtures.model, transport: transport)
        let models = try await client.models()
        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"])
        XCTAssertEqual(transport.fetched, [.models])
        XCTAssertEqual(transport.sent.count, 0)
    }

    func testAModelListThatFailsThrowsItsFailure() async throws {
        let badKey = try ProviderFixtures.data("errors/gemini-bad-key.json")
        let cases: [(AgentProviderID, Result<AgentHTTPReply, AgentTransportError>, AgentFailure)] = [
            (.gemini, .success(AgentHTTPReply(status: 400, body: badKey)), .wrongKey),
            (.gemini, .failure(.http(status: 400, body: badKey)), .wrongKey),
            (.ollama, .failure(.notRunning), .notRunning),
            (.claude, .failure(.proxyAuth), .unreachable)
        ]
        for (provider, reply, failure) in cases {
            let client = LiveModelClient(profile: try profile(provider), model: ProviderFixtures.model,
                                         transport: ProviderRecordingTransport(fetches: [.models: reply]))
            do {
                _ = try await client.models()
                XCTFail("the list should fail")
            } catch {
                XCTAssertEqual(error as? AgentFailure, failure, "\(provider)")
            }
        }
    }

    func testATypedAddressIsAskedAgainUnderV1() async throws {
        let transport = ProviderRecordingTransport(fetches: [
            .models: .success(AgentHTTPReply(status: 404, body: Data("Not found".utf8))),
            .modelsAlternate: .success(AgentHTTPReply(status: 200, body: try ProviderFixtures.data("models/other.json")))
        ])
        let client = LiveModelClient(profile: try profile(.other), model: ProviderFixtures.model, transport: transport)
        let models = try await client.models()
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(transport.fetched, [.models, .modelsAlternate])
    }

    func testARefusedKeyIsNotAskedTwice() async throws {
        let transport = ProviderRecordingTransport(fetches: [
            .models: .success(AgentHTTPReply(status: 401, body: Data())),
            .modelsAlternate: .success(AgentHTTPReply(status: 200, body: try ProviderFixtures.data("models/other.json")))
        ])
        let client = LiveModelClient(profile: try profile(.other), model: ProviderFixtures.model, transport: transport)
        do {
            _ = try await client.models()
            XCTFail("a refused key should fail the list")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .wrongKey)
        }
        XCTAssertEqual(transport.fetched, [.models])
    }

    /// A typed address, and LM Studio, which has its own list and an OpenAI-style one, look in a second place;
    /// every other provider has one list.
    func testOnlyATypedAddressAndLMStudioHaveASecondPlaceToLook() async throws {
        let transport = ProviderRecordingTransport(fetches: [.models: .success(AgentHTTPReply(status: 404, body: Data()))])
        let client = LiveModelClient(profile: try profile(.ollama), model: ProviderFixtures.model, transport: transport)
        do {
            _ = try await client.models()
            XCTFail("a missing list should fail")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .noSuchModel)
        }
        XCTAssertEqual(transport.fetched, [.models])
        // An LM Studio without its own list is asked for its other one, which names no model that sees pictures.
        let older = ProviderRecordingTransport(fetches: [
            .models: .success(AgentHTTPReply(status: 404, body: Data())),
            .modelsAlternate: .success(AgentHTTPReply(status: 200, body: Data(#"{"data": [{"id": "qwen2.5-7b-instruct"}]}"#.utf8)))])
        let lmStudio = LiveModelClient(profile: try profile(.lmStudio), model: ProviderFixtures.model, transport: older)
        let listed = try await lmStudio.models()
        XCTAssertEqual(listed.map(\.id), ["qwen2.5-7b-instruct"])
        XCTAssertEqual(listed.map(\.seesPictures), [nil])
        XCTAssertEqual(older.fetched, [.models, .modelsAlternate])
    }

    // MARK: The client itself

    func testItIsNamedForItsProfileAndShutsItsTransportDown() async throws {
        let transport = ProviderRecordingTransport()
        let ollama = LiveModelClient(profile: try profile(.ollama), model: "qwen3:8b", transport: transport)
        XCTAssertEqual(ollama.providerName, "Ollama")
        XCTAssertEqual(ollama.destination, AgentText.destinationOnThisMac("Ollama"))
        XCTAssertTrue(ollama.isLocal)
        let claude = LiveModelClient(profile: try profile(.claude), model: "claude-opus-5-5", transport: transport)
        XCTAssertEqual(claude.providerName, "Claude")
        XCTAssertFalse(claude.isLocal)
        await claude.shutdown()
        XCTAssertEqual(transport.shutDownCount, 1)
    }

    func testEachWireGetsItsAdapter() throws {
        XCTAssertTrue(LiveModelClient.adapter(for: .anthropicMessages, profile: try profile(.claude)) is AnthropicMessagesAdapter)
        XCTAssertTrue(LiveModelClient.adapter(for: .openAIResponses, profile: try profile(.grok)) is OpenAIResponsesAdapter)
        XCTAssertTrue(LiveModelClient.adapter(for: .chatCompletions, profile: try profile(.gemini)) is ChatCompletionsAdapter)
    }

    /// LM Studio alone gets an answer's shape in the prompt: a `response_format` there stops gpt-oss from thinking.
    func testOnlyLMStudioGetsTheSchemaInThePrompt() throws {
        for id in [AgentProviderID.gemini, .ollama, .other, .lmStudio] {
            let adapter = LiveModelClient.adapter(for: .chatCompletions, profile: try profile(id))
            let body = try AgentJSON(data: adapter.structuredBody(ProviderFixtures.ask, model: ProviderFixtures.model))
            let system = body["messages"]?.arrayValue?.first?["content"]?.stringValue ?? ""
            XCTAssertEqual(body["response_format"] == nil, id == .lmStudio, "\(id)")
            XCTAssertEqual(system.contains(ChatCompletionsAdapter.schemaLead), id == .lmStudio, "\(id)")
        }
    }
}
