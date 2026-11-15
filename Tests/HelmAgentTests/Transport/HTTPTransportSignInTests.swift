import XCTest
@testable import HelmAgent

/// The transport with a ChatGPT sign-in, with a stub loader in front of the network: the bearer token on OpenAI's
/// requests and its renewal, the body a plan request carries, and the sign-in host's own requests. Nothing here reaches
/// a real host.
final class HTTPTransportSignInTests: XCTestCase {
    private typealias T = AgentTransportTesting

    /// Hands out a token, and the next one on each renewal.
    private final class StubBearer: AgentBearerSource, @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String]
        private(set) var renewals = 0
        private(set) var forgotten = false
        init(_ tokens: [String]) { self.tokens = tokens }
        func bearerToken() async throws -> AgentSecret {
            lock.lock(); defer { lock.unlock() }
            guard let first = tokens.first, let secret = AgentSecret(bearerToken: first) else { throw AgentTransportError.noKey }
            return secret
        }
        func renewedToken() async throws -> AgentSecret {
            lock.lock()
            renewals += 1
            if tokens.count > 1 { tokens.removeFirst() }
            lock.unlock()
            return try await bearerToken()
        }
        func forget() { lock.lock(); forgotten = true; lock.unlock() }
    }

    override func tearDown() {
        AgentStubLoader.reset { _ in [.fail(.cannotConnectToHost)] }
        super.tearDown()
    }

    private func planProfile() throws -> AgentProviderProfile {
        AgentProviderProfile(id: .openAI, endpoint: try AgentEndpoint(fixed: .openAI), usesChatGPT: true)
    }

    private func transport(_ profile: AgentProviderProfile, bearer: (any AgentBearerSource)? = nil) -> HTTPTransport {
        HTTPTransport(liveProfile: profile, secrets: MemorySecretStore(), limits: T.roomy, bearer: bearer,
                      testProtocols: [AgentStubLoader.self])
    }

    private static let completed = """
        event: response.completed
        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}]}}

        """

    private static func events(_ text: String) -> [AgentStubLoader.Step] {
        [.respond(status: 200, headers: ["Content-Type": "text/event-stream"], from: nil), .send(Data(text.utf8)), .finish]
    }

    private static func json(_ status: Int, _ text: String) -> [AgentStubLoader.Step] {
        [.respond(status: status, headers: ["Content-Type": "application/json"], from: nil), .send(Data(text.utf8)), .finish]
    }

    // MARK: Requests billed to the plan

    func testAPlanRequestCarriesTheBearerTokenStoreFalseStreamTrueAndItsToolsInANamespace() async throws {
        AgentStubLoader.reset { _ in Self.events(Self.completed) }
        let bearer = StubBearer(["test-access-token-0001"])
        let client = LiveModelClient(profile: try planProfile(), model: "gpt-6.1-sol", transport: transport(try planProfile(), bearer: bearer))
        XCTAssertEqual(client.providerName, "ChatGPT", "the panel's lines name the plan")
        XCTAssertEqual(client.destination, "OpenAI", "requests go to OpenAI, as the consent line says")
        let input = AgentTurnInput(system: ProviderFixtures.system, tools: [ProviderFixtures.tool],
                                   history: [.object(["role": .string("user"), "content": .string("Organize r1")])])
        var finished: AgentTurnResult?
        for try await event in client.turn(input) { if case .finished(let result) = event { finished = result } }
        XCTAssertEqual(finished?.stop, .endTurn)

        let seen = try XCTUnwrap(AgentStubLoader.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(seen.header("Authorization"), "Bearer test-access-token-0001")
        let body = try AgentJSON(data: seen.body)
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["model"], .string("gpt-6.1-sol"))
        XCTAssertNil(body["max_output_tokens"], "plan use takes no token ceiling")
        XCTAssertEqual(body["instructions"], .string(ProviderFixtures.system))
        let tools = try XCTUnwrap(body["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"], .string("namespace"))
        XCTAssertEqual(tools[0]["name"], .string("helm"))
        XCTAssertEqual(tools[0]["tools"]?.arrayValue?.first?["name"], .string(ProviderFixtures.tool.name))
        XCTAssertFalse(String(decoding: seen.body, as: UTF8.self).contains("test-access-token"), "the token is in the header alone")
    }

    func testATokenOpenAITurnsAwayIsRenewedOnceAndTheRequestMadeAgain() async throws {
        var asked = 0
        let lock = NSLock()
        AgentStubLoader.reset { _ in
            lock.lock(); asked += 1; let count = asked; lock.unlock()
            return count == 1 ? Self.json(401, #"{"error":{"code":"invalid_api_key"}}"#) : Self.events(Self.completed)
        }
        let bearer = StubBearer(["test-access-token-0001", "test-access-token-0002"])
        let outcome = await T.drain(transport(try planProfile(), bearer: bearer).stream(.chat, body: T.data("{}")))
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(bearer.renewals, 1)
        XCTAssertEqual(AgentStubLoader.seen.map { $0.header("Authorization") },
                       ["Bearer test-access-token-0001", "Bearer test-access-token-0002"])
    }

    func testASecondRefusalEndsTheRequestAsASignInToMakeAgain() async throws {
        AgentStubLoader.reset { _ in Self.json(401, #"{"error":{"code":"subscription_sharing_invalid_user"}}"#) }
        let bearer = StubBearer(["test-access-token-0001", "test-access-token-0002"])
        let profile = try planProfile()
        let client = LiveModelClient(profile: profile, model: "gpt-6.1-sol", transport: transport(profile, bearer: bearer))
        do {
            _ = try await client.models()
            XCTFail("a sign-in OpenAI can't verify lists nothing")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .noKey)
        }
        XCTAssertEqual(bearer.renewals, 1, "renewed once, never in a loop")
        XCTAssertEqual(AgentStubLoader.seen.count, 2)
    }

    func testAPlansModelsAreTheListedOnesShownByDisplayName() async throws {
        let list = """
            {"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"},
                       {"slug":"gpt-6.1-internal","display_name":"Internal","visibility":"hide"},
                       {"slug":"gpt-6-astra","display_name":"GPT-6 Astra","visibility":"list"}]}
            """
        AgentStubLoader.reset { _ in Self.json(200, list) }
        let profile = try planProfile()
        let client = LiveModelClient(profile: profile, model: "gpt-6.1-sol",
                                     transport: transport(profile, bearer: StubBearer(["test-access-token-0001"])))
        let models = try await client.models()
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol", "gpt-6-astra"], "in OpenAI's order, the hidden one left out")
        XCTAssertEqual(models.map(\.title), ["GPT-6.1 Sol", "GPT-6 Astra"])
        XCTAssertEqual(AgentStubLoader.seen.first?.url.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(AgentStubLoader.seen.first?.header("Authorization"), "Bearer test-access-token-0001")
    }

    func testAPlanThatReachedItsLimitHasItsOwnFailureAndIsNotTriedAgain() async throws {
        AgentStubLoader.reset { _ in
            Self.json(429, #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#)
        }
        let profile = try planProfile()
        let retrying = HTTPTransport(liveProfile: profile, secrets: MemorySecretStore(), limits: T.limits(retries: 2),
                                     bearer: StubBearer(["test-access-token-0001"]), testProtocols: [AgentStubLoader.self])
        let client = LiveModelClient(profile: profile, model: "gpt-6.1-sol", transport: retrying)
        do {
            _ = try await client.models()
            XCTFail("a plan at its limit lists nothing")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .outOfCredit)
        }
        XCTAssertEqual(AgentStubLoader.seen.count, 1, "waiting won't lift a usage limit")
    }

    func testShuttingDownLetsTheBearerGo() async throws {
        let bearer = StubBearer(["test-access-token-0001"])
        await transport(try planProfile(), bearer: bearer).shutdown()
        XCTAssertTrue(bearer.forgotten)
    }

    // MARK: The sign-in host

    func testTheSignInHostIsSentAFormAndNoKey() async throws {
        AgentStubLoader.reset { _ in Self.json(400, #"{"error":"invalid_grant"}"#) }
        let signIn = transport(try AgentProviderCatalog.signInProfile())
        let reply = try await signIn.post(.token, form: [("grant_type", "authorization_code"), ("code", "test-code")])
        XCTAssertEqual(reply.status, 400, "a refusal is an answer, with the body that says why")
        XCTAssertEqual(AgentTokenReply.errorCode(in: reply.body), "invalid_grant")
        let seen = try XCTUnwrap(AgentStubLoader.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.url.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
        XCTAssertEqual(seen.header("Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(seen.header("Accept"), "application/json")
        XCTAssertEqual(String(decoding: seen.body, as: UTF8.self), "grant_type=authorization_code&code=test-code")
        XCTAssertNil(seen.header("Authorization"))
        XCTAssertEqual(AgentStubLoader.seen.count, 1, "a POST is never made twice")
    }

    func testTheSignInHostsKeysAndDiscoveryAreFetched() async throws {
        AgentStubLoader.reset { request in Self.json(200, request.url?.path == "/.well-known/jwks.json" ? #"{"keys":[]}"# : "{}") }
        let signIn = transport(try AgentProviderCatalog.signInProfile())
        let keys = try await signIn.get(.keys)
        XCTAssertEqual(keys.status, 200)
        _ = try await signIn.get(.discovery)
        XCTAssertEqual(AgentStubLoader.seen.map { $0.url.absoluteString },
                       ["https://auth.openai.com/.well-known/jwks.json", "https://auth.openai.com/.well-known/openid-configuration"])
        XCTAssertEqual(AgentStubLoader.seen.map(\.method), ["GET", "GET"])
    }

    func testEachTransportSendsOnlyItsOwnRequests() async throws {
        AgentStubLoader.reset { _ in Self.json(200, "{}") }
        let provider = transport(try planProfile(), bearer: StubBearer(["test-access-token-0001"]))
        await XCTAssertThrowsTransport(.unreachable) { _ = try await provider.post(.token, form: [("a", "b")]) }
        await XCTAssertThrowsTransport(.unreachable) { _ = try await provider.get(.keys) }
        let signIn = transport(try AgentProviderCatalog.signInProfile())
        await XCTAssertThrowsTransport(.unreachable) { _ = try await signIn.fetch(.models) }
        let outcome = await T.drain(signIn.stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .unreachable)
        await XCTAssertThrowsTransport(.unreachable) { _ = try await signIn.post(.revoke(path: "/oauth/../token"), form: []) }
        await XCTAssertThrowsTransport(.unreachable) { _ = try await signIn.post(.revoke(path: "oauth/revoke"), form: []) }
        await XCTAssertThrowsTransport(.unreachable) { _ = try await signIn.post(.keys, form: []) }
        XCTAssertTrue(AgentStubLoader.seen.isEmpty, "nothing was sent")
    }

    func testTheSignInHostCantRedirectARequestElsewhere() async throws {
        let elsewhere = try XCTUnwrap(URL(string: "https://collector.example.net/token"))
        AgentStubLoader.reset { request in
            if request.url?.host == "collector.example.net" { return Self.json(200, "{}") }
            return [.redirect(to: elsewhere, status: 307),
                    .respond(status: 307, headers: ["Location": elsewhere.absoluteString], from: nil), .finish]
        }
        let signIn = transport(try AgentProviderCatalog.signInProfile())
        await XCTAssertThrowsTransport(.redirected) { _ = try await signIn.post(.token, form: [("code", "test-code")]) }
        XCTAssertEqual(AgentStubLoader.seen.map { $0.url.host }, ["auth.openai.com"])
    }
}
