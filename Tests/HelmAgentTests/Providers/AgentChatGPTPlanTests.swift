import XCTest
import HelmCore
@testable import HelmAgent

/// The pieces of a request billed to a ChatGPT plan, each by itself: the profile, the sign-in host's routes, the
/// Responses body plan use takes, the plan's model list, its errors and the lines the person reads for them.
final class AgentChatGPTPlanTests: XCTestCase {
    // MARK: The profile and the sign-in host

    func testOpenAIIsReachedWithAChatGPTSignInUnlessAKeyIsChosen() throws {
        let plan = try AgentProviderCatalog.profile(for: AIConfig(provider: "openAI")).get()
        XCTAssertTrue(plan.usesChatGPT)
        XCTAssertFalse(plan.needsKey, "the sign-in stands in for the key")
        XCTAssertEqual(plan.name, "ChatGPT")
        XCTAssertEqual(plan.destination, "OpenAI")
        XCTAssertEqual(plan.endpoint, try AgentEndpoint(fixed: .openAI))
        let key = try AgentProviderCatalog.profile(for: AIConfig(provider: "openAI", openAIUsesKey: true)).get()
        XCTAssertFalse(key.usesChatGPT)
        XCTAssertTrue(key.needsKey)
        XCTAssertEqual(key.name, "OpenAI")
        XCTAssertNotEqual(plan, key, "changing between the two starts every conversation over")
        // No other provider can be reached with a ChatGPT sign-in.
        XCTAssertFalse(AgentProviderProfile(id: .claude, endpoint: try AgentEndpoint(fixed: .claude), usesChatGPT: true).usesChatGPT)
        XCTAssertFalse(try AgentProviderCatalog.profile(for: AIConfig(provider: "gemini")).get().usesChatGPT)
    }

    func testTheSignInHostHasFixedPathsAndAPlainRevocation() throws {
        let host = try AgentEndpoint.openAISignIn()
        XCTAssertEqual(host.host, "auth.openai.com")
        XCTAssertTrue(host.isSecure)
        XCTAssertEqual(host.port, 443)
        XCTAssertEqual(host.basePath, "")
        XCTAssertEqual(try AgentProviderCatalog.signInProfile().endpoint, host)
        XCTAssertEqual(AgentProviderCatalog.route(.token), AgentRouteSpec(method: "POST", path: "/api/accounts/oauth/token", auth: .none))
        XCTAssertEqual(AgentProviderCatalog.route(.keys), AgentRouteSpec(method: "GET", path: "/.well-known/jwks.json", auth: .none))
        XCTAssertEqual(AgentProviderCatalog.route(.discovery),
                       AgentRouteSpec(method: "GET", path: "/.well-known/openid-configuration", auth: .none))
        XCTAssertEqual(AgentProviderCatalog.route(.revoke(path: "/oauth/revoke")),
                       AgentRouteSpec(method: "POST", path: "/oauth/revoke", auth: .none))
        for path in ["oauth/revoke", "/oauth//revoke", "/oauth/../revoke", "/oauth/./revoke", "/oauth/revoke?x=1", "/oauth/re voke",
                     "/" + String(repeating: "a", count: 300), "/oauth/%2e%2e", "/"] {
            XCTAssertNil(AgentProviderCatalog.route(.revoke(path: path)), path)
        }
    }

    // MARK: The Responses body

    private let input = AgentTurnInput(system: "Be brief.", tools: [ProviderFixtures.tool],
                                       history: [.object(["role": .string("user"), "content": .string("Organize r1")])])

    func testAPlanTurnStreamsStoresNothingSendsNoCeilingAndGroupsItsTools() throws {
        let body = try AgentJSON(data: OpenAIResponsesAdapter(planUsage: true).turnBody(input, model: "gpt-6.1-sol"))
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertEqual(body["instructions"], .string("Be brief."))
        XCTAssertEqual(body["include"], .array([.string("reasoning.encrypted_content")]))
        let namespace = try XCTUnwrap(body["tools"]?.arrayValue?.first)
        XCTAssertEqual(body["tools"]?.arrayValue?.count, 1)
        XCTAssertEqual(namespace["type"], .string("namespace"))
        XCTAssertEqual(namespace["name"], .string("helm"))
        XCTAssertNotNil(namespace["description"]?.stringValue)
        let tool = try XCTUnwrap(namespace["tools"]?.arrayValue?.first)
        XCTAssertEqual(tool["type"], .string("function"))
        XCTAssertEqual(tool["name"], .string(ProviderFixtures.tool.name))
        XCTAssertEqual(tool["strict"], .bool(true))
        // A request with a key keeps its usual shape.
        let usual = try AgentJSON(data: OpenAIResponsesAdapter().turnBody(input, model: "gpt-6-astra"))
        XCTAssertNotNil(usual["max_output_tokens"])
        XCTAssertEqual(usual["tools"]?.arrayValue?.first?["type"], .string("function"))
    }

