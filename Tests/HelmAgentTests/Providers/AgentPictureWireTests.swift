import XCTest
import HelmCore
@testable import HelmAgent

/// Pictures on each wire: where a tool result's pictures and a structured question's pictures go, each after its
/// label, numbered across one user turn's results; what each provider's refusal of a picture maps to; and how the
/// scripted model keeps pictures without their bytes.
final class AgentPictureWireTests: XCTestCase {
    /// Three tiny stand-in JPEGs, told apart by their last byte: base64 "/9gB", "/9gC" and "/9gD".
    static func image(_ last: UInt8, width: Int = 512, height: Int = 384) -> AgentContentImage {
        AgentContentImage(jpeg: Data([0xFF, 0xD8, last]), width: width, height: height, source: .picture)
    }

    /// A turn's results: a read with two pictures, a listing with none, then a read with one.
    private let results = [
        AgentToolResult(callID: "call_a", name: "read_contents", json: #"{"x":1}"#, images: [image(1), image(2)]),
        AgentToolResult(callID: "call_b", name: "list_folder", json: "{}"),
        AgentToolResult(callID: "call_c", name: "read_contents", json: #"{"y":2}"#, images: [image(3, width: 300, height: 512)])
    ]

    private let ask = AgentStructuredAsk(system: "Look.", user: "Which show a dog?", schemaName: "look", schema: .object([:]),
                                         pictures: [AgentAskPicture(label: "Item 1", image: image(1)),
                                                    AgentAskPicture(label: "Item 2", image: image(2))])

    private func json(_ text: String) -> AgentJSON { ProviderFixtures.object(text) }

    // MARK: Claude

    func testClaudePutsEachResultsPicturesInsideItsToolResult() {
        let items = AnthropicMessagesAdapter().userItems(text: "Next", toolResults: results)
        let image = { (data: String) in #"{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\#(data)"}}"# }
        XCTAssertEqual(.array(items), json("""
        [{"role":"user","content":[
          {"type":"tool_result","tool_use_id":"call_a","content":[
            {"type":"text","text":"{\\"x\\":1}"},
            {"type":"text","text":"Picture 1"},\(image("/9gB")),
            {"type":"text","text":"Picture 2"},\(image("/9gC"))]},
          {"type":"tool_result","tool_use_id":"call_b","content":"{}"},
          {"type":"tool_result","tool_use_id":"call_c","content":[
            {"type":"text","text":"{\\"y\\":2}"},
            {"type":"text","text":"Picture 3"},\(image("/9gD"))]},
          {"type":"text","text":"Next"}]}]
        """))
    }

    func testClaudesStructuredQuestionWithPicturesIsBlocks() throws {
        let body = try AgentJSON(data: AnthropicMessagesAdapter().structuredBody(ask, model: ProviderFixtures.model))
        XCTAssertEqual(body["messages"], json("""
        [{"role":"user","content":[
          {"type":"text","text":"Which show a dog?"},
          {"type":"text","text":"Item 1"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"/9gB"}},
          {"type":"text","text":"Item 2"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"/9gC"}}]}]
        """))
    }

    // MARK: Responses

    private let responsesPictures = """
    {"role":"user","content":[
      {"type":"input_text","text":"Pictures from read_contents, as its items name them:"},
      {"type":"input_text","text":"Picture 1"},{"type":"input_image","image_url":"data:image/jpeg;base64,/9gB","detail":"low"},
      {"type":"input_text","text":"Picture 2"},{"type":"input_image","image_url":"data:image/jpeg;base64,/9gC","detail":"low"},
      {"type":"input_text","text":"Picture 3"},{"type":"input_image","image_url":"data:image/jpeg;base64,/9gD","detail":"low"}]}
    """

    func testResponsesKeepsTheOutputsAsJSONThenOneMessageOfPicturesThenTheText() {
        for adapter in [OpenAIResponsesAdapter(), OpenAIResponsesAdapter(planUsage: true)] {
            let items = adapter.userItems(text: "Next", toolResults: results)
            XCTAssertEqual(.array(items), json("""
            [{"type":"function_call_output","call_id":"call_a","output":"{\\"x\\":1}"},
             {"type":"function_call_output","call_id":"call_b","output":"{}"},
             {"type":"function_call_output","call_id":"call_c","output":"{\\"y\\":2}"},
             \(responsesPictures),
             {"role":"user","content":"Next"}]
            """), "plan use \(adapter.planUsage)")
            XCTAssertEqual(adapter.userItems(text: nil, toolResults: results).last, json(responsesPictures))
        }
    }

    func testResponsesStructuredQuestionWithPicturesIsParts() throws {
        let body = try AgentJSON(data: OpenAIResponsesAdapter().structuredBody(ask, model: ProviderFixtures.model))
        XCTAssertEqual(body["input"], json("""
        [{"role":"user","content":[
          {"type":"input_text","text":"Which show a dog?"},
          {"type":"input_text","text":"Item 1"},{"type":"input_image","image_url":"data:image/jpeg;base64,/9gB","detail":"low"},
          {"type":"input_text","text":"Item 2"},{"type":"input_image","image_url":"data:image/jpeg;base64,/9gC","detail":"low"}]}]
        """))
    }

    // MARK: Chat Completions

    func testChatCompletionsKeepsToolMessagesAsTextThenOneMessageOfPicturesThenTheText() {
        for adapter in [ChatCompletionsAdapter(sendsMaxTokens: true), ChatCompletionsAdapter(sendsMaxTokens: false)] {
            let items = adapter.userItems(text: "Next", toolResults: results)
            XCTAssertEqual(.array(items), json("""
            [{"role":"tool","tool_call_id":"call_a","content":"{\\"x\\":1}"},
             {"role":"tool","tool_call_id":"call_b","content":"{}"},
             {"role":"tool","tool_call_id":"call_c","content":"{\\"y\\":2}"},
             {"role":"user","content":[
               {"type":"text","text":"Pictures from read_contents, as its items name them:"},
               {"type":"text","text":"Picture 1"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9gB"}},
               {"type":"text","text":"Picture 2"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9gC"}},
               {"type":"text","text":"Picture 3"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9gD"}}]},
             {"role":"user","content":"Next"}]
            """))
        }
    }

    func testChatCompletionsStructuredQuestionWithPicturesIsParts() throws {
        let body = try AgentJSON(data: ChatCompletionsAdapter(sendsMaxTokens: true).structuredBody(ask, model: ProviderFixtures.model))
        XCTAssertEqual(body["messages"], json("""
        [{"role":"system","content":"Look."},
         {"role":"user","content":[
          {"type":"text","text":"Which show a dog?"},
          {"type":"text","text":"Item 1"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9gB"}},
          {"type":"text","text":"Item 2"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9gC"}}]}]
        """))
    }

    // MARK: Without pictures

    func testWithoutPicturesEveryWireSendsWhatItAlwaysSent() throws {
        let plain = results.map(\.withoutImages)
        let words = AgentStructuredAsk(system: ask.system, user: ask.user, schemaName: ask.schemaName, schema: ask.schema)
        let adapters: [any AgentWireAdapter] = [AnthropicMessagesAdapter(), OpenAIResponsesAdapter(), ChatCompletionsAdapter(sendsMaxTokens: true)]
        for adapter in adapters {
            let items = adapter.userItems(text: "Next", toolResults: plain)
            let sent = String(decoding: AgentJSON.array(items).data(), as: UTF8.self)
            for word in ["image", "Picture", "base64"] { XCTAssertFalse(sent.contains(word), "\(type(of: adapter)): \(word)") }
            XCTAssertEqual(items.count, adapter is AnthropicMessagesAdapter ? 1 : 4)
            let body = String(decoding: try adapter.structuredBody(words, model: ProviderFixtures.model), as: UTF8.self)
            XCTAssertTrue(body.contains(#""content":"Which show a dog?""#), "\(type(of: adapter)): the question is a string as before")
        }
        // The bodies' fixtures, byte for byte, are the adapters' own tests; a turn's pictures add only to that turn.
        XCTAssertEqual(AnthropicMessagesAdapter().userItems(text: nil, toolResults: [results[1]]),
                       [json(#"{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_b","content":"{}"}]}"#)])
    }

    func testLabelsAreNumberedAcrossOneTurnsResults() {
        let labels = AgentToolResult.labeledPictures(results).map { $0.map(\.label) }
        XCTAssertEqual(labels, [["Picture 1", "Picture 2"], [], ["Picture 3"]])
        XCTAssertEqual(AgentWireParts.dataURL(Self.image(1)), "data:image/jpeg;base64,/9gB")
    }

    // MARK: A provider refusing a picture

    func testEachProvidersRefusalOfAPictureIsABadRequest() {
        let claude = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0.content.2.image.source.base64.data: Could not process image"}}"#.utf8)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: claude, provider: .claude), .badRequest)
        let openAI = Data(#"{"error":{"message":"Invalid content type. image_url is only supported by certain models.","type":"invalid_request_error","param":"input[3].content[1]","code":null}}"#.utf8)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: openAI, provider: .openAI), .badRequest)
        XCTAssertEqual(AgentErrorMapper.chatGPTFailure(status: 400, body: openAI), .badRequest)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: openAI, provider: .grok), .badRequest)
        XCTAssertEqual(AgentErrorMapper.failure(status: 422, body: Data(), provider: .grok), .badRequest)
        let gemini = Data(#"[{"error":{"code":400,"message":"Unable to process input image.","status":"INVALID_ARGUMENT"}}]"#.utf8)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: gemini, provider: .gemini), .badRequest)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: gemini), .badRequest)
        // Ollama answers 500 for a model without the parts that read pictures, on its own route and its compatible one.
        let ollama = Data(#"{"error":"this model is missing data required for image input"}"#.utf8)
        let ollamaCompatible = Data(#"{"error":{"message":"this model is missing data required for image input","type":"api_error","param":null,"code":null}}"#.utf8)
        for body in [ollama, ollamaCompatible] {
            XCTAssertEqual(AgentErrorMapper.failure(status: 500, body: body, provider: .ollama), .badRequest)
            XCTAssertEqual(AgentErrorMapper.failure(status: 500, body: body), .badRequest)
            XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: body), .badRequest)
        }
        let lmStudio = Data(#"{"error":"Model does not support images. Please use a model that does."}"#.utf8)
        for status in [400, 500] {
            XCTAssertEqual(AgentErrorMapper.failure(status: status, body: lmStudio, provider: .lmStudio), .badRequest, "\(status)")
        }
        // Inside a stream, with a status or without one.
        XCTAssertEqual(AgentErrorMapper.failure(streamError: json(#"{"error":"this model is missing data required for image input"}"#)), .badRequest)
        XCTAssertEqual(AgentErrorMapper.failure(streamError: json(#"{"error":{"type":"api_error","message":"Model does not support images."}}"#)), .badRequest)
    }

    func testOtherFailuresMapAsBefore() {
        XCTAssertEqual(AgentErrorMapper.failure(status: 500, body: Data(#"{"error":"llama runner process has terminated"}"#.utf8), provider: .ollama), .overloaded)
        XCTAssertEqual(AgentErrorMapper.failure(streamError: json(#"{"error":"something broke"}"#)), .overloaded)
        XCTAssertEqual(AgentErrorMapper.failure(status: 400, body: Data("model does not support tools".utf8), provider: .lmStudio), .noTools)
        XCTAssertEqual(AgentErrorMapper.failure(status: 413, body: Data("image exceeds 5 MB maximum".utf8), provider: .claude), .tooLarge)
    }

    // MARK: The scripted model

    func testTheScriptedModelListsPicturesBySizeNeverByTheirBytes() async throws {
        let client = ScriptedModelClient()
        let items = client.userItems(text: "Next", toolResults: results)
        XCTAssertEqual(items.count, 1)
        let listed = items[0]["results"]?.arrayValue?.map { $0["pictures"] }
        XCTAssertEqual(listed, [
            json(#"[{"label":"Picture 1","width":512,"height":384},{"label":"Picture 2","width":512,"height":384}]"#),
            nil,
            json(#"[{"label":"Picture 3","width":300,"height":512}]"#)
        ])
        for try await _ in client.turn(AgentTurnInput(system: "", tools: [], history: items)) {}
        _ = try? await client.structured(ask)
        XCTAssertEqual(client.sentAsks.first?.pictures, ask.pictures, "a question keeps its pictures")
        let sent = client.allSentText()
        XCTAssertTrue(sent.contains("[picture 512x384]"))
        XCTAssertTrue(sent.contains("[picture 300x512]"))
        XCTAssertTrue(sent.contains("Picture 3"))
        XCTAssertTrue(sent.contains("Item 2"))
        XCTAssertFalse(sent.contains("/9g"), "never a picture's bytes")
        XCTAssertFalse(sent.contains("base64"))
    }

    func testAScriptedModelThatCantTakePicturesFailsOnlyWhileTheHistoryHoldsOne() async throws {
        let client = ScriptedModelClient()
        client.picturesFailure = .badRequest
        func turn(_ history: [AgentJSON]) async -> AgentFailure? {
            do {
                for try await _ in client.turn(AgentTurnInput(system: "", tools: [], history: history)) {}
                return nil
            } catch {
                return error as? AgentFailure
            }
        }
        let withPictures = client.userItems(text: "hello", toolResults: results)
        let without = client.userItems(text: "hello", toolResults: results.map(\.withoutImages))
        agentEqual(await turn(withPictures), .badRequest)
        agentNil(await turn(without))
        client.picturesFailure = nil
        agentNil(await turn(withPictures))
    }
}
