import XCTest
@testable import HelmAgent

/// The ChatGPT sign-in's access token as the transport asks for it: read from the store once, renewed before it runs
/// out and when OpenAI turns it away, with the rotated refresh token saved each time. Against a memory store and a
/// stub token endpoint; nothing reaches OpenAI or the keychain.
final class AgentChatGPTBearerTests: XCTestCase {
    private func reply(access: String, refresh: String?, scope: String? = "openid offline_access chatgpt.tokens.use.direct",
                       status: Int = 200) -> AgentHTTPReply {
        var body: [String: AgentJSON] = ["access_token": .string(access), "token_type": .string("Bearer"), "expires_in": .number(3_600)]
        if let refresh { body["refresh_token"] = .string(refresh) }
        if let scope { body["scope"] = .string(scope) }
        return AgentHTTPReply(status: status, body: AgentJSON.object(body).data())
    }

    private func token(_ secret: AgentSecret) -> String { secret.revealSecret() }

    func testAFreshTokenIsReadOnceAndHandedOutWithoutARefresh() async throws {
        let rig = AgentSignInRig()
        try rig.saveTokens(expiresIn: 3_600)
        let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        let handed1 = try await bearer.bearerToken()
        XCTAssertEqual(token(handed1), "test-access-token-0001")
        let handed2 = try await bearer.bearerToken()
        XCTAssertEqual(token(handed2), "test-access-token-0001")
        XCTAssertTrue(rig.openAI.posts.isEmpty, "nothing was renewed")
    }

    func testATokenAboutToRunOutIsRenewedAndTheRotatedRefreshTokenIsSaved() async throws {
        let rig = AgentSignInRig()
        try rig.saveTokens(expiresIn: 60)
        rig.openAI.overrides["token"] = .success(reply(access: "test-access-token-0002", refresh: "test-refresh-token-0002"))
        let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        let handed3 = try await bearer.bearerToken()
        XCTAssertEqual(token(handed3), "test-access-token-0002")
        let refresh = try XCTUnwrap(rig.openAI.posts.first)
        XCTAssertEqual(refresh.route, "token")
        XCTAssertEqual(refresh.form, ["grant_type": "refresh_token", "client_id": "oaiapp_test_client",
                                      "refresh_token": "test-refresh-token-0001", "resource": "https://api.openai.com/v1"])
        let saved = try XCTUnwrap(rig.savedTokens)
        XCTAssertEqual(saved.accessToken, "test-access-token-0002")
        XCTAssertEqual(saved.refreshToken, "test-refresh-token-0002", "the rotated refresh token replaces the spent one")
        XCTAssertGreaterThan(saved.expiresAt.timeIntervalSinceNow, 3_000)
        XCTAssertEqual(rig.store.signInNote(.chatGPTTokens), "person@example.com", "the account's email stays beside it")
        // The renewed token is held, so the next request asks nothing.
        let handed4 = try await bearer.bearerToken()
        XCTAssertEqual(token(handed4), "test-access-token-0002")
        XCTAssertEqual(rig.openAI.posts.count, 1)
    }

    func testAnAnswerWithNoNewRefreshTokenKeepsTheOldOne() async throws {
        let rig = AgentSignInRig()
        try rig.saveTokens(expiresIn: 0)
        rig.openAI.overrides["token"] = .success(reply(access: "test-access-token-0002", refresh: nil, scope: nil))
        let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        let handed5 = try await bearer.bearerToken()
        XCTAssertEqual(token(handed5), "test-access-token-0002")
        XCTAssertEqual(rig.savedTokens?.refreshToken, "test-refresh-token-0001")
        XCTAssertEqual(rig.savedTokens?.allowsPlan, true, "an answer that names no scope keeps the scopes before")
    }

    func testATokenOpenAITurnedAwayIsRenewedEvenBeforeItRunsOut() async throws {
        let rig = AgentSignInRig()
        try rig.saveTokens(expiresIn: 3_600)
        rig.openAI.overrides["token"] = .success(reply(access: "test-access-token-0002", refresh: "test-refresh-token-0002"))
        let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        _ = try await bearer.bearerToken()
        let handed6 = try await bearer.renewedToken()
        XCTAssertEqual(token(handed6), "test-access-token-0002")
        XCTAssertEqual(rig.openAI.posts.count, 1)
    }

