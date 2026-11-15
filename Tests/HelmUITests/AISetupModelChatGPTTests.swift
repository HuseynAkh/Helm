#if os(macOS)
import AppKit
import Security
import XCTest
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmPersistence
import HelmTestKit
@testable import HelmUI

/// Settings › AI and the AI mode screen with OpenAI reached by a ChatGPT sign-in, each provider's help, Refresh
/// Models, and a connected provider that is always ready. OpenAI's sign-in is played in the test process and the
/// browser is a recorder: nothing reaches OpenAI, a browser or the keychain.
@MainActor final class AISetupModelChatGPTTests: XCTestCase {
    private final class Memory: KeyValueStoring {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any, forKey key: String) { values[key] = value }
        func register(defaults: [String: Any]) { values.merge(defaults) { old, _ in old } }
    }

    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)

    private struct Rig {
        let model: AISetupModel
        let providers: AISetupFakeProviders
        let store: MemorySecretStore
        let services: AgentServices
        let openAI: AISetupStubOpenAI
    }

    private func rig(on: Bool = true, config: AIConfig = AIConfig(), signsIn: Bool = true) -> Rig {
        let store = MemorySecretStore()
        let providers = AISetupFakeProviders()
        let openAI = AISetupStubOpenAI()
        let disk = MemoryAgentDisk(home: home.path)
        var makeSignIn: (@Sendable (any AgentSecretStoring) -> AgentChatGPTSignIn)?
        if signsIn {
            makeSignIn = { secrets in AgentChatGPTSignIn(store: secrets, transport: openAI, makeListener: { openAI }) }
        }
        let parts = AgentRuntimeParts(secrets: store, disk: disk, home: home.path, supportFolder: "/home/helm/.support",
                                      clock: FakeClock(), buildStamp: "", makeClient: providers.makeClient, makeSignIn: makeSignIn)
        let aiConfig = AIConfigStore()
        aiConfig.update { $0 = config }
        let services = AgentServices(runtime: AgentRuntime(parts: parts), config: aiConfig, secrets: store, disk: disk,
                                     storage: MemoryStorageFactsReader(home: home), connector: MemoryServerConnector(),
                                     openInBrowser: { openAI.open($0) })
        // The app hands every saved change to the runtime (AppController.followAIMode); so does this rig.
        let runtime = services.runtime
        runtime.configure(aiConfig.config)
        _ = aiConfig.changes.subscribe { runtime.configure($0) }
        let settings = SettingsStore(storage: Memory())
        if on { settings.set(.bool(true), for: .aiModeEnabled) }
        return Rig(model: AISetupModel(settings: settings, services: services), providers: providers, store: store,
                   services: services, openAI: openAI)
    }

    private func signIn(_ rig: Rig) async {
        rig.model.continueWithChatGPT()
        await rig.model.signInTask?.value
        await rig.model.settle()
    }

    // MARK: ChatGPT

    func testOpenAIStartsOnTheChatGPTSignInWithAKeyAsTheQuietOtherWay() {
        let rig = rig()
        rig.model.choose(.openAI)
        XCTAssertTrue(rig.model.usesChatGPT)
        XCTAssertFalse(rig.model.showsKeyField, "no key to paste")
        XCTAssertEqual(rig.model.connection, .noKey)
        XCTAssertNil(rig.model.stateLine, "the button is the call to act, not a No key line")
        XCTAssertEqual(rig.model.consentLine, "Sends your requests and file names to OpenAI, never file contents.")
        XCTAssertEqual(AIModeScreen.parts(for: rig.model), [.titleRow, .sentence, .provider, .chatGPT, .state, .consent, .done])
        XCTAssertEqual(rig.providers.asked, [], "nothing is asked before the person signs in")

        rig.model.press(AgentText.useKeyInstead)
        XCTAssertTrue(rig.services.config.config.openAIUsesKey)
        XCTAssertFalse(rig.model.usesChatGPT)
        XCTAssertTrue(rig.model.showsKeyField)
        XCTAssertEqual(rig.model.stateLine, AgentText.stateNoKey)
        XCTAssertEqual(AIModeScreen.parts(for: rig.model),
                       [.titleRow, .sentence, .provider, .key, .useChatGPT, .state, .consent, .done])
        rig.model.press(AgentText.useChatGPTInstead)
        XCTAssertFalse(rig.services.config.config.openAIUsesKey)
        XCTAssertTrue(rig.model.usesChatGPT)
    }

    func testContinueWithChatGPTSignsInThroughTheBrowserAndChecksTheConnection() async throws {
        let rig = rig()
        rig.providers.answers["openAI"] = .models(["gpt-6.1-sol", "gpt-6-astra"])
        rig.model.choose(.openAI)
        rig.model.press(AgentText.continueWithChatGPT)
        XCTAssertEqual(rig.model.signIn, .waiting)
        XCTAssertTrue(rig.model.linesForTesting.contains(AgentText.signInWaiting))
        await rig.model.signInTask?.value
        await rig.model.settle()

        let opened = try XCTUnwrap(rig.openAI.opened.first)
        XCTAssertEqual(opened.host, "auth.openai.com", "the browser opened OpenAI's sign-in")
        XCTAssertEqual(rig.model.signIn, .idle)
        XCTAssertTrue(rig.model.isSignedIn)
        XCTAssertEqual(rig.model.accountLine, "Signed in as person@example.com.")
        XCTAssertTrue(rig.model.linesForTesting.contains("Signed in as person@example.com."))
        XCTAssertEqual(rig.model.connection, .connected(2))
        XCTAssertEqual(rig.model.model, "gpt-6-astra", "the plan offers OpenAI's first choice, so it stays")
        guard case .ready(let name, let destination, _, _) = rig.services.runtime.state else { return XCTFail("not ready") }
        XCTAssertEqual(name, "ChatGPT")
        XCTAssertEqual(destination, "OpenAI")
        XCTAssertEqual(rig.store.accounts, [], "no key was saved")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(rig.services.config.config), as: UTF8.self).contains("oaiapp"),
                       "ai.json holds neither the client nor a token")
    }

    func testAPlanThatDoesntOfferOpenAIsFirstChoiceRunsItsOwnFirstModel() async {
        let rig = rig()
        rig.providers.answers["openAI"] = .models(["gpt-6.1-sol", "gpt-6.1-mini"])
        rig.model.choose(.openAI)
        await signIn(rig)
        XCTAssertEqual(rig.model.connection, .connected(2))
        XCTAssertEqual(rig.model.model, "gpt-6.1-sol")
        XCTAssertEqual(rig.services.config.config.models["openAI"], "gpt-6.1-sol")
        guard case .ready(_, _, let model, _) = rig.services.runtime.state else { return XCTFail("not ready") }
        XCTAssertEqual(model, "gpt-6.1-sol")
    }

    func testASignInTheBrowserRefusedSaysSoAndTheNextAsksForConsent() async {
        let rig = rig()
        rig.openAI.refuses = true
        rig.model.choose(.openAI)
        await signIn(rig)
        XCTAssertEqual(rig.model.signIn, .failed(AgentText.signInDeclined))
        XCTAssertTrue(rig.model.linesForTesting.contains(AgentText.signInDeclined))
        XCTAssertFalse(rig.model.isSignedIn)
        XCTAssertEqual(rig.model.connection, .noKey)
        rig.openAI.refuses = false
        await signIn(rig)
        XCTAssertEqual(rig.openAI.authorizeParameters["prompt"], "consent")
        XCTAssertTrue(rig.model.isSignedIn)
    }

    func testABrowserThatWontOpenAndARunThatCantSignInHaveTheirLines() async {
        let closed = rig()
        closed.openAI.opens = false
        closed.model.choose(.openAI)
        await signIn(closed)
        XCTAssertEqual(closed.model.signIn, .failed(AgentText.signInNoBrowser))

        let fixture = rig(signsIn: false)
        fixture.model.choose(.openAI)
        fixture.model.continueWithChatGPT()
        XCTAssertEqual(fixture.model.signIn, .failed(AgentText.signInUnavailable))
        XCTAssertTrue(fixture.openAI.opened.isEmpty, "a run that can't sign in opens nothing")

        let off = rig(on: false)
        off.model.choose(.openAI)
        off.model.continueWithChatGPT()
        XCTAssertEqual(off.model.signIn, .idle, "nothing starts while AI mode is off")
        XCTAssertTrue(off.openAI.opened.isEmpty)
    }

    func testCancelStopsASignInThatIsWaitingForTheBrowser() async {
        let rig = rig()
        rig.openAI.waits = true
        rig.model.choose(.openAI)
        rig.model.continueWithChatGPT()
        XCTAssertEqual(rig.model.signIn, .waiting)
        for _ in 0..<200 where rig.openAI.opened.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        rig.model.press(AgentText.cancel)
        await rig.model.signInTask?.value
        XCTAssertEqual(rig.model.signIn, .idle, "a stopped sign-in needs no line")
        XCTAssertFalse(rig.model.isSignedIn)
    }

    func testRemoveSignsOutAndTheContinueButtonComesBack() async {
        let rig = rig()
        rig.providers.answers["openAI"] = .models(["gpt-6-astra"])
        rig.model.choose(.openAI)
        await signIn(rig)
        XCTAssertTrue(rig.model.isSignedIn)
        rig.model.press(AgentText.removeSignIn)
        await rig.model.signOutTask?.value
        XCTAssertFalse(rig.model.isSignedIn)
        XCTAssertNil(rig.model.accountLine)
        XCTAssertEqual(rig.model.connection, .noKey)
        XCTAssertEqual(rig.model.models, [])
        XCTAssertNil(rig.model.signOutLine, "OpenAI confirmed the revocation")
        XCTAssertEqual(rig.services.runtime.state, .notReady)
        XCTAssertTrue(rig.store.hasSignIn(.chatGPTRegistration), "the registration stays for the next sign-in")

        // A revocation OpenAI doesn't confirm says where to finish it.
        await signIn(rig)
        rig.openAI.revokes = false
        rig.model.removeSignIn()
        await rig.model.signOutTask?.value
        XCTAssertEqual(rig.model.signOutLine, AgentText.signOutUnconfirmed)
        XCTAssertFalse(rig.model.isSignedIn)
    }

    func testThePlansLimitAndAPlanThatDoesntCoverHelmHaveTheirStateLines() async {
        let rig = rig()
        rig.model.choose(.openAI)
        await signIn(rig)
        rig.providers.answers["openAI"] = .failure(.outOfCredit)
        rig.model.tryAgain()
        await rig.model.settle()
        XCTAssertEqual(rig.model.connection, .planLimit)
        XCTAssertEqual(rig.model.stateLine, AgentText.planLimit)
        rig.providers.answers["openAI"] = .failure(.noSuchModel)
        rig.model.refreshModels()
        await rig.model.settle()
        XCTAssertEqual(rig.model.connectionForTesting, "planNotCovered")
        XCTAssertEqual(rig.model.stateLine, AgentText.statePlanNotCovered)
    }

    func testDoneWithoutASignInSaysWhatIsMissing() async {
        let rig = rig()
        rig.model.choose(.openAI)
        let closes = await rig.model.done(pendingKey: nil)
        XCTAssertFalse(closes)
        XCTAssertEqual(rig.model.stateLine, AgentText.signInFirst)
    }

    // MARK: Help for each provider

    func testEachProviderHasItsLineAndItsPageAndThePageOpensInTheBrowser() {
        let rig = rig()
        let pages: [(AgentProviderID, String, String?)] = [
            (.claude, AgentText.helpClaude, "https://platform.claude.com/docs/en/manage-claude/authentication#api-keys"),
            (.openAI, AgentText.helpChatGPT,
             "https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites"),
            (.gemini, AgentText.helpGemini, "https://aistudio.google.com/docs/api-key"),
            (.grok, AgentText.helpGrok, "https://docs.x.ai/docs/quickstart"),
            (.ollama, AgentText.helpOllama, "https://docs.ollama.com/quickstart"),
            (.lmStudio, AgentText.helpLMStudio, "https://lmstudio.ai/docs/developer/core/server"),
            (.other, AgentText.helpOther, nil)
        ]
        for (provider, line, page) in pages {
            rig.model.choose(provider)
            XCTAssertEqual(rig.model.helpLine, line, provider.rawValue)
            XCTAssertEqual(rig.model.helpPage?.absoluteString, page, provider.rawValue)
            let before = rig.openAI.opened.count
            rig.model.press(AgentText.howToConnect)
            XCTAssertEqual(rig.openAI.opened.count, before + (page == nil ? 0 : 1), provider.rawValue)
            if let page { XCTAssertEqual(rig.openAI.opened.last?.absoluteString, page) }
        }
        XCTAssertTrue(AgentText.helpClaude.contains("Anthropic requires an API key for apps like Helm"))
        rig.model.choose(.openAI)
        rig.model.useKey(true)
        XCTAssertEqual(rig.model.helpLine, AgentText.helpOpenAIKey)
        XCTAssertEqual(rig.model.helpPage?.absoluteString, "https://developers.openai.com/api/docs/quickstart")
        rig.model.openManageUsage()
        XCTAssertEqual(rig.openAI.opened.last?.absoluteString, "https://chatgpt.com/settings/usage")
        // Each line is one short sentence.
        for (_, line, _) in pages {
            XCTAssertFalse([". ", "? ", "! "].contains { line.contains($0) }, line)
            XCTAssertTrue(line.hasSuffix("."), line)
        }
    }

    // MARK: LM Studio: the list, Refresh Models and a ready model

    func testAConnectedLMStudioWithNoSavedModelMakesTheRuntimeReadyWithTheFirstModel() async {
        let rig = rig()
        rig.providers.answers["lmStudio"] = .models(["qwen2.5-7b-instruct", "lmstudio-community/llama-3.2-3b-instruct"])
        XCTAssertNil(rig.services.config.config.models["lmStudio"])
        rig.model.choose(.lmStudio)
        await rig.model.settle()
        XCTAssertEqual(rig.model.connection, .connected(2))
        XCTAssertEqual(rig.model.modelChoices, ["qwen2.5-7b-instruct", "lmstudio-community/llama-3.2-3b-instruct"],
                       "the menu lists what LM Studio's server reports")
        XCTAssertEqual(rig.services.config.config.models["lmStudio"], "qwen2.5-7b-instruct")
        XCTAssertEqual(rig.services.runtime.state,
                       .ready(provider: "LM Studio", destination: "LM Studio on this Mac", model: "qwen2.5-7b-instruct", isLocal: true),
                       "Connected means AI search and the panel can run")
    }

    func testAModelLMStudioNoLongerListsGivesWayToOneItDoes() async {
        let rig = rig(config: AIConfig(provider: "lmStudio", models: ["lmStudio": "unloaded-model"]))
        rig.providers.answers["lmStudio"] = .models(["qwen2.5-7b-instruct"])
        rig.model.choose(.lmStudio)
        await rig.model.settle()
        XCTAssertEqual(rig.model.model, "qwen2.5-7b-instruct")
        XCTAssertEqual(rig.model.modelChoices, ["qwen2.5-7b-instruct"])
        guard case .ready(_, _, let model, _) = rig.services.runtime.state else { return XCTFail("not ready") }
        XCTAssertEqual(model, "qwen2.5-7b-instruct")
        // A cloud provider keeps the model the person picked, listed or not.
        let cloud = self.rig(config: AIConfig(provider: "claude", models: ["claude": "claude-haiku-5-5"]))
        try? cloud.store.save(XCTUnwrap(AgentSecret(pasted: "test-key-0123456789-abcdef")),
                              for: AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443))
        cloud.providers.answers["claude"] = .models(["claude-opus-5-5"])
        cloud.model.choose(.claude)
        await cloud.model.settle()
        XCTAssertEqual(cloud.model.model, "claude-haiku-5-5")
    }

    func testAnEmptyListIsNotConnectedAndRefreshModelsAsksAgain() async {
        let rig = rig()
        rig.providers.answers["lmStudio"] = .models([])
        rig.model.choose(.lmStudio)
        await rig.model.settle()
        XCTAssertEqual(rig.model.connection, .noModels)
        XCTAssertNotEqual(rig.model.stateLine, AgentText.stateConnected)
        XCTAssertTrue(rig.model.linesForTesting.contains("LM Studio has no models yet."))
        XCTAssertEqual(rig.services.runtime.state, .notReady, "nothing can run yet")
        XCTAssertTrue(rig.model.offersTryAgain, "once a model is loaded, Try Again finds it")
        XCTAssertTrue(rig.model.canRefreshModels)

        // A model was loaded in LM Studio: Refresh Models finds it.
        rig.providers.answers["lmStudio"] = .models(["qwen2.5-7b-instruct"])
        rig.model.press(AgentText.refreshModels)
        await rig.model.settle()
        XCTAssertEqual(rig.model.connection, .connected(1))
        XCTAssertEqual(rig.model.modelChoices, ["qwen2.5-7b-instruct"])
        // And another one: the list follows the server.
        rig.providers.answers["lmStudio"] = .models(["qwen2.5-7b-instruct", "gemma-3-4b"])
        rig.model.refreshModels()
        await rig.model.settle()
        XCTAssertEqual(rig.model.modelChoices, ["qwen2.5-7b-instruct", "gemma-3-4b"])
        XCTAssertEqual(rig.model.model, "qwen2.5-7b-instruct", "the chosen model stays while it is listed")
        XCTAssertEqual(rig.providers.asked, ["lmStudio", "lmStudio", "lmStudio"])
    }

    func testRefreshModelsAsksNothingWhileOffOrWithoutWhatTheProviderNeeds() async {
        let off = rig(on: false)
        off.model.choose(.lmStudio)
        XCTAssertFalse(off.model.canRefreshModels)
        off.model.refreshModels()
        await off.model.settle()
        XCTAssertEqual(off.providers.asked, [])
        let keyless = rig()
        keyless.model.choose(.gemini)
        XCTAssertFalse(keyless.model.canRefreshModels, "a cloud provider with no key isn't asked")
        keyless.model.refreshModels()
        await keyless.model.settle()
        XCTAssertEqual(keyless.providers.asked, [])
    }

    func testAPlanModelIsShownByItsName() async {
        let rig = rig()
        rig.providers.labels = ["gpt-6.1-sol": "GPT-6.1 Sol"]
        rig.providers.answers["openAI"] = .models(["gpt-6.1-sol"])
        rig.model.choose(.openAI)
        await signIn(rig)
        XCTAssertEqual(rig.model.modelTitle("gpt-6.1-sol"), "GPT-6.1 Sol")
        XCTAssertEqual(rig.model.modelTitle("unlisted"), "unlisted")
    }
}

