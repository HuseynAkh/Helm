import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// AI mode's switch: nothing is built while it is off, turning it off lets go of everything, and a change of
/// provider starts every conversation over.
@MainActor final class AgentRuntimeTests: XCTestCase {
    // MARK: Stand-ins

    /// Holds a model list back until it is opened.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen { lock.unlock(); continuation.resume(); return }
                waiting.append(continuation)
                lock.unlock()
            }
        }
        func open() {
            lock.lock(); isOpen = true; let held = waiting; waiting = []; lock.unlock()
            for continuation in held { continuation.resume() }
        }
    }

    /// A live client that reaches nothing. It counts how often it was shut down.
    private final class FakeLiveClient: AgentLiveClient, @unchecked Sendable {
        let profile: AgentProviderProfile
        let model: String
        private let lock = NSLock()
        private var shutdownCount = 0
        private let listed: Result<[AgentModelInfo], AgentFailure>
        private let gate: Gate?

        init(profile: AgentProviderProfile, model: String, listed: Result<[AgentModelInfo], AgentFailure>, gate: Gate? = nil) {
            self.profile = profile; self.model = model; self.listed = listed; self.gate = gate
        }
        var shutdowns: Int { lock.lock(); defer { lock.unlock() }; return shutdownCount }
        var providerName: String { profile.name }
        var destination: String { profile.destination }
        var isLocal: Bool { profile.isLocal }
        func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> { AsyncThrowingStream { $0.finish() } }
        func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { [] }
        func structured(_ ask: AgentStructuredAsk) async throws -> Data { Data() }
        func models() async throws -> [AgentModelInfo] {
            await gate?.wait()
            return try listed.get()
        }
        func shutdown() async { count() }
        private func count() { lock.lock(); shutdownCount += 1; lock.unlock() }
    }

    /// Makes live clients, and keeps each one it made.
    private final class Factory: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeLiveClient] = []
        private var answer: Result<[AgentModelInfo], AgentFailure> = .success([AgentModelInfo(id: "model-a"), AgentModelInfo(id: "model-b")].compactMap { $0 })
        private var heldBy: Gate?

        var built: [FakeLiveClient] { lock.lock(); defer { lock.unlock() }; return made }
        var listed: Result<[AgentModelInfo], AgentFailure> {
            get { lock.lock(); defer { lock.unlock() }; return answer }
            set { lock.lock(); answer = newValue; lock.unlock() }
        }
        /// When set, every client made from then on holds its model list back until the gate opens.
        var gate: Gate? {
            get { lock.lock(); defer { lock.unlock() }; return heldBy }
            set { lock.lock(); heldBy = newValue; lock.unlock() }
        }
        func make(_ profile: AgentProviderProfile, _ model: String) -> FakeLiveClient {
            lock.lock(); defer { lock.unlock() }
            let client = FakeLiveClient(profile: profile, model: model, listed: answer, gate: heldBy)
            made.append(client)
            return client
        }
    }

    /// A conversation that counts what the runtime asks of it.
    private final class CountingConversation: AgentConversing, @unchecked Sendable {
        let parts: AgentSessionParts
        private let lock = NSLock()
        private var calls: [String] = []
        let notices: AsyncStream<AgentNotice> = AsyncStream { $0.finish() }

        init(parts: AgentSessionParts) { self.parts = parts }
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return calls }
        private func note(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }

        func roots() async -> [AgentScopeRoot] { [] }
        func setTabFolder(_ input: AgentRootInput?) async -> AgentTabFolder { .none }
        func folder(for input: AgentRootInput) async -> AgentFolderRef { .refused(.notFound) }
        func removeRoot(alias: String) async {}
        func send(_ input: AgentPersonInput) -> AsyncStream<AgentSessionEvent> { AsyncStream { $0.finish() } }
        func beginApply(planID: UUID, ticked: Set<Int>) async -> AgentApplyTicket { .refused }
        func settle(planID: UUID, _ outcome: AgentPlanOutcome) async {}
        func stop() async { note("stop") }
        func startOver() async { note("startOver") }
        func clear() async { note("clear") }
    }

    private final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [CountingConversation] = []
        var sessions: [CountingConversation] { lock.lock(); defer { lock.unlock() }; return list }
        func make(_ parts: AgentSessionParts) -> CountingConversation {
            let session = CountingConversation(parts: parts)
            lock.lock(); list.append(session); lock.unlock()
            return session
        }
    }

    private let secrets = MemorySecretStore()
    private let factory = Factory()
    private let made = Made()

    private func makeRuntime(scripted: (any AgentModelClient)? = nil, live: Bool = true, countsSessions: Bool = true) -> AgentRuntime {
        let factory = self.factory, made = self.made
        var makeClient: (@Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient)?
        if live { makeClient = { profile, model, _ in factory.make(profile, model) } }
        var makeSession: (@Sendable (AgentSessionParts) -> any AgentConversing)?
        if countsSessions { makeSession = { made.make($0) } }
        return AgentRuntime(parts: AgentRuntimeParts(
            secrets: secrets, disk: MemoryAgentDisk(), home: "/home/helm", supportFolder: "/home/helm/Library/Application Support/Helm",
            clock: FakeClock(), buildStamp: "1024-1700000000", scripted: scripted, makeClient: makeClient, makeSession: makeSession))
    }

    private func saveKey(for provider: AgentProviderID, otherAddress: String? = nil) throws {
        let profile = try AgentProviderCatalog.profile(for: AIConfig(provider: provider.rawValue, otherAddress: otherAddress)).get()
        try secrets.save(try XCTUnwrap(AgentSecret(pasted: "stand-in-for-tests")), for: profile.secretID)
    }

    private func expectFailure(_ result: Result<any AgentModelClient, AgentFailure>, _ failure: AgentFailure, line: UInt = #line) {
        guard case .failure(let found) = result else { return XCTFail("a client was handed over", line: line) }
        XCTAssertEqual(found, failure, line: line)
    }

    // MARK: Off

    func testARuntimeStartsOffWithAnEmptyConfig() async {
        let runtime = makeRuntime()
        XCTAssertFalse(runtime.isOn)
        XCTAssertEqual(runtime.state, .off)
        XCTAssertEqual(runtime.config, AIConfig())
        XCTAssertEqual(runtime.clientBuildCount, 0)
        XCTAssertNil(runtime.makeSession())
        XCTAssertNil(runtime.listSecondsOverrideForTesting)
        XCTAssertNil(runtime.scriptedClientForTesting)
        expectFailure(runtime.client(), .off)
    }

    func testWhileOffTheClientFactoryIsNeverCalled() async throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        let config = AIConfig(provider: "claude")
        runtime.configure(config)
        XCTAssertEqual(runtime.config, config)
        XCTAssertEqual(runtime.state, .off)
        expectFailure(runtime.client(), .off)
        let checked = await runtime.check(config)
        XCTAssertEqual(checked, .off)
        let other = await runtime.check(AIConfig(provider: "ollama", models: ["ollama": "llama"]))
        XCTAssertEqual(other, .off)
        XCTAssertNil(runtime.makeSession())
        runtime.configure(AIConfig(provider: "openAI", openAIUsesKey: true))
        runtime.setOn(false)
        await runtime.settle()
        XCTAssertEqual(factory.built.count, 0)
        XCTAssertEqual(runtime.clientBuildCount, 0)
        XCTAssertEqual(made.sessions.count, 0)
    }

    // MARK: On

    func testTheClientIsBuiltOnFirstUseAndOnce() throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        runtime.configure(AIConfig(provider: "claude"))
        runtime.setOn(true)
        XCTAssertTrue(runtime.isOn)
        XCTAssertEqual(runtime.state, .ready(provider: "Claude", destination: "Claude", model: "claude-opus-5-5", isLocal: false))
        XCTAssertEqual(factory.built.count, 0, "being ready builds nothing")

        guard case .success(let first) = runtime.client() else { return XCTFail("no client") }
        XCTAssertEqual(factory.built.count, 1)
        XCTAssertEqual(runtime.clientBuildCount, 1)
        XCTAssertEqual(factory.built[0].profile.secretID.account, "claude|api.anthropic.com:443")
        XCTAssertEqual(factory.built[0].model, "claude-opus-5-5")
        guard case .success(let second) = runtime.client() else { return XCTFail("no client") }
        XCTAssertTrue((first as AnyObject) === (second as AnyObject))
        XCTAssertEqual(runtime.clientBuildCount, 1)
    }

    func testAProviderThatNeedsAKeyIsNotReadyWithoutOne() throws {
        let runtime = makeRuntime()
        runtime.setOn(true)
        XCTAssertEqual(runtime.state, .notReady, "no provider is chosen")
        expectFailure(runtime.client(), .notReady)

        runtime.configure(AIConfig(provider: "claude"))
        XCTAssertEqual(runtime.state, .notReady)
        expectFailure(runtime.client(), .noKey)
        XCTAssertEqual(factory.built.count, 0)

        // The key store isn't watched: the config changes when a key is saved, and the state is worked out again.
        try saveKey(for: .claude)
        runtime.configure(AIConfig(provider: "claude", keyOwners: ["claude|api.anthropic.com:443": "1024-1700000000"]))
        XCTAssertEqual(runtime.state, .ready(provider: "Claude", destination: "Claude", model: "claude-opus-5-5", isLocal: false))
        // A key saved for one provider isn't another's.
        runtime.configure(AIConfig(provider: "openAI", openAIUsesKey: true))
        XCTAssertEqual(runtime.state, .notReady)
        expectFailure(runtime.client(), .noKey)
    }

    func testALocalProviderNeedsAModelAndNoKey() {
        let runtime = makeRuntime()
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "ollama"))
        XCTAssertEqual(runtime.state, .notReady, "a local provider preselects no model")
        expectFailure(runtime.client(), .notReady)
        runtime.configure(AIConfig(provider: "ollama", models: ["ollama": "llama3.2:latest"]))
        XCTAssertEqual(runtime.state, .ready(provider: "Ollama", destination: "Ollama on this Mac", model: "llama3.2:latest", isLocal: true))
        guard case .success = runtime.client() else { return XCTFail("no client") }
        XCTAssertEqual(factory.built.last?.profile.endpoint.hostAndPort, "127.0.0.1:11434")
    }

    func testATypedProviderIsReadyOnlyWithAnAddressHelmWillSendTo() {
        let runtime = makeRuntime()
        runtime.setOn(true)
        for address in [nil, "192.168.1.20:8080", "http://models.example.com", "studio.local", "user:pass@models.example.com"] {
            runtime.configure(AIConfig(provider: "other", models: ["other": "some-model"], otherAddress: address))
            XCTAssertEqual(runtime.state, .notReady, address ?? "no address")
            expectFailure(runtime.client(), .notReady)
        }
        runtime.configure(AIConfig(provider: "other", models: ["other": "some-model"], otherAddress: "models.example.com/v1"))
        XCTAssertEqual(runtime.state, .ready(provider: "Other", destination: "models.example.com", model: "some-model", isLocal: false))
        XCTAssertEqual(factory.built.count, 0)
    }

    func testARuntimeWithNoFactoryNeverBuildsAClient() async throws {
        let runtime = makeRuntime(live: false)
        try saveKey(for: .claude)
        runtime.configure(AIConfig(provider: "claude"))
        runtime.setOn(true)
        XCTAssertEqual(runtime.state, .notReady, "with no way to make a client there is nothing to be ready with")
        expectFailure(runtime.client(), .notReady)
        XCTAssertNil(runtime.makeSession())
        let checked = await runtime.check(AIConfig(provider: "claude"))
        XCTAssertEqual(checked, .cantReach)
        XCTAssertEqual(runtime.clientBuildCount, 0)
    }

    // MARK: Turning off

    func testTurningOffShutsTheClientDownAndStopsEverySession() async throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        runtime.configure(AIConfig(provider: "claude"))
        runtime.setOn(true)
        guard case .success = runtime.client() else { return XCTFail("no client") }
        let first = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        let second = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        XCTAssertEqual(made.sessions.count, 2)
        XCTAssertEqual(factory.built[0].shutdowns, 0)

        runtime.setOn(false)
        XCTAssertEqual(runtime.state, .off)
        XCTAssertFalse(runtime.isOn)
        expectFailure(runtime.client(), .off)
        XCTAssertNil(runtime.makeSession())
        await runtime.settle()
        XCTAssertEqual(factory.built[0].shutdowns, 1)
        XCTAssertEqual(first.asked, ["stop", "clear"])
        XCTAssertEqual(second.asked, ["stop", "clear"])
        // A conversation made before can't get a client any more.
        let late = await first.parts.client()
        expectFailure(late, .off)

        // On again: a new client on first use. A conversation still held works again and is still the runtime's,
        // so a changed provider starts it over and the next off stops and clears it again.
        runtime.setOn(true)
        guard case .success = runtime.client() else { return XCTFail("no client") }
        XCTAssertEqual(factory.built.count, 2)
        XCTAssertEqual(runtime.clientBuildCount, 2)
        guard case .success = await first.parts.client() else { return XCTFail("no client") }
        runtime.configure(AIConfig(provider: "ollama", models: ["ollama": "llama"]))
        await runtime.settle()
        XCTAssertEqual(first.asked, ["stop", "clear", "startOver"])
        XCTAssertEqual(second.asked, ["stop", "clear", "startOver"])
        runtime.setOn(false)
        await runtime.settle()
        XCTAssertEqual(first.asked, ["stop", "clear", "startOver", "stop", "clear"])
        XCTAssertEqual(second.asked, ["stop", "clear", "startOver", "stop", "clear"])
    }

    func testTurningOffShutsDownAClientOutForACheck() async throws {
        let runtime = makeRuntime()
        for provider in [AgentProviderID.claude, .openAI] { try saveKey(for: provider) }
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "claude"))
        let gate = Gate()
        factory.gate = gate
        let checking = Task { await runtime.check(AIConfig(provider: "openAI", openAIUsesKey: true)) }
        while factory.built.isEmpty { await Task.yield() }
        let probe = factory.built[0]
        XCTAssertEqual(probe.profile.id, .openAI)

        runtime.setOn(false)
        await runtime.settle()
        XCTAssertEqual(probe.shutdowns, 1, "shut down before its model list came back")
        gate.open()
        let answer = await checking.value
        XCTAssertEqual(answer, .off)
        XCTAssertEqual(probe.shutdowns, 1, "and only once")
    }

    func testTurningOffTwiceDoesNothingMore() async throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        runtime.configure(AIConfig(provider: "claude"))
        runtime.setOn(true)
        runtime.setOn(true)
        guard case .success = runtime.client() else { return XCTFail("no client") }
        runtime.setOn(false)
        runtime.setOn(false)
        await runtime.settle()
        XCTAssertEqual(factory.built[0].shutdowns, 1)
    }

    // MARK: A changed config

    func testAChangedProviderPortOrAddressStartsEverySessionOver() async throws {
        let runtime = makeRuntime()
        for provider in [AgentProviderID.claude, .openAI] { try saveKey(for: provider) }
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "claude"))
        let session = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        let other = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        guard case .success = runtime.client() else { return XCTFail("no client") }

        // Another provider.
        runtime.configure(AIConfig(provider: "openAI", openAIUsesKey: true))
        await runtime.settle()
        XCTAssertEqual(session.asked, ["startOver"])
        XCTAssertEqual(other.asked, ["startOver"])
        XCTAssertEqual(factory.built[0].shutdowns, 1, "the client for the old provider is shut down")
        guard case .success = runtime.client() else { return XCTFail("no client") }
        XCTAssertEqual(factory.built.count, 2)
        XCTAssertEqual(factory.built[1].profile.id, .openAI)

        // A local provider, then its port.
        var config = AIConfig(provider: "ollama", models: ["ollama": "llama"])
        runtime.configure(config)
        await runtime.settle()
        XCTAssertEqual(session.asked, ["startOver", "startOver"])
        guard case .success = runtime.client() else { return XCTFail("no client") }
        config.ports["ollama"] = 11500
        runtime.configure(config)
        await runtime.settle()
        XCTAssertEqual(session.asked, ["startOver", "startOver", "startOver"])
        XCTAssertEqual(factory.built[2].shutdowns, 1)
        guard case .success = runtime.client() else { return XCTFail("no client") }
        XCTAssertEqual(factory.built[3].profile.endpoint.port, 11500)
        // Another provider's port is not this provider's.
        config.ports["lmStudio"] = 4321
        runtime.configure(config)
        await runtime.settle()
        XCTAssertEqual(session.asked.count, 3)
        XCTAssertEqual(factory.built[3].shutdowns, 0)

        // A typed provider, then its address.
        config = AIConfig(provider: "other", models: ["other": "some-model"], otherAddress: "models.example.com")
        runtime.configure(config)
        await runtime.settle()
        XCTAssertEqual(session.asked.count, 4)
        guard case .success = runtime.client() else { return XCTFail("no client") }
        config.otherAddress = "other.example.com"
        runtime.configure(config)
        await runtime.settle()
        XCTAssertEqual(session.asked.count, 5)
        XCTAssertEqual(session.asked.last, "startOver")
        XCTAssertEqual(other.asked.count, 5)
        XCTAssertEqual(factory.built.last?.shutdowns, 1)
        // The sessions were started over and never stopped or cleared: their folders stay.
        XCTAssertFalse(session.asked.contains("clear"))
        XCTAssertFalse(session.asked.contains("stop"))
    }

    func testAChangedModelKeepsTheThreads() async throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "claude"))
        let session = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        guard case .success = runtime.client() else { return XCTFail("no client") }

        runtime.configure(AIConfig(provider: "claude", models: ["claude": "claude-haiku-5-5"]))
        await runtime.settle()
        XCTAssertEqual(session.asked, [], "a new model in the same provider keeps the thread")
        XCTAssertEqual(factory.built[0].shutdowns, 1, "but the client is made again for the new model")
        XCTAssertEqual(runtime.state, .ready(provider: "Claude", destination: "Claude", model: "claude-haiku-5-5", isLocal: false))
        guard case .success = runtime.client() else { return XCTFail("no client") }
        XCTAssertEqual(factory.built.count, 2)
        XCTAssertEqual(factory.built[1].model, "claude-haiku-5-5")

        // The same config again changes nothing.
        runtime.configure(AIConfig(provider: "claude", models: ["claude": "claude-haiku-5-5"]))
        // Another provider's saved model isn't this provider's model.
        runtime.configure(AIConfig(provider: "claude", models: ["claude": "claude-haiku-5-5", "openAI": "gpt-6-astra"]))
        await runtime.settle()
        XCTAssertEqual(session.asked, [])
        XCTAssertEqual(factory.built[1].shutdowns, 0)
        guard case .success = runtime.client() else { return XCTFail("no client") }
        XCTAssertEqual(factory.built.count, 2)
    }

    func testASavedOrRemovedKeyMakesTheClientAgain() async throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "claude"))
        let session = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        guard case .success = runtime.client() else { return XCTFail("no client") }
        // The client holds the key it first used, so a new key needs a new client. The thread is kept.
        runtime.configure(AIConfig(provider: "claude", keyOwners: ["claude|api.anthropic.com:443": "2048-1800000000"]))
        await runtime.settle()
        XCTAssertEqual(factory.built[0].shutdowns, 1)
        XCTAssertEqual(session.asked, [])
    }

    func testAKeyReplacedByTheSameBuildReachesTheClientAtTheNextCheck() async throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        let config = AIConfig(provider: "claude", keyOwners: ["claude|api.anthropic.com:443": "1024-1700000000"])
        runtime.setOn(true)
        runtime.configure(config)
        let session = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        guard case .connected = await runtime.check(config) else { return XCTFail("not connected") }
        XCTAssertEqual(factory.built.count, 1)

        // The same build saves another key under the same account, so the config is the same as before.
        try saveKey(for: .claude)
        runtime.configure(config)
        guard case .connected = await runtime.check(config) else { return XCTFail("not connected") }
        await runtime.settle()
        XCTAssertEqual(factory.built.count, 2, "the check makes the client again, which reads the store again")
        XCTAssertEqual(factory.built[0].shutdowns, 1)
        XCTAssertEqual(factory.built[1].shutdowns, 0, "the new client is the one in use")
        guard case .success(let current) = runtime.client() else { return XCTFail("no client") }
        XCTAssertTrue((current as AnyObject) === factory.built[1])
        XCTAssertEqual(session.asked, [], "the thread is kept")
    }

    func testChangesAreSentOnceForEachChange() throws {
        let runtime = makeRuntime()
        var seen: [AgentRuntimeState] = []
        let token = runtime.changes.subscribe { seen.append($0) }
        defer { runtime.changes.cancel(token) }
        try saveKey(for: .claude)

        runtime.setOn(true)
        XCTAssertEqual(seen, [.notReady])
        runtime.setOn(true)
        runtime.configure(AIConfig())
        XCTAssertEqual(seen, [.notReady])
        runtime.configure(AIConfig(provider: "claude"))
        let ready = AgentRuntimeState.ready(provider: "Claude", destination: "Claude", model: "claude-opus-5-5", isLocal: false)
        XCTAssertEqual(seen, [.notReady, ready])
        runtime.configure(AIConfig(provider: "claude"))
        runtime.configure(AIConfig(provider: "claude", ports: ["ollama": 11500]))
        XCTAssertEqual(seen, [.notReady, ready])
        runtime.configure(AIConfig(provider: "claude", models: ["claude": "claude-sonnet-5-5"]))
        XCTAssertEqual(seen.count, 3)
        runtime.setOn(false)
        runtime.setOn(false)
        XCTAssertEqual(seen.last, .off)
        XCTAssertEqual(seen.count, 4)
    }

    // MARK: Checking a connection

    func testACheckAsksTheDraftsProviderAndLeavesTheConfigAlone() async throws {
        let runtime = makeRuntime()
        for provider in [AgentProviderID.claude, .openAI] { try saveKey(for: provider) }
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "claude"))
        guard case .success = runtime.client() else { return XCTFail("no client") }

        // The config in use is checked through its client, made again so that the key is read again.
        var answer = await runtime.check(AIConfig(provider: "claude"))
        XCTAssertEqual(answer, .connected([AgentModelInfo(id: "model-a"), AgentModelInfo(id: "model-b")].compactMap { $0 }))
        await runtime.settle()
        XCTAssertEqual(factory.built.count, 2)
        XCTAssertEqual(factory.built[0].shutdowns, 1)
        guard case .success(let current) = runtime.client() else { return XCTFail("no client") }
        XCTAssertTrue((current as AnyObject) === factory.built[1])

        // A draft for another provider gets a client of its own, which is shut down afterwards.
        answer = await runtime.check(AIConfig(provider: "openAI", openAIUsesKey: true))
        XCTAssertEqual(answer, .connected([AgentModelInfo(id: "model-a"), AgentModelInfo(id: "model-b")].compactMap { $0 }))
        XCTAssertEqual(factory.built.count, 3)
        XCTAssertEqual(factory.built[2].profile.id, .openAI)
        XCTAssertEqual(factory.built[2].shutdowns, 1)
        XCTAssertEqual(factory.built[1].shutdowns, 0, "the client in use is left alone")
        XCTAssertEqual(runtime.config, AIConfig(provider: "claude"))
        XCTAssertEqual(runtime.clientBuildCount, 3)

        // A local provider can be checked before a model is chosen: that is how its models are found.
        answer = await runtime.check(AIConfig(provider: "lmStudio"))
        XCTAssertEqual(factory.built.last?.profile.endpoint.hostAndPort, "127.0.0.1:1234")
        XCTAssertEqual(factory.built.last?.shutdowns, 1)
        guard case .connected = answer else { return XCTFail("not connected") }
    }

    func testACheckSaysWhatWentWrong() async throws {
        let runtime = makeRuntime()
        try saveKey(for: .claude)
        runtime.setOn(true)

        var answer = await runtime.check(AIConfig())
        XCTAssertEqual(answer, .cantReach, "no provider")
        answer = await runtime.check(AIConfig(provider: "other", otherAddress: "10.0.0.5"))
        XCTAssertEqual(answer, .cantReach, "an address Helm won't send to")
        answer = await runtime.check(AIConfig(provider: "gemini"))
        XCTAssertEqual(answer, .noKey)
        XCTAssertEqual(factory.built.count, 0, "nothing is built to find that out")

        let expected: [(AgentFailure, AgentConnection)] = [
            (.wrongKey, .wrongKey), (.keyDenied, .keyDenied), (.noKey, .noKey), (.notRunning, .notRunning), (.unreachable, .cantReach),
            (.timedOut, .cantReach), (.rateLimited, .cantReach), (.overloaded, .cantReach), (.unreadable, .cantReach),
            (.outOfCredit, .cantReach), (.badRequest, .cantReach)
        ]
        for (failure, connection) in expected {
            factory.listed = .failure(failure)
            answer = await runtime.check(AIConfig(provider: "claude"))
            XCTAssertEqual(answer, connection, failure.rawValue)
        }
        factory.listed = .success([])
        answer = await runtime.check(AIConfig(provider: "ollama"))
        XCTAssertEqual(answer, .noModels)
        // Every client made for a check was shut down.
        XCTAssertTrue(factory.built.allSatisfy { $0.shutdowns == 1 })
    }

    func testACheckNoticesAKeySavedSinceTheStateWasLastWorkedOut() async throws {
        let runtime = makeRuntime()
        var seen: [AgentRuntimeState] = []
        let token = runtime.changes.subscribe { seen.append($0) }
        defer { runtime.changes.cancel(token) }
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "claude"))
        XCTAssertEqual(seen, [.notReady])
        try saveKey(for: .claude)
        let answer = await runtime.check(AIConfig(provider: "claude"))
        guard case .connected = answer else { return XCTFail("not connected") }
        XCTAssertEqual(seen.last, .ready(provider: "Claude", destination: "Claude", model: "claude-opus-5-5", isLocal: false))
    }

    // MARK: Models that can't see pictures

    /// A model LM Studio said reads text only gets no pictures; any other, or one it said nothing of, does. The
    /// answer is the chosen model's, for the provider at the address it was listed for.
    func testOnlyAModelItsProviderCalledTextOnlyIsSentNoPictures() throws {
        let runtime = makeRuntime()
        XCTAssertTrue(runtime.modelSeesPictures, "nothing chosen")
        var config = AIConfig(provider: "lmStudio", models: ["lmStudio": "openai/gpt-oss-20b"],
                              textOnlyModels: ["lmStudio|127.0.0.1:1234": ["openai/gpt-oss-20b"]])
        runtime.configure(config)
        XCTAssertFalse(runtime.modelSeesPictures)
        config.models["lmStudio"] = "qwen2.5-vl-7b-instruct"
        runtime.configure(config)
        XCTAssertTrue(runtime.modelSeesPictures)
        // The same name listed by LM Studio at another port says nothing about this one.
        config.models["lmStudio"] = "openai/gpt-oss-20b"
        config.ports["lmStudio"] = 4321
        runtime.configure(config)
        XCTAssertTrue(runtime.modelSeesPictures)
        // A file written before Helm kept this reads as every model seeing pictures.
        let old = try JSONDecoder().decode(AIConfig.self, from: Data(#"{"provider": "lmStudio", "models": {"lmStudio": "x"}}"#.utf8))
        XCTAssertEqual(old.textOnlyModels, [:])
    }

    // MARK: What checks found, for the model menu

    func testEveryCheckTellsWhatTheProviderListedOrThatItDidNot() async throws {
        let runtime = makeRuntime()
        var heard: [(account: String, models: [String]?)] = []
        runtime.checked = { profile, models in heard.append((profile.secretID.account, models?.map(\.id))) }
        // While AI mode is off nothing is asked, so nothing is told.
        _ = await runtime.check(AIConfig(provider: "lmStudio"))
        XCTAssertTrue(heard.isEmpty)
        runtime.setOn(true)
        _ = await runtime.check(AIConfig(provider: "lmStudio"))
        XCTAssertEqual(heard.last?.account, "lmStudio|127.0.0.1:1234")
        XCTAssertEqual(heard.last?.models, ["model-a", "model-b"])
        // A cloud provider with no key is told as having no list, without anything being built.
        _ = await runtime.check(AIConfig(provider: "gemini"))
        XCTAssertEqual(heard.last?.account, "gemini|generativelanguage.googleapis.com:443")
        XCTAssertNil(heard.last?.models)
        // A provider that fails, or lists nothing, has no list either.
        factory.listed = .failure(.notRunning)
        _ = await runtime.check(AIConfig(provider: "ollama", ports: ["ollama": 11500]))
        XCTAssertEqual(heard.last?.account, "ollama|127.0.0.1:11500")
        XCTAssertNil(heard.last?.models)
        factory.listed = .success([])
        _ = await runtime.check(AIConfig(provider: "lmStudio"))
        XCTAssertNil(heard.last?.models)
        // A config with no address says nothing about any provider.
        let count = heard.count
        _ = await runtime.check(AIConfig(provider: "other"))
        XCTAssertEqual(heard.count, count)
    }

    func testAProviderOnThisMacIsListedAgainWithoutTouchingTheClientInUse() async throws {
        let runtime = makeRuntime()
        var heard: [String: [String]?] = [:]
        runtime.checked = { profile, models in heard.updateValue(models?.map(\.id), forKey: profile.secretID.account) }
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "lmStudio", models: ["lmStudio": "model-a"]))
        guard case .success(let inUse) = runtime.client() else { return XCTFail("no client") }
        // The provider in use, asked again: a client of its own, shut down afterwards, and the one in use stays.
        factory.listed = .success([AgentModelInfo(id: "model-c")].compactMap { $0 })
        let answer = await runtime.relistLocal(AIConfig(provider: "lmStudio", models: ["lmStudio": "model-a"]))
        XCTAssertEqual(answer, .connected([AgentModelInfo(id: "model-c")].compactMap { $0 }))
        XCTAssertEqual(heard["lmStudio|127.0.0.1:1234"], ["model-c"])
        await runtime.settle()
        XCTAssertEqual(factory.built.count, 2)
        XCTAssertEqual(factory.built[1].shutdowns, 1)
        XCTAssertEqual(factory.built[0].shutdowns, 0, "the client in use is left alone")
        guard case .success(let still) = runtime.client() else { return XCTFail("no client") }
        XCTAssertTrue((still as AnyObject) === (inUse as AnyObject))
        // Ollama, not running: told as having no list.
        factory.listed = .failure(.notRunning)
        _ = await runtime.relistLocal(AIConfig(provider: "ollama"))
        XCTAssertEqual(heard["ollama|127.0.0.1:11434"], .some(nil))
        // A cloud provider is never asked this way, even with its key saved, and neither is anything while AI mode is off.
        try saveKey(for: .claude)
        let built = factory.built.count
        let cloud = await runtime.relistLocal(AIConfig(provider: "claude"))
        XCTAssertEqual(cloud, .off)
        runtime.setOn(false)
        let off = await runtime.relistLocal(AIConfig(provider: "lmStudio"))
        XCTAssertEqual(off, .off)
        XCTAssertEqual(factory.built.count, built, "nothing more was built")
        XCTAssertFalse(heard.keys.contains("claude|api.anthropic.com:443"))
    }

    func testAScriptedRuntimeListsAgainFromItsScript() async throws {
        let runtime = makeRuntime(scripted: ScriptedModelClient(), countsSessions: false)
        var heard: [String: [String]] = [:]
        runtime.checked = { profile, models in heard[profile.secretID.account] = models?.map(\.id) }
        runtime.setOn(true)
        let answer = await runtime.relistLocal(AIConfig(provider: "lmStudio"))
        XCTAssertEqual(answer, .connected([AgentModelInfo(id: "scripted-1")].compactMap { $0 }))
        XCTAssertEqual(heard["lmStudio|127.0.0.1:1234"], ["scripted-1"])
        XCTAssertEqual(runtime.clientBuildCount, 0)
    }

    // MARK: Scripted

    func testAScriptedRuntimeIsReadyAsSoonAsAIModeIsOn() async {
        let scripted = ScriptedModelClient()
        let runtime = makeRuntime(scripted: scripted)
        XCTAssertEqual(runtime.state, .off)
        expectFailure(runtime.client(), .off)
        XCTAssertTrue(runtime.scriptedClientForTesting === scripted)

        // An empty config and an empty key store.
        runtime.setOn(true)
        XCTAssertEqual(runtime.state, .ready(provider: "Claude", destination: "Claude", model: "scripted-1", isLocal: false))
        guard case .success(let client) = runtime.client() else { return XCTFail("no client") }
        XCTAssertTrue((client as AnyObject) === scripted)
        XCTAssertNotNil(runtime.makeSession())

        // Whatever the config says, the scripted client is the one that answers, and no live client is built.
        runtime.configure(AIConfig(provider: "openAI", openAIUsesKey: true))
        XCTAssertEqual(runtime.state, .ready(provider: "Claude", destination: "Claude", model: "gpt-6-astra", isLocal: false))
        runtime.configure(AIConfig(provider: "other", otherAddress: "10.0.0.5"))
        guard case .ready = runtime.state else { return XCTFail("not ready") }
        guard case .success(let again) = runtime.client() else { return XCTFail("no client") }
        XCTAssertTrue((again as AnyObject) === scripted)
        var answer = await runtime.check(AIConfig(provider: "gemini"))
        XCTAssertEqual(answer, .connected([AgentModelInfo(id: "scripted-1")].compactMap { $0 }))
        scripted.modelsFailure = .notRunning
        answer = await runtime.check(AIConfig(provider: "ollama"))
        XCTAssertEqual(answer, .notRunning)
        XCTAssertEqual(runtime.clientBuildCount, 0)
        XCTAssertEqual(factory.built.count, 0)

        runtime.setOn(false)
        XCTAssertEqual(runtime.state, .off)
        expectFailure(runtime.client(), .off)
    }

    func testAScriptedRuntimeStartsSessionsOverWhenTheProviderChanges() async throws {
        let runtime = makeRuntime(scripted: ScriptedModelClient(providerName: "Ollama", destination: "Ollama on this Mac", isLocal: true))
        runtime.setOn(true)
        XCTAssertEqual(runtime.state, .ready(provider: "Ollama", destination: "Ollama on this Mac", model: "scripted-1", isLocal: true))
        runtime.configure(AIConfig(provider: "claude"))
        let session = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        runtime.configure(AIConfig(provider: "openAI", openAIUsesKey: true))
        await runtime.settle()
        XCTAssertEqual(session.asked, ["startOver"])
    }

    // MARK: Sessions

    func testASessionsPartsReachTheRuntime() async throws {
        let scripted = ScriptedModelClient()
        let runtime = makeRuntime(scripted: scripted)
        runtime.setOn(true)
        let session = try XCTUnwrap(runtime.makeSession() as? CountingConversation)
        XCTAssertEqual(session.parts.home, "/home/helm")
        XCTAssertEqual(session.parts.supportFolder, "/home/helm/Library/Application Support/Helm")
        guard case .success(let client) = await session.parts.client() else { return XCTFail("no client") }
        XCTAssertTrue((client as AnyObject) === scripted)

        // What a fixture run sets on the runtime is what a session reads at its next listing.
        XCTAssertNil(session.parts.listSecondsOverride())
        runtime.listSecondsOverrideForTesting = 0.5
        XCTAssertEqual(runtime.listSecondsOverrideForTesting, 0.5)
        XCTAssertEqual(session.parts.listSecondsOverride(), 0.5)
        runtime.listSecondsOverrideForTesting = nil
        XCTAssertNil(session.parts.listSecondsOverride())

        runtime.setOn(false)
        let late = await session.parts.client()
        expectFailure(late, .off)
    }

    func testWithNoSessionFactoryAStandInIsMade() {
        let runtime = makeRuntime(scripted: ScriptedModelClient(), countsSessions: false)
        XCTAssertNil(runtime.makeSession(), "nothing while off")
        runtime.setOn(true)
        XCTAssertTrue(runtime.makeSession() is StandInConversation)
    }

    func testSessionsAreHeldWeakly() async throws {
        let runtime = makeRuntime(scripted: ScriptedModelClient(), countsSessions: false)
        runtime.setOn(true)
        weak var gone: StandInConversation?
        do {
            let session = try XCTUnwrap(runtime.makeSession() as? StandInConversation)
            gone = session
        }
        XCTAssertNil(gone, "the runtime doesn't keep a session alive")
        // A change that reaches every session finds none, and nothing goes wrong.
        runtime.configure(AIConfig(provider: "claude"))
        runtime.setOn(false)
        await runtime.settle()
    }

    func testAStandInSessionHearsThatItWasStartedOver() async throws {
        let runtime = makeRuntime(scripted: ScriptedModelClient(), countsSessions: false)
        runtime.setOn(true)
        runtime.configure(AIConfig(provider: "claude"))
        let session = try XCTUnwrap(runtime.makeSession())
        runtime.configure(AIConfig(provider: "gemini"))
        await runtime.settle()
        var heard: [AgentNotice] = []
        for await notice in session.notices {
            heard.append(notice)
            break
        }
        XCTAssertEqual(heard, [.startedOver])
    }
}