    func testAPlanStructuredAskStreamsAndItsAnswerIsReadFromTheStream() throws {
        let ask = AgentStructuredAsk(system: "Plan.", user: "find invoices", schemaName: "plan",
                                     schema: .object(["type": .string("object")]))
        let body = try AgentJSON(data: OpenAIResponsesAdapter(planUsage: true).structuredBody(ask, model: "gpt-6.1-sol"))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertNil(try AgentJSON(data: OpenAIResponsesAdapter().structuredBody(ask, model: "gpt-6-astra"))["stream"])

        let stream = """
            event: response.created
            data: {"type":"response.created","response":{"status":"in_progress"}}

            event: response.completed
            data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\\"queries\\":[1]}"}]}]}}

            """
        let answer = try OpenAIResponsesAdapter(planUsage: true).structuredAnswer(from: Data(stream.utf8))
        XCTAssertEqual(try AgentJSON(data: answer), .object(["queries": .array([.number(1)])]))

        let limited = """
            data: {"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded"}}}

            """
        XCTAssertThrowsError(try OpenAIResponsesAdapter(planUsage: true).structuredAnswer(from: Data(limited.utf8))) {
            XCTAssertEqual($0 as? AgentFailure, .outOfCredit)
        }
        XCTAssertThrowsError(try OpenAIResponsesAdapter(planUsage: true).structuredAnswer(from: Data("data: {\"type\":\"ping\"}\n".utf8))) {
            XCTAssertEqual($0 as? AgentFailure, .unreadable, "a stream that never completes")
        }
    }

