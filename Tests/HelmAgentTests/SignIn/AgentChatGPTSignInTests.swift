import XCTest
@testable import HelmAgent

/// The ChatGPT sign-in from the browser's first page to the saved tokens, against OpenAI played in the test process.
/// Nothing here reaches OpenAI, a browser or the keychain.
final class AgentChatGPTSignInTests: XCTestCase {
    private typealias Rig = AgentSignInRig

    // MARK: The authorize page

    func testAFirstSignInRegistersWithEveryParameterOpenAIAsksFor() throws {
        let registration = AgentChatGPTRegistration(hostID: "urn:uuid:3f1a2b4c-0000-4000-8000-000000000001", clientID: nil)
        let address = try XCTUnwrap(AgentChatGPTSignIn.authorizeAddress(
            registration: registration, redirect: "http://127.0.0.1:54321/auth/callback", state: "state-test",
            nonce: "nonce-test", challenge: "challenge-test", idTokenHint: "hint-test", asksConsent: false))
        let parts = try XCTUnwrap(URLComponents(url: address, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "auth.openai.com")
        XCTAssertNil(parts.port)
        XCTAssertEqual(parts.path, "/api/accounts/authorize")
        let items = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        XCTAssertEqual(items, [
            "response_type": "code", "client_id": "dynamic_agent_client",
            "redirect_uri": "http://127.0.0.1:54321/auth/callback",
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": "https://api.openai.com/v1", "state": "state-test", "nonce": "nonce-test",
            "code_challenge": "challenge-test", "code_challenge_method": "S256",
            "ext_agent_host_id": "urn:uuid:3f1a2b4c-0000-4000-8000-000000000001", "agent_name_hint": "Helm"
        ], "a first sign-in names Helm and sends no ID token hint")
        XCTAssertEqual(parts.queryItems?.count, items.count, "no parameter is sent twice")
        // Every value is escaped but letters, digits and -._~, so `:` and `/` can't be read otherwise.
        let query = try XCTUnwrap(parts.percentEncodedQuery)
        XCTAssertTrue(query.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fcallback"), query)
        XCTAssertTrue(query.contains("scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct"),
                      query)
    }

    func testAReturningSignInSendsItsOwnClientAndTheIDTokenItKept() throws {
        let registration = AgentChatGPTRegistration(hostID: "urn:uuid:3f1a2b4c-0000-4000-8000-000000000001",
                                                    clientID: "oaiapp_test_client")
        let address = try XCTUnwrap(AgentChatGPTSignIn.authorizeAddress(
            registration: registration, redirect: "http://127.0.0.1:1455/auth/callback", state: "s", nonce: "n",
            challenge: "c", idTokenHint: "hint-test", asksConsent: true))
        let items = Dictionary((URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        }) { first, _ in first }
        XCTAssertEqual(items["client_id"], "oaiapp_test_client")
        XCTAssertNil(items["agent_name_hint"], "the name goes with the registration only")
        XCTAssertEqual(items["id_token_hint"], "hint-test")
        XCTAssertEqual(items["ext_agent_host_id"], "urn:uuid:3f1a2b4c-0000-4000-8000-000000000001")
        XCTAssertEqual(items["prompt"], "consent", "after a declined sign-in the person is asked to agree again")
    }

    func testTheRedirectIsThisMacByNumberAndOnlyThePortVaries() {
        XCTAssertEqual(AgentChatGPTSignIn.redirect(port: 54321), "http://127.0.0.1:54321/auth/callback")
        XCTAssertEqual(AgentChatGPTSignIn.redirect(port: 1455), "http://127.0.0.1:1455/auth/callback")
        XCTAssertFalse(AgentChatGPTSignIn.redirect(port: 1455).contains("localhost"))
    }

    // MARK: A whole sign-in

    func testASignInListensFirstThenOpensTheBrowserExchangesTheCodeAndSavesTheTokens() async throws {
        let rig = Rig()
        let account = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        XCTAssertEqual(account, AgentChatGPTAccount(email: "person@example.com"))
        XCTAssertEqual(rig.openAI.events.prefix(2), ["listen", "open"], "the listener starts before the browser opens")
        XCTAssertEqual(rig.openAI.events.last, "stop", "and stops once the callback is in")
        XCTAssertEqual(rig.openAI.opened.count, 1)
        XCTAssertEqual(rig.listener.waitedPath, "/auth/callback")
        XCTAssertEqual(rig.listener.waitedSeconds, 300, "five minutes for the browser")

        // The code exchange: the issued client, the verifier, the same redirect and resource, and no secret.
        let exchange = try XCTUnwrap(rig.openAI.posts.first { $0.route == "token" }?.form)
        let page = rig.openAI.authorizeParameters
        XCTAssertEqual(Set(exchange.keys), ["grant_type", "client_id", "code", "code_verifier", "redirect_uri", "resource"])
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["client_id"], "oaiapp_test_client", "the issued client, never the registration one")
        XCTAssertEqual(exchange["code"], "test-code")
        XCTAssertEqual(exchange["redirect_uri"], page["redirect_uri"])
        XCTAssertEqual(exchange["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(AgentPKCE(verifier: exchange["code_verifier"] ?? "").challenge, page["code_challenge"])
        XCTAssertNil(exchange["client_secret"])
        XCTAssertEqual(rig.openAI.gets, ["keys"], "the ID token was checked against the published keys")

        // The keychain record: the registration with the issued client, the tokens with the email as their note.
        let registration = try XCTUnwrap(rig.savedRegistration)
        XCTAssertEqual(registration.clientID, "oaiapp_test_client")
        XCTAssertEqual(registration.hostID, page["ext_agent_host_id"])
        XCTAssertTrue(AgentChatGPTRegistration.isHostID(registration.hostID))
        let tokens = try XCTUnwrap(rig.savedTokens)
        XCTAssertEqual(tokens.clientID, "oaiapp_test_client")
        XCTAssertEqual(tokens.accessToken, "test-access-token-0001")
        XCTAssertEqual(tokens.refreshToken, "test-refresh-token-0001")
        XCTAssertTrue(tokens.allowsPlan)
        XCTAssertGreaterThan(tokens.expiresAt.timeIntervalSinceNow, 3_000)
        XCTAssertEqual(rig.store.signInNote(.chatGPTTokens), "person@example.com")
        XCTAssertEqual(rig.store.signInItems, [.chatGPTRegistration, .chatGPTTokens])
        XCTAssertEqual(rig.store.accounts, [], "no key was saved")
        XCTAssertEqual(rig.openAI.shutdowns, 1, "the sign-in's transport is let go")
        // The tokens never print.
        XCTAssertEqual(String(describing: tokens), "AgentChatGPTTokens(hidden)")
        XCTAssertEqual(String(reflecting: tokens), "AgentChatGPTTokens(hidden)")
        XCTAssertTrue(Mirror(reflecting: tokens).children.isEmpty)
    }

    func testTheHostIDIsMadeBeforeTheFirstSignInAndKeptForEveryOne() async throws {
        let rig = Rig()
        _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        let first = try XCTUnwrap(rig.savedRegistration?.hostID)
        XCTAssertEqual(rig.openAI.authorizeParameters["ext_agent_host_id"], first)
        // The second sign-in is a returning one, with the same host and its own client.
        _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        XCTAssertEqual(rig.openAI.authorizeParameters["ext_agent_host_id"], first)
        XCTAssertEqual(rig.openAI.authorizeParameters["client_id"], "oaiapp_test_client")
        XCTAssertNil(rig.openAI.authorizeParameters["agent_name_hint"])
        XCTAssertNotNil(rig.openAI.authorizeParameters["id_token_hint"], "the ID token kept names the account")
        XCTAssertEqual(rig.savedRegistration?.hostID, first)
        // A sign-in that failed before the browser opened still left the host ID, so it is never made twice.
        let other = Rig()
        other.openAI.opens = false
        await assertFails(.noBrowser) { _ = try await other.signIn.run(openInBrowser: other.openAI.opener) }
        XCTAssertNotNil(other.savedRegistration?.hostID)
        XCTAssertNil(other.savedRegistration?.clientID)
    }

    func testEachSignInHasItsOwnStateNonceAndVerifier() async throws {
        let rig = Rig()
        _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        let first = rig.openAI.authorizeParameters
        _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        let second = rig.openAI.authorizeParameters
        for name in ["state", "nonce", "code_challenge"] {
            XCTAssertNotEqual(first[name], second[name], name)
            XCTAssertGreaterThanOrEqual(first[name]?.count ?? 0, 43, name)
        }
    }

    // MARK: What is turned away

    func testACallbackWithAnotherStateIsTurnedAwayAndTheRightOneTaken() async throws {
        let rig = Rig()
        let issued = rig.openAI.issuedClient
        rig.openAI.callbacks = { page in
            [["code": "forged-code", "state": "someone-elses-state", "client_id": issued],
             ["code": "test-code", "state": page["state"] ?? "", "client_id": issued]]
        }
        _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        XCTAssertEqual(rig.listener.turnedAway.map { $0["state"] }, ["someone-elses-state"])
        XCTAssertEqual(rig.openAI.posts.filter { $0.route == "token" }.map { $0.form["code"] }, ["test-code"])
    }

    func testOnlyACallbackWithAnotherStateIsAWaitThatEnds() async {
        let rig = Rig()
        rig.openAI.callbacks = { _ in [["code": "forged-code", "state": "someone-elses-state", "client_id": "oaiapp_x"]] }
        await assertFails(.timedOut) { _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
        XCTAssertTrue(rig.openAI.posts.isEmpty, "no code was exchanged")
        XCTAssertNil(rig.savedTokens)
    }

    func testAccessDeniedStopsWithoutExchangingACode() async {
        let rig = Rig()
        rig.openAI.callbacks = { page in [["error": "access_denied", "state": page["state"] ?? ""]] }
        await assertFails(.declined) { _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
        XCTAssertTrue(rig.openAI.posts.isEmpty)
        XCTAssertNil(rig.savedTokens)
        // Any other refusal is a sign-in that didn't finish.
        rig.openAI.callbacks = { page in [["error": "server_error", "state": page["state"] ?? ""]] }
        await assertFails(.failed) { _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
    }

    func testAReturningSignInTakesNoOtherClient() async throws {
        let rig = Rig()
        _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        let tokensBefore = try XCTUnwrap(rig.savedTokens)
        rig.openAI.callbacks = { page in [["code": "test-code", "state": page["state"] ?? "", "client_id": "oaiapp_someone_else"]] }
        let postsBefore = rig.openAI.posts.count
        await assertFails(.failed) { _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
        XCTAssertEqual(rig.openAI.posts.count, postsBefore, "the code was not exchanged")
        XCTAssertEqual(rig.savedRegistration?.clientID, "oaiapp_test_client", "the registration wasn't replaced")
        XCTAssertEqual(rig.savedTokens?.refreshToken, tokensBefore.refreshToken)
    }

    func testTheCallbackClientRules() throws {
        let first = AgentChatGPTRegistration(hostID: "urn:uuid:3f1a2b4c-0000-4000-8000-000000000001", clientID: nil)
        let returning = AgentChatGPTRegistration(hostID: first.hostID, clientID: "oaiapp_mine")
        XCTAssertEqual(try AgentChatGPTSignIn.client(from: ["code": "c", "client_id": "oaiapp_new"], registration: first), "oaiapp_new")
        XCTAssertThrowsError(try AgentChatGPTSignIn.client(from: ["code": "c"], registration: first), "a registration with no client")
        XCTAssertThrowsError(try AgentChatGPTSignIn.client(from: ["code": "c", "client_id": "dynamic_agent_client"], registration: first))
        XCTAssertThrowsError(try AgentChatGPTSignIn.client(from: ["code": "c", "client_id": "oaiapp new&x=1"], registration: first))
        XCTAssertEqual(try AgentChatGPTSignIn.client(from: ["code": "c"], registration: returning), "oaiapp_mine")
        XCTAssertEqual(try AgentChatGPTSignIn.client(from: ["code": "c", "client_id": "oaiapp_mine"], registration: returning),
                       "oaiapp_mine")
        XCTAssertThrowsError(try AgentChatGPTSignIn.client(from: ["code": "c", "client_id": "oaiapp_other"], registration: returning))
        XCTAssertThrowsError(try AgentChatGPTSignIn.client(from: ["error": "access_denied"], registration: returning)) { error in
            XCTAssertEqual(error as? AgentSignInFailure, .declined)
        }
    }

    func testASignInWithoutPlanUseKeepsTheClientButNoTokens() async {
        let rig = Rig()
        rig.openAI.grantedScope = "openid profile email offline_access resource.invoke"
        await assertFails(.planOff) { _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
        XCTAssertNil(rig.savedTokens, "nothing is spent on a plan the sign-in doesn't allow")
        XCTAssertEqual(rig.savedRegistration?.clientID, "oaiapp_test_client", "the next try reuses the client")
    }

    func testAnIDTokenThatFailsItsChecksSavesNothing() async {
        let cases: [(String, (String, String) -> [String: AgentJSON])] = [
            ("another nonce", { AgentTestSigner.claims(clientID: $0, nonce: "not-" + $1) }),
            ("another audience", { client, nonce in AgentTestSigner.claims(clientID: "oaiapp_other", nonce: nonce) }),
            ("expired", { AgentTestSigner.claims(clientID: $0, nonce: $1, now: Date().addingTimeInterval(-7_200)) })
        ]
        for (name, claims) in cases {
            let rig = Rig()
            rig.openAI.idClaims = claims
            await assertFails(.failed, name) { _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
            XCTAssertNil(rig.savedTokens, name)
        }
        // A token signed by a key OpenAI doesn't publish.
        let rig = Rig()
        let stranger = AgentTestSigner(.p256, keyID: "test-key-1")
        rig.openAI.overrides["keys"] = .success(AgentHTTPReply(status: 200, body: stranger.keyList))
        await assertFails(.failed) { _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
        XCTAssertNil(rig.savedTokens)
    }

    func testABrowserThatWontOpenATimeoutAndAnUnreachableHostEachHaveTheirFailure() async {
        let closed = Rig()
        closed.openAI.opens = false
        await assertFails(.noBrowser) { _ = try await closed.signIn.run(openInBrowser: closed.openAI.opener) }
        XCTAssertEqual(closed.listener.stops, 1, "the listener stops")

        let slow = Rig()
        slow.listener.failure = .timedOut
        await assertFails(.timedOut) { _ = try await slow.signIn.run(openInBrowser: slow.openAI.opener) }

        let offline = Rig()
        offline.openAI.overrides["token"] = .failure(AgentTransportError.unreachable)
        await assertFails(.unreachable) { _ = try await offline.signIn.run(openInBrowser: offline.openAI.opener) }

        let refused = Rig()
        refused.openAI.overrides["token"] = .success(AgentHTTPReply(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        await assertFails(.failed) { _ = try await refused.signIn.run(openInBrowser: refused.openAI.opener) }
        XCTAssertNil(refused.savedTokens)
    }

    func testStoppingTheTaskStopsTheListener() async {
        let rig = Rig()
        rig.listener.failure = .cancelled
        let task = Task { try await rig.signIn.run(openInBrowser: rig.openAI.opener) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a stopped sign-in doesn't finish")
        } catch {
            XCTAssertEqual(error as? AgentSignInFailure, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(rig.listener.stops, 1)
    }

    // MARK: Signing out

    func testSigningOutRevokesTheRefreshTokenRemovesTheTokensAndKeepsTheRegistration() async throws {
        let rig = Rig()
        _ = try await rig.signIn.run(openInBrowser: rig.openAI.opener)
        let out = AgentChatGPTSignIn(store: rig.store, transport: rig.openAI, makeListener: { rig.listener })
        let confirmed = await out.signOut()
        XCTAssertTrue(confirmed)
        let revoke = try XCTUnwrap(rig.openAI.posts.first { $0.route == "revoke:/oauth/revoke" }?.form)
        XCTAssertEqual(revoke, ["token": "test-refresh-token-0001", "token_type_hint": "refresh_token",
                                "client_id": "oaiapp_test_client"])
        XCTAssertNil(rig.savedTokens)
        XCTAssertNil(rig.store.signInNote(.chatGPTTokens))
        XCTAssertEqual(rig.savedRegistration?.clientID, "oaiapp_test_client", "the client and host ID stay for next time")
    }

    func testARevocationOpenAIDoesntConfirmStillRemovesTheTokens() async throws {
        for (name, setUp) in [("a revocation elsewhere", { (openAI: AgentStubOpenAI) in
                                    openAI.revocationEndpoint = "https://auth.example.com/oauth/revoke" }),
                              ("no discovery", { (openAI: AgentStubOpenAI) in
                                    openAI.overrides["discovery"] = .failure(AgentTransportError.unreachable) }),
                              ("a refused revocation", { (openAI: AgentStubOpenAI) in
                                    openAI.overrides["revoke:/oauth/revoke"] = .success(AgentHTTPReply(status: 503, body: Data())) })] {
            let rig = Rig()
            try rig.saveTokens()
            setUp(rig.openAI)
            let out = AgentChatGPTSignIn(store: rig.store, transport: rig.openAI, makeListener: { rig.listener })
            let confirmed = await out.signOut()
            XCTAssertFalse(confirmed, name)
            XCTAssertNil(rig.savedTokens, name)
        }
    }

    func testTheRevocationPathMustBeOnTheSignInHost() {
        func path(_ endpoint: String) -> String? {
            AgentChatGPTSignIn.revocationPath(in: AgentJSON.object(["revocation_endpoint": .string(endpoint)]).data())
        }
        XCTAssertEqual(path("https://auth.openai.com/oauth/revoke"), "/oauth/revoke")
        XCTAssertEqual(path("https://auth.openai.com:443/oauth/revoke"), "/oauth/revoke")
        XCTAssertNil(path("https://auth.example.com/oauth/revoke"))
        XCTAssertNil(path("http://auth.openai.com/oauth/revoke"))
        XCTAssertNil(path("https://auth.openai.com:8443/oauth/revoke"))
        XCTAssertNil(path("https://user@auth.openai.com/oauth/revoke"))
        XCTAssertNil(path("https://auth.openai.com/oauth/revoke?next=1"))
        XCTAssertNil(path("https://auth.openai.com/oauth/../revoke"))
        XCTAssertNil(path("https://auth.openai.com/oauth/%2e%2e/revoke"))
    }

    // MARK: Forms

    func testFormFieldsAreEscapedButForTheUnreservedCharacters() {
        let body = String(decoding: AgentFormBody.encode([("a b", "c+d/e=f&g"), ("x", "~._-AZaz09")]), as: UTF8.self)
        XCTAssertEqual(body, "a%20b=c%2Bd%2Fe%3Df%26g&x=~._-AZaz09")
    }

    func testTheRefreshFormKeepsTheGrantAndNamesTheIssuedClient() throws {
        let tokens = AgentChatGPTTokens(clientID: "oaiapp_test_client", accessToken: "test-access", refreshToken: "test-refresh",
                                        idToken: nil, expiresAt: Date(), scopes: [])
        let form = Dictionary(AgentChatGPTSignIn.refreshForm(tokens)) { first, _ in first }
        XCTAssertEqual(form, ["grant_type": "refresh_token", "client_id": "oaiapp_test_client", "refresh_token": "test-refresh",
                              "resource": "https://api.openai.com/v1"])
        XCTAssertNil(form["scope"], "no scope, so the grant stays as it was")
    }

    // MARK: Parts

    private func assertFails(_ expected: AgentSignInFailure, _ message: String = "", file: StaticString = #filePath,
                             line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentSignInFailure, expected, message, file: file, line: line)
        }
    }
}