    func testANewerTokenSavedMeanwhileIsUsedInPlaceOfARenewal() async throws {
        // Another client renewed first: the store holds a newer token than the one turned away, so it is taken as is.
        let rig = AgentSignInRig()
        try rig.saveTokens(access: "test-access-token-0001", expiresIn: 3_600)
        let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        _ = try await bearer.bearerToken()
        try rig.saveTokens(access: "test-access-token-0003", refresh: "test-refresh-token-0003", expiresIn: 3_600)
        let handed7 = try await bearer.renewedToken()
        XCTAssertEqual(token(handed7), "test-access-token-0003")
        XCTAssertTrue(rig.openAI.posts.isEmpty, "the newer refresh token wasn't spent")
    }

    func testRenewalsAcrossBearersAreMadeOneAtATime() async throws {
        let rig = AgentSignInRig()
        try rig.saveTokens(expiresIn: 0)
        rig.openAI.overrides["token"] = .success(reply(access: "test-access-token-0002", refresh: "test-refresh-token-0002"))
        let first = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        let second = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        async let one = first.bearerToken()
        async let two = second.bearerToken()
        let tokens = try await [token(one), token(two)]
        XCTAssertEqual(tokens, ["test-access-token-0002", "test-access-token-0002"])
        XCTAssertEqual(rig.openAI.posts.count, 1, "the second found the first one's renewal and spent nothing")
    }

    func testARefreshTokenThatCantBeUsedAgainEndsTheSignIn() async throws {
        for code in ["invalid_grant", "refresh_token_reused", "refresh_token_expired", "invalid_client"] {
            let rig = AgentSignInRig()
            try rig.saveTokens(expiresIn: 0)
            rig.openAI.overrides["token"] = .success(AgentHTTPReply(status: 400, body: Data(#"{"error":"\#(code)"}"#.utf8)))
            let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
            await XCTAssertThrowsBearer(.noKey, code) { _ = try await bearer.bearerToken() }
            XCTAssertNil(rig.savedTokens, code)
            XCTAssertFalse(rig.store.hasSignIn(.chatGPTTokens), code)
        }
    }

    func testABusyOrUnreachableTokenEndpointKeepsTheSignIn() async throws {
        for override in [Result<AgentHTTPReply, Error>.success(AgentHTTPReply(status: 503, body: Data())),
                         .failure(AgentTransportError.unreachable)] {
            let rig = AgentSignInRig()
            try rig.saveTokens(expiresIn: 0)
            rig.openAI.overrides["token"] = override
            let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
            await XCTAssertThrowsBearer(.unreachable) { _ = try await bearer.bearerToken() }
            XCTAssertEqual(rig.savedTokens?.refreshToken, "test-refresh-token-0001", "the sign-in is kept for later")
        }
    }

    func testASignInThatLostPlanUseOrIsMissingAsksForANewOne() async throws {
        let none = AgentSignInRig()
        await XCTAssertThrowsBearer(.noKey) { _ = try await AgentChatGPTBearer(store: none.store, transport: none.openAI).bearerToken() }

        let narrowed = AgentSignInRig()
        try narrowed.saveTokens(expiresIn: 0)
        narrowed.openAI.overrides["token"] = .success(reply(access: "test-access-token-0002", refresh: "test-refresh-token-0002",
                                                            scope: "openid offline_access"))
        await XCTAssertThrowsBearer(.noKey) {
            _ = try await AgentChatGPTBearer(store: narrowed.store, transport: narrowed.openAI).bearerToken()
        }
        XCTAssertNil(narrowed.savedTokens)
    }

    func testAKeychainThatSaysNoIsKeyDenied() async throws {
        let rig = AgentSignInRig()
        try rig.saveTokens()
        rig.store.denies = true
        await XCTAssertThrowsBearer(.keyDenied) { _ = try await AgentChatGPTBearer(store: rig.store, transport: rig.openAI).bearerToken() }
    }

    func testForgettingLetsGoOfTheTokensAndTheTransport() async throws {
        let rig = AgentSignInRig()
        try rig.saveTokens()
        let bearer = AgentChatGPTBearer(store: rig.store, transport: rig.openAI)
        _ = try await bearer.bearerToken()
        bearer.forget()
        await XCTAssertThrowsBearer(.cancelled) { _ = try await bearer.bearerToken() }
        for _ in 0..<50 where rig.openAI.shutdowns == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(rig.openAI.shutdowns, 1)
        XCTAssertNotNil(rig.savedTokens, "forgetting signs nobody out")
    }

    private func XCTAssertThrowsBearer(_ expected: AgentTransportError, _ message: String = "", file: StaticString = #filePath,
                                       line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentTransportError, expected, message, file: file, line: line)
        }
    }
}