    func testAPlanStreamsCallsAndLimitsAreRead() {
        let reader = OpenAIResponsesAdapter(planUsage: true).makeReader()
        let call = #"{"type":"function_call","call_id":"call_1","namespace":"helm","name":"helm.list_folder","arguments":"{}"}"#
        var events = reader.feed(#"data: {"type":"response.output_item.done","output_index":0,"item":\#(call)}"#)
        events += reader.feed(#"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        XCTAssertEqual(events.count, 1)
        let result = reader.finish()
        XCTAssertEqual(result.stop, .toolUse)
        XCTAssertEqual(result.calls.map(\.name), ["list_folder"], "the namespace isn't part of the tool's name")
        XCTAssertEqual(result.rawItems.first?["namespace"], .string("helm"), "the item goes back as it came")

        let limited = OpenAIResponsesAdapter(planUsage: true).makeReader()
        _ = limited.feed(#"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)
        XCTAssertEqual(limited.finish().stop, .failed(.outOfCredit))
        let unavailable = OpenAIResponsesAdapter(planUsage: true).makeReader()
        _ = unavailable.feed(#"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_unavailable"}}}"#)
        XCTAssertEqual(unavailable.finish().stop, .failed(.overloaded))
    }

    // MARK: The model list

    func testAPlansListKeepsTheListedModelsInOpenAIsOrderByDisplayName() throws {
        let body = """
            {"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"},
                       {"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide"},
                       {"slug":"gpt-6-astra","display_name":"GPT-6 Astra","visibility":"list"},
                       {"slug":"gpt-6-astra","display_name":"Again","visibility":"list"},
                       {"slug":"bad slug!","display_name":"Bad","visibility":"list"},
                       {"slug":"gpt-odd","display_name":"Odd\\u202Ename","visibility":"list"},
                       {"display_name":"No slug","visibility":"list"}]}
            """
        let models = try AgentModelLister.chatGPTModels(from: Data(body.utf8))
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol", "gpt-6-astra", "gpt-odd"])
        XCTAssertEqual(models.map(\.title), ["GPT-6.1 Sol", "GPT-6 Astra", "gpt-odd"], "a name that isn't clean shows the slug")
        XCTAssertThrowsError(try AgentModelLister.chatGPTModels(from: Data(#"{"data":[{"id":"gpt-6"}]}"#.utf8)))
        XCTAssertEqual(AgentModelLister.preselected(models, provider: .openAI), "gpt-6-astra")
        XCTAssertEqual(AgentModelLister.preselected(Array(models.prefix(1)), provider: .openAI), "gpt-6.1-sol",
                       "a plan that doesn't offer OpenAI's first choice runs its own first one")
    }

    func testAModelsLabelIsShortCleanTextOrNothing() {
        XCTAssertEqual(AgentModelInfo(id: "m", label: "  Model M ")?.title, "Model M")
        XCTAssertNil(AgentModelInfo(id: "m", label: String(repeating: "x", count: 65))?.label)
        XCTAssertNil(AgentModelInfo(id: "m", label: "")?.label)
        XCTAssertNil(AgentModelInfo(id: "m", label: "a\u{0}b")?.label)
        XCTAssertNil(AgentModelInfo(id: "bad id", label: "Fine"))
        XCTAssertNil(AgentModelInfo(id: "m")?.label)
    }

    // MARK: Errors and lines

    private func failure(_ status: Int, _ code: String) -> AgentFailure {
        AgentErrorMapper.chatGPTFailure(status: status, body: Data(#"{"error":{"code":"\#(code)","message":"words"}}"#.utf8))
    }

    func testThePlansErrorsMapToTheirFailures() {
        XCTAssertEqual(failure(429, "subscription_sharing_usage_limit_exceeded"), .outOfCredit)
        XCTAssertEqual(failure(503, "subscription_sharing_usage_unavailable"), .overloaded)
        XCTAssertEqual(failure(503, "subscription_sharing_user_unavailable"), .overloaded)
        XCTAssertEqual(failure(403, "subscription_sharing_user_not_eligible"), .noSuchModel)
        XCTAssertEqual(failure(403, "subscription_sharing_route_not_supported"), .noSuchModel)
        XCTAssertEqual(failure(400, "subscription_sharing_unsupported_capability"), .noSuchModel)
        XCTAssertEqual(failure(403, "chatpass_v2_scope_not_authorized"), .noSuchModel)
        XCTAssertEqual(failure(401, "subscription_sharing_invalid_user"), .noKey)
        XCTAssertEqual(AgentErrorMapper.chatGPTFailure(status: 401, body: Data(#"{"detail":"no"}"#.utf8)), .noKey)
        XCTAssertEqual(AgentErrorMapper.chatGPTFailure(status: 403, body: Data()), .noSuchModel)
        XCTAssertEqual(AgentErrorMapper.chatGPTFailure(status: 429, body: Data()), .rateLimited)
        XCTAssertEqual(AgentErrorMapper.chatGPTFailure(status: 503, body: Data()), .overloaded)
        XCTAssertEqual(AgentErrorMapper.chatGPTFailure(of: AgentTransportError.unreachable), .unreachable)
        XCTAssertEqual(AgentErrorMapper.chatGPTFailure(of: AgentTransportError.noKey), .noKey)
        // With a key, the same statuses keep their usual meaning.
        XCTAssertEqual(AgentErrorMapper.failure(status: 401, body: Data(), provider: .openAI), .wrongKey)
    }

    func testThePanelsLinesNameThePlanForAChatGPTSignIn() {
        XCTAssertEqual(AgentText.failNoKey("ChatGPT"), "Sign in with ChatGPT in Settings to use it.")
        XCTAssertEqual(AgentText.failOutOfCredit("ChatGPT"), "You've reached your ChatGPT plan's usage limit.")
        XCTAssertEqual(AgentText.failNoSuchModel("ChatGPT"), "Your ChatGPT plan doesn't cover this request.")
        XCTAssertEqual(AgentText.failBusy("ChatGPT"), "ChatGPT is busy, so try again in a moment.")
        // Every other provider's lines are as they were.
        XCTAssertEqual(AgentText.failNoKey("OpenAI"), "Add a key in Settings to use OpenAI.")
        XCTAssertEqual(AgentText.failOutOfCredit("OpenAI"), "Your OpenAI account is out of credit.")
        XCTAssertEqual(AgentText.failNoSuchModel("Claude"), "Claude doesn't have that model.")
    }

    func testABearerTokenIsLongerThanAKeyButHeldToATokensCharacters() {
        let long = String(repeating: "abcDEF123.-_", count: 200)
        XCTAssertNotNil(AgentSecret(bearerToken: long))
        XCTAssertNil(AgentSecret(pasted: long), "a pasted key is at most 512 characters")
        XCTAssertNil(AgentSecret(bearerToken: ""))
        XCTAssertNil(AgentSecret(bearerToken: "token with space"))
        XCTAssertNil(AgentSecret(bearerToken: "token\r\nX-Other: 1"))
        XCTAssertNil(AgentSecret(bearerToken: String(repeating: "a", count: 16_385)))
        XCTAssertEqual(String(describing: AgentSecret(bearerToken: "test-token-0001")), "Optional(AgentSecret(hidden))")
    }

    func testEachHelpPageIsAnHTTPSAddressOnTheList() throws {
        XCTAssertEqual(AgentHelpLinks.all.count, 8)
        for text in AgentHelpLinks.all {
            let page = try XCTUnwrap(URL(string: text), text)
            XCTAssertEqual(page.scheme, "https", text)
        }
        var linked: Set<String> = []
        for provider in AgentProviderID.allCases {
            for usesChatGPT in [false, true] {
                if let page = AgentHelpLinks.howToConnect(provider, usesChatGPT: usesChatGPT) { linked.insert(page.absoluteString) }
            }
        }
        if let usage = AgentHelpLinks.manageUsage { linked.insert(usage.absoluteString) }
        XCTAssertEqual(linked, Set(AgentHelpLinks.all), "every page is used, and none is made up elsewhere")
        XCTAssertNil(AgentHelpLinks.howToConnect(.other, usesChatGPT: false))
        // No help page is a host the transport reaches.
        let hosts = Set(AgentHelpLinks.all.compactMap { URL(string: $0)?.host })
        XCTAssertFalse(hosts.contains("api.openai.com") || hosts.contains("auth.openai.com") || hosts.contains("api.anthropic.com"))
    }
}

