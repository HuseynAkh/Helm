import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// The runtime with OpenAI reached by a ChatGPT sign-in: ready only once signed in, a sign-in only while AI mode is on
/// in a run that can sign in, and a sign-out that removes the tokens. Fake clients and the stub OpenAI stand in.
@MainActor final class AgentRuntimeChatGPTTests: XCTestCase {
    private final class ListingClient: AgentLiveClient, @unchecked Sendable {
        let profile: AgentProviderProfile
        let answer: Result<[AgentModelInfo], AgentFailure>
        init(profile: AgentProviderProfile, answer: Result<[AgentModelInfo], AgentFailure>) {
            self.profile = profile; self.answer = answer
        }
        var providerName: String { profile.name }
        var destination: String { profile.destination }
        var isLocal: Bool { profile.isLocal }
        func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> { AsyncThrowingStream { $0.finish() } }
        func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { [] }
        func structured(_ ask: AgentStructuredAsk) async throws -> Data { Data() }
        func models() async throws -> [AgentModelInfo] { try answer.get() }
        func shutdown() async {}
    }

    private let rig = AgentSignInRig()
    private var answer: Result<[AgentModelInfo], AgentFailure> = .success([AgentModelInfo(id: "gpt-6.1-sol")].compactMap { $0 })

    private func runtime(signsIn: Bool = true) -> AgentRuntime {
        let rig = self.rig, answer = self.answer
        let makeClient: @Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient = { profile, _, _ in
            ListingClient(profile: profile, answer: answer)
        }
        var makeSignIn: (@Sendable (any AgentSecretStoring) -> AgentChatGPTSignIn)?
        if signsIn {
            let openAI = rig.openAI, listener = rig.listener
            makeSignIn = { store in AgentChatGPTSignIn(store: store, transport: openAI, makeListener: { listener }) }
        }
        let parts = AgentRuntimeParts(secrets: rig.store, disk: MemoryAgentDisk(), home: "/home/helm",
                                      supportFolder: "/home/helm/.support", clock: FakeClock(), buildStamp: "",
                                      makeClient: makeClient, makeSignIn: makeSignIn)
        return AgentRuntime(parts: parts)
    }

    func testOpenAIWithAChatGPTSignInIsReadyOnlyOnceSignedIn() async throws {
        let runtime = runtime()
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "openAI"))
        XCTAssertEqual(runtime.state, .notReady)
        guard case .failure(.noKey) = runtime.client() else { return XCTFail("no client without a sign-in") }
        let unchecked = await runtime.check(AIConfig(provider: "openAI"))
        XCTAssertEqual(unchecked, .noKey, "nothing is asked without a sign-in")
        XCTAssertEqual(runtime.clientBuildCount, 0)

        try rig.saveTokens()
        runtime.chatGPTSignInChanged()
        XCTAssertEqual(runtime.state, .ready(provider: "ChatGPT", destination: "OpenAI", model: "gpt-6-astra", isLocal: false))
        let checked = await runtime.check(AIConfig(provider: "openAI"))
        XCTAssertEqual(checked, .connected([AgentModelInfo(id: "gpt-6.1-sol")].compactMap { $0 }))
        // A saved key doesn't make OpenAI ready while the ChatGPT sign-in is the way in, and the other way round.
        try rig.store.removeSignIn(.chatGPTTokens)
        try rig.store.save(XCTUnwrap(AgentSecret(pasted: "test-key-0123456789-openai")),
                           for: AgentSecretID(provider: .openAI, host: "api.openai.com", port: 443))
        runtime.chatGPTSignInChanged()
        XCTAssertEqual(runtime.state, .notReady)
        runtime.configure(AIConfig(provider: "openAI", openAIUsesKey: true))
        XCTAssertEqual(runtime.state, .ready(provider: "OpenAI", destination: "OpenAI", model: "gpt-6-astra", isLocal: false))
    }

    func testAPlanAtItsLimitOrThatDoesntCoverHelmSaysSoInTheCheck() async throws {
        try rig.saveTokens()
        answer = .failure(.outOfCredit)
        let limited = runtime()
        limited.setOn(true)
        let atLimit = await limited.check(AIConfig(provider: "openAI"))
        XCTAssertEqual(atLimit, .planLimit)
        answer = .failure(.noSuchModel)
        let narrow = runtime()
        narrow.setOn(true)
        let notCovered = await narrow.check(AIConfig(provider: "openAI"))
        XCTAssertEqual(notCovered, .planNotCovered)
        // With a key, the same answers keep their usual meaning.
        try rig.store.save(XCTUnwrap(AgentSecret(pasted: "test-key-0123456789-openai")),
                           for: AgentSecretID(provider: .openAI, host: "api.openai.com", port: 443))
        let keyed = await narrow.check(AIConfig(provider: "openAI", openAIUsesKey: true))
        XCTAssertEqual(keyed, .cantReach)
    }

    func testASignInIsOnlyHadWhileAIModeIsOnInARunThatCanSignIn() {
        let runtime = runtime()
        XCTAssertNil(runtime.chatGPTSignIn(), "nothing reaches OpenAI's sign-in host while AI mode is off")
        runtime.setOn(true)
        XCTAssertNotNil(runtime.chatGPTSignIn())
        let fixture = self.runtime(signsIn: false)
        fixture.setOn(true)
        XCTAssertNil(fixture.chatGPTSignIn(), "a fixture run never signs in")
    }

    func testSigningOutRemovesTheTokensAndTheStateFollows() async throws {
        try rig.saveTokens()
        let runtime = runtime()
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "openAI"))
        XCTAssertNotEqual(runtime.state, .notReady)
        let confirmed = await runtime.signOutOfChatGPT()
        XCTAssertTrue(confirmed)
        XCTAssertFalse(rig.store.hasSignIn(.chatGPTTokens))
        XCTAssertEqual(runtime.state, .notReady)
        XCTAssertTrue(rig.openAI.posts.contains { $0.route == "revoke:/oauth/revoke" })
        // With AI mode off, the tokens still go, and OpenAI is asked nothing.
        try rig.saveTokens()
        runtime.setOn(false)
        let posts = rig.openAI.posts.count
        let offline = await runtime.signOutOfChatGPT()
        XCTAssertFalse(offline, "a revocation that wasn't asked for isn't confirmed")
        XCTAssertFalse(rig.store.hasSignIn(.chatGPTTokens))
        XCTAssertEqual(rig.openAI.posts.count, posts)
    }
}