/// OpenAI's sign-in in the test process: the browser, which records each page it is asked to open and comes back to the
/// callback with this sign-in's state, the listener that hands that callback over, and the sign-in host with an RSA
/// key made in memory for the test. Nothing leaves the process.
final class AISetupStubOpenAI: AgentSignInTransport, AgentCallbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private let privateKey: SecKey
    private let publicKey: SecKey
    var opens = true
    var refuses = false
    var revokes = true
    /// The browser never comes back, until the sign-in is stopped.
    var waits = false
    private var stopped = false
    private(set) var opened: [URL] = []

    init() {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
                                         kSecAttrIsPermanent as String: false]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil), let published = SecKeyCopyPublicKey(key) else {
            preconditionFailure("a test key could be made")
        }
        privateKey = key; publicKey = published
    }

    @MainActor func open(_ address: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        opened.append(address)
        return opens
    }

    var authorizeParameters: [String: String] {
        lock.lock(); let last = opened.last; lock.unlock()
        let items = last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: The listener

    func start() throws -> Int {
        lock.lock(); stopped = false; lock.unlock()
        return 54321
    }

    func callback(path: String, timeout: Double,
                  accepts: @escaping @Sendable ([String: String]) -> Bool) async throws -> [String: String] {
        while waits {
            lock.lock(); let done = stopped; lock.unlock()
            if done { throw AgentSignInFailure.cancelled }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let page = authorizeParameters
        var query = ["state": page["state"] ?? ""]
        if refuses {
            query["error"] = "access_denied"
        } else {
            query["code"] = "test-code"
            if page["client_id"] == "dynamic_agent_client" { query["client_id"] = "oaiapp_test_client" }
        }
        guard accepts(query) else { throw AgentSignInFailure.timedOut }
        return query
    }

    func stop() { lock.lock(); stopped = true; lock.unlock() }

    // MARK: The sign-in host

    func post(_ route: AgentSignInRoute, form: [(String, String)]) async throws -> AgentHTTPReply {
        switch route {
        case .token:
            let page = authorizeParameters
            let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_test_client", "sub": "user-test-subject",
                                         "exp": Int(Date().timeIntervalSince1970) + 3_600, "iat": Int(Date().timeIntervalSince1970),
                                         "nonce": page["nonce"] ?? "", "email": "person@example.com"]
            let reply: [String: Any] = ["access_token": "test-access-token-0001", "refresh_token": "test-refresh-token-0001",
                                        "id_token": token(claims), "token_type": "Bearer", "expires_in": 3_600,
                                        "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"]
            return AgentHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: reply))
        case .revoke:
            return AgentHTTPReply(status: revokes ? 200 : 503, body: Data())
        case .keys, .discovery:
            return AgentHTTPReply(status: 405, body: Data())
        }
    }

    func get(_ route: AgentSignInRoute) async throws -> AgentHTTPReply {
        switch route {
        case .keys:
            let external = SecKeyCopyExternalRepresentation(publicKey, nil).map { $0 as Data } ?? Data()
            let (modulus, exponent) = Self.integers(external)
            let list: [String: Any] = ["keys": [["kty": "RSA", "kid": "test-key-1", "use": "sig", "alg": "RS256",
                                                 "n": Self.base64URL(modulus), "e": Self.base64URL(exponent)]]]
            return AgentHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: list))
        case .discovery:
            let document = ["revocation_endpoint": "https://auth.openai.com/oauth/revoke"]
            return AgentHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: document))
        case .token, .revoke:
            return AgentHTTPReply(status: 405, body: Data())
        }
    }

    func shutdown() async {}

    private func token(_ claims: [String: Any]) -> String {
        let header: [String: Any] = ["alg": "RS256", "kid": "test-key-1", "typ": "JWT"]
        let encode = { (object: [String: Any]) in
            Self.base64URL((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        let input = encode(header) + "." + encode(claims)
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)
        return input + "." + Self.base64URL((signature as Data?) ?? Data())
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The modulus and exponent of a PKCS #1 RSA public key.
    private static func integers(_ der: Data) -> (Data, Data) {
        let bytes = Array(der)
        var index = 1
        func length() -> Int {
            let first = Int(bytes[index]); index += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7F) { value = value << 8 | Int(bytes[index]); index += 1 }
            return value
        }
        _ = length()
        func integer() -> Data {
            index += 1
            let count = length()
            defer { index += count }
            return Data(bytes[index..<index + count])
        }
        return (integer(), integer())
    }
}
#endif
