#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmPersistence
import HelmTestKit
@testable import HelmUI

/// Settings › AI and the AI mode screen's model, against keys kept in memory and a fake client for each provider
/// that answers from a table. Nothing here reaches a provider or the keychain.
@MainActor final class AISetupModelTests: XCTestCase {
    private final class Memory: KeyValueStoring {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any, forKey key: String) { values[key] = value }
        func register(defaults: [String: Any]) { values.merge(defaults) { old, _ in old } }
    }

    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    /// Made up for these tests; never a real key.
    private let testKey = "test-key-0123456789-abcdef"

    private func rig(store: (any AgentSecretStoring)? = nil, config: AIConfig = AIConfig(), on: Bool = false)
        -> (AISetupModel, AISetupFakeProviders, MemorySecretStore, AgentServices, SettingsStore) {
        let memory = MemorySecretStore()
        let secrets = store ?? memory
        let providers = AISetupFakeProviders()
        let disk = MemoryAgentDisk(home: home.path)
        let parts = AgentRuntimeParts(secrets: secrets, disk: disk, home: home.path, supportFolder: "/home/helm/.support",
                                      clock: FakeClock(), buildStamp: "", makeClient: providers.makeClient)
        let aiConfig = AIConfigStore()
        aiConfig.update { $0 = config }
        let services = AgentServices(runtime: AgentRuntime(parts: parts), config: aiConfig, secrets: secrets, disk: disk,
                                     storage: MemoryStorageFactsReader(home: home), connector: MemoryServerConnector())
        let settings = SettingsStore(storage: Memory())
        if on { settings.set(.bool(true), for: .aiModeEnabled) }
        return (AISetupModel(settings: settings, services: services), providers, memory, services, settings)
    }

    // MARK: Starting out

    func testItStartsOnClaudeAndAsksNothing() async {
        let (model, providers, _, services, _) = rig()
        XCTAssertEqual(model.provider, .claude)
        XCTAssertFalse(model.isOn)
        XCTAssertEqual(model.connection, AISetupModel.Connection.none)
        XCTAssertEqual(model.model, "claude-opus-5-5", "Claude's own first choice")
        model.setOn(true)
        XCTAssertEqual(model.connection, .noKey, "no key is known without asking anyone")
        await model.settle()
        XCTAssertEqual(providers.asked, [], "turning AI mode on asks nothing")
        XCTAssertEqual(services.runtime.clientBuildCount, 0)
    }

    func testTheSwitchWritesTheSetting() {
        let (model, _, _, services, settings) = rig()
        model.setOn(true)
        XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertTrue(model.isOn)
        XCTAssertTrue(services.runtime.isOn, "the runtime follows the switch")
        model.setOn(false)
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertFalse(services.runtime.isOn)
        // A change made elsewhere, as a script's `setting` does, shows here too.
        settings.set(.bool(true), for: .aiModeEnabled)
        XCTAssertTrue(model.isOn)
        model.press(AgentText.aiTitle)
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled), "the title row is the switch")
    }

    func testTheConsentLineNamesWhereRequestsGo() {
        let (model, _, _, _, _) = rig(on: true)
        XCTAssertEqual(model.consentLine, "Sends your requests and file names to Claude, never file contents.")
        model.choose(.ollama)
        XCTAssertEqual(model.consentLine, "Sends your requests and file names to Ollama on this Mac, never file contents.")
        model.choose(.other)
        XCTAssertEqual(model.consentLine, "Sends your requests and file names to the address you enter, never file contents.",
                       "Other before an address is saved names no provider called Other")
        model.setAddress("models.example.com")
        XCTAssertEqual(model.consentLine, "Sends your requests and file names to models.example.com, never file contents.")
        XCTAssertEqual(model.consentLine, AgentText.consent("models.example.com"))
    }

    // MARK: Keys

    func testEnteringAKeySavesItUnderItsAddressAndChecksIt() async throws {
        let (model, providers, store, services, _) = rig(on: true)
        providers.answers["claude"] = .models(["claude-opus-5-5", "claude-sonnet-5-5"])
        model.enterKey("  \(testKey)\n")
        XCTAssertEqual(store.accounts, ["claude|api.anthropic.com:443"])
        XCTAssertTrue(model.hasSavedKey)
        XCTAssertEqual(services.config.config.provider, "claude", "the provider in use is saved")
        XCTAssertNotNil(services.config.config.keyOwners["claude|api.anthropic.com:443"])
        await model.settle()
        XCTAssertEqual(model.connection, .connected(2))
        XCTAssertEqual(model.models.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(providers.asked, ["claude"])
        // Nothing the model holds keeps the key's text, and ai.json never does.
        XCTAssertFalse(Self.strings(in: model).contains { $0.contains(testKey) })
        XCTAssertFalse(model.linesForTesting.contains { $0.contains(testKey) })
        let saved = String(decoding: try JSONEncoder().encode(services.config.config), as: UTF8.self)
        XCTAssertFalse(saved.contains(testKey))
        XCTAssertTrue(model.linesForTesting.contains(AgentText.keySaved))
    }

    func testAKeyWithAControlCharacterIsRefused() async {
        let (model, providers, store, _, _) = rig(on: true)
        model.enterKey("test-key-01234\u{07}56789")
        model.enterKey("test-key-01234\r\nX-Other: 1")
        await model.settle()
        XCTAssertEqual(store.accounts, [], "nothing was saved")
        XCTAssertEqual(providers.asked, [], "nothing was asked")
        XCTAssertNotEqual(model.connection, .checking)
        XCTAssertFalse(model.hasSavedKey)
    }

    func testRemoveKeyDeletesIt() async {
        let (model, providers, store, services, _) = rig(on: true)
        providers.answers["claude"] = .models(["claude-opus-5-5"])
        model.enterKey(testKey)
        await model.settle()
        model.press(AgentText.removeKey)
        XCTAssertEqual(store.accounts, [])
        XCTAssertFalse(model.hasSavedKey)
        XCTAssertNil(services.config.config.keyOwners["claude|api.anthropic.com:443"])
        XCTAssertEqual(model.connection, .noKey)
        XCTAssertEqual(model.models, [])
    }

    func testAWrongKeyAnUnreachableProviderAndARefusedKeychainEachShowTheirState() async {
        let (model, providers, store, _, _) = rig(on: true)
        providers.answers["claude"] = .failure(.wrongKey)
        model.enterKey(testKey)
        await model.settle()
        XCTAssertEqual(model.connection, .wrongKey)
        XCTAssertEqual(model.connectionForTesting, "wrongKey")

        providers.answers["claude"] = .failure(.unreachable)
        model.tryAgain()
        await model.settle()
        XCTAssertEqual(model.connection, .cantReach)
        XCTAssertTrue(model.offersTryAgain)
        XCTAssertTrue(model.linesForTesting.contains("Can't reach Claude"))

        // macOS refuses to hand the key over.
        providers.answers["claude"] = .models(["claude-opus-5-5"])
        store.denies = true
        model.press(AgentText.tryAgain)
        await model.settle()
        XCTAssertEqual(model.connection, .keyDenied)
        XCTAssertTrue(model.linesForTesting.contains(AgentText.failKeyDenied))
        store.denies = false
        model.press(AgentText.tryAgain)
        await model.settle()
        XCTAssertEqual(model.connection, .connected(1))
    }

    func testAKeychainThatRefusesToSaveShowsKeyDenied() async {
        let refusing = AISetupRefusingStore()
        let (model, providers, _, _, _) = rig(store: refusing, on: true)
        model.enterKey(testKey)
        await model.settle()
        XCTAssertEqual(model.connection, .keyDenied)
        XCTAssertFalse(model.hasSavedKey)
        XCTAssertEqual(providers.asked, [], "nothing is asked with a key that wasn't saved")
    }

    func testAKeyIsFoundOnlyForTheProviderItWasSavedFor() async {
        let (model, providers, store, _, _) = rig(on: true)
        providers.answers["claude"] = .models(["claude-opus-5-5"])
        model.enterKey(testKey)
        await model.settle()
        model.choose(.openAI)
        XCTAssertFalse(model.hasSavedKey)
        XCTAssertEqual(model.connection, .noKey)
        await model.settle()
        XCTAssertEqual(providers.asked, ["claude"], "a provider with no key isn't asked")
        // Back on Claude, whose key is saved: it is checked at once.
        model.choose(.claude)
        await model.settle()
        XCTAssertEqual(providers.asked, ["claude", "claude"])
        XCTAssertEqual(model.connection, .connected(1))
        XCTAssertEqual(store.accounts, ["claude|api.anthropic.com:443"])
    }

    // MARK: Local providers

    func testPickingOllamaChecksItAtOnce() async {
        let (model, providers, _, services, _) = rig(on: true)
        providers.answers["ollama"] = .models(["llama4:8b", "qwen3:14b"])
        model.choose(.ollama)
        XCTAssertEqual(model.connection, .checking)
        await model.settle()
        XCTAssertEqual(providers.asked, ["ollama"])
        XCTAssertEqual(model.connection, .connected(2))
        XCTAssertEqual(model.linesForTesting.last, AgentText.stateConnected)
        XCTAssertFalse(model.showsPort)
        XCTAssertEqual(model.model, "llama4:8b", "a local provider runs the first model it lists until another is picked")
        XCTAssertEqual(services.config.config.models["ollama"], "llama4:8b")
        XCTAssertEqual(services.config.config.provider, "ollama")

        providers.answers["ollama"] = .failure(.notRunning)
        model.tryAgain()
        await model.settle()
        XCTAssertEqual(model.connection, .notRunning)
        XCTAssertTrue(model.showsPort, "the port shows beside the not-running state")
        XCTAssertTrue(model.linesForTesting.contains(AgentText.failOllamaNotRunning))
        XCTAssertTrue(model.offersTryAgain)

        providers.answers["lmStudio"] = .failure(.notRunning)
        model.choose(.lmStudio)
        await model.settle()
        XCTAssertTrue(model.linesForTesting.contains(AgentText.failLMStudioNotRunning))
        XCTAssertTrue(model.showsPort)

        providers.answers["lmStudio"] = .models([])
        model.tryAgain()
        await model.settle()
        XCTAssertEqual(model.connection, .noModels)
        XCTAssertFalse(model.showsPort, "the port shows only beside the not-running state")
        XCTAssertTrue(model.linesForTesting.contains("LM Studio has no models yet."))
    }

    func testATypedPortKeepsToTheRange() async {
        let (model, providers, _, services, _) = rig(on: true)
        providers.answers["ollama"] = .failure(.notRunning)
        model.choose(.ollama)
        await model.settle()
        XCTAssertEqual(model.port, 11434)
        model.setPort("80")
        XCTAssertEqual(services.config.config.ports["ollama"], 1024)
        model.setPort("70000")
        XCTAssertEqual(services.config.config.ports["ollama"], 65535)
        model.setPort("11 5x00")
        XCTAssertEqual(services.config.config.ports["ollama"], 11500, "digits only")
        model.setPort("port")
        XCTAssertEqual(services.config.config.ports["ollama"], 11500, "no digits changes nothing")
        XCTAssertEqual(model.port, 11500)
        await model.settle()
        XCTAssertEqual(providers.asked, ["ollama"], "a new port waits for Try Again")
        model.tryAgain()
        await model.settle()
        XCTAssertEqual(providers.ports.last, 11500, "Try Again asks on the new port")
        // A cloud provider has no port.
        model.choose(.claude)
        model.setPort("2000")
        XCTAssertNil(services.config.config.ports["claude"])
    }

    // MARK: Other

    func testOtherRefusesPlainHTTPAnIPAddressAndALocalName() async {
        let (model, providers, _, services, _) = rig(on: true)
        model.choose(.other)
        let refused: [(String, String)] = [
            ("http://models.example.com", AgentText.addressNeedsHTTPS),
            ("https://192.168.1.20", AgentText.addressOtherDevice),
            ("10.0.0.7:8080", AgentText.addressOtherDevice),
            ("studio.local", AgentText.addressOtherDevice),
            ("https://user:secret@models.example.com", AgentText.addressNeedsHTTPS)
        ]
        for (text, line) in refused {
            model.setAddress(text)
            XCTAssertEqual(model.addressProblem, line, text)
            XCTAssertTrue(model.linesForTesting.contains(line), text)
            XCTAssertNil(services.config.config.otherAddress, "\(text) isn't saved")
        }
        await model.settle()
        XCTAssertEqual(providers.asked, [], "a refused address is never asked")
    }

    func testOtherOffersTheModelFieldOnlyWhenItsAddressGivesNoList() async {
        let (model, providers, _, services, _) = rig(on: true)
        model.choose(.other)
        XCTAssertFalse(model.showsModelField, "no address yet")
        providers.answers["other"] = .models(["mistral-large", "qwen3-coder"])
        model.setAddress("https://models.example.com/")
        await model.settle()
        XCTAssertNil(model.addressProblem)
        XCTAssertEqual(services.config.config.otherAddress, "models.example.com")
        XCTAssertEqual(model.connection, .connected(2))
        XCTAssertFalse(model.showsModelField, "the address lists its models")

        providers.answers["other"] = .failure(.badRequest)
        model.setAddress("plain.example.org")
        await model.settle()
        XCTAssertEqual(model.models, [])
        XCTAssertTrue(model.showsModelField, "no list, so the model is typed")
        model.typeModel(" my-model ")
        XCTAssertEqual(services.config.config.models["other"], "my-model")
        XCTAssertEqual(model.model, "my-model")
        model.typeModel("bad model name")
        XCTAssertEqual(services.config.config.models["other"], "my-model", "a name no server could list is refused")

        providers.answers["other"] = .models([])
        model.tryAgain()
        await model.settle()
        XCTAssertEqual(model.connection, .noModels)
        XCTAssertTrue(model.showsModelField)

        // A cloud provider never offers it.
        model.choose(.claude)
        XCTAssertFalse(model.showsModelField)
    }

    func testOtherShowsTheKeyFieldOnlyOnceItsAddressIsTaken() async {
        let (model, providers, _, _, _) = rig(on: true)
        XCTAssertTrue(model.showsKeyField, "Claude takes a key at once")
        model.choose(.other)
        XCTAssertFalse(model.showsKeyField, "a key typed now would have no address to be saved under")
        XCTAssertFalse(AIModeScreen.parts(for: model).contains(.key))
        model.setAddress("http://models.example.com")
        XCTAssertFalse(model.showsKeyField, "a refused address isn't taken")
        providers.answers["other"] = .models(["served-model"])
        model.setAddress("models.example.com")
        XCTAssertTrue(model.showsKeyField)
        XCTAssertEqual(AIModeScreen.parts(for: model), [.titleRow, .sentence, .provider, .address, .key, .state, .consent, .done])
        await model.settle()
        model.choose(.ollama)
        XCTAssertFalse(model.showsKeyField, "a local provider has no key field")
    }

    func testAnAddressWhoseModelsAreUnderV1IsSavedWithV1() async {
        let (model, providers, _, services, _) = rig(on: true)
        model.choose(.other)
        // Only /v1/models answers, as the live client finds by asking there after the first list fails.
        providers.answers["other/v1"] = .models(["served-model"])
        model.setAddress("api.example.net")
        await model.settle()
        XCTAssertEqual(services.config.config.otherAddress, "api.example.net/v1")
        XCTAssertEqual(model.connection, .connected(1))
        // Where the plain address has the list itself and /v1 doesn't, the address stays as typed.
        providers.answers = ["other": .models(["served-model"])]
        model.setAddress("api.example.org")
        await model.settle()
        XCTAssertEqual(services.config.config.otherAddress, "api.example.org")
        XCTAssertEqual(model.connection, .connected(1))
    }

    // MARK: Done and leaving

    func testDoneCommitsATypedKeyAndClosesOnlyWhenOffOrConnected() async {
        let (model, providers, store, _, settings) = rig()
        let closesWhileOff = await model.done(pendingKey: nil)
        XCTAssertTrue(closesWhileOff)
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))

        model.setOn(true)
        let closesWithNoKey = await model.done(pendingKey: nil)
        XCTAssertFalse(closesWithNoKey, "on, with no key: the state stays on show")

        providers.answers["claude"] = .failure(.wrongKey)
        let closesWithAWrongKey = await model.done(pendingKey: testKey)
        XCTAssertFalse(closesWithAWrongKey)
        XCTAssertEqual(store.accounts, ["claude|api.anthropic.com:443"], "Done entered the typed key")

        providers.answers["claude"] = .models(["claude-opus-5-5"])
        let closesConnected = await model.done(pendingKey: testKey)
        XCTAssertTrue(closesConnected)
        XCTAssertTrue(model.isOn, "Done leaves AI mode on")
    }

    func testDoneRefusedForAMissingKeyMarksItAsTheProblem() async {
        let (model, _, _, _, _) = rig(on: true)
        XCTAssertEqual(model.connection, .noKey)
        XCTAssertFalse(model.stateIsProblem, "No key is quiet until Done is pressed")
        let closes = await model.done(pendingKey: nil)
        XCTAssertFalse(closes)
        XCTAssertEqual(model.refusedDone, 1, "the screen hears that Done couldn't close")
        XCTAssertTrue(model.flagsMissingKey)
        XCTAssertTrue(model.stateIsProblem, "No key turns orange, as Wrong key is")
        _ = await model.done(pendingKey: nil)
        XCTAssertEqual(model.refusedDone, 2, "every refusal is heard, so the caret goes back each time")
        model.choose(.openAI)
        XCTAssertEqual(model.connection, .noKey)
        XCTAssertFalse(model.stateIsProblem, "another provider starts quiet")
    }

    func testDoneEntersATypedAddressPortAndModelName() async {
        let (model, providers, _, services, _) = rig(on: true)
        model.choose(.other)
        providers.answers["other"] = .models(["served-model"])
        // An address typed without Return: Done enters it, so the check runs.
        model.commitTyped(address: "models.example.com", port: "", model: "")
        let closes = await model.done(pendingKey: nil)
        XCTAssertTrue(closes)
        XCTAssertEqual(services.config.config.otherAddress, "models.example.com")
        let asked = providers.asked
        XCTAssertFalse(asked.isEmpty, "the typed address was checked")
        XCTAssertTrue(asked.allSatisfy { $0 == "other" })
        // The same address again, in another spelling, is not asked again.
        model.commitTyped(address: "https://models.example.com", port: nil, model: nil)
        await model.settle()
        XCTAssertEqual(providers.asked, asked)

        // A model's name typed where the address lists none.
        providers.answers["other"] = .models([])
        model.tryAgain()
        await model.settle()
        XCTAssertTrue(model.showsModelField)
        model.commitTyped(model: " typed-model ")
        XCTAssertEqual(model.model, "typed-model")

        // A port typed for a local provider that isn't running.
        providers.answers["ollama"] = .failure(.notRunning)
        model.choose(.ollama)
        await model.settle()
        model.commitTyped(port: "11500")
        XCTAssertEqual(services.config.config.ports["ollama"], 11500)
        model.commitTyped(address: "elsewhere.example.com", port: "", model: "other-model")
        XCTAssertNil(services.config.config.models["ollama"].flatMap { $0 == "other-model" ? $0 : nil },
                     "an address and a model name are Other's alone")
    }

    func testALocalProviderThatCantBeReachedShowsItsPort() async {
        let (model, providers, _, _, _) = rig(on: true)
        providers.answers["ollama"] = .failure(.unreachable)
        model.choose(.ollama)
        await model.settle()
        XCTAssertEqual(model.connection, .cantReach)
        XCTAssertTrue(model.showsPort, "the port may be why it can't be reached")
        XCTAssertTrue(AIModeScreen.parts(for: model).contains(.port))
    }

    func testOtherHasNoModelRowUntilItsAddressIsTaken() {
        let (model, _, _, _, _) = rig(on: true)
        model.choose(.other)
        XCTAssertFalse(model.hasProfile)
        model.setAddress("models.example.com")
        XCTAssertTrue(model.hasProfile)
    }

    func testDoneAsksAProviderThatHasNotBeenAskedYet() async {
        let (model, providers, _, _, _) = rig(config: AIConfig(provider: "ollama"), on: true)
        providers.answers["ollama"] = .models(["llama4:8b"])
        XCTAssertEqual(model.connection, AISetupModel.Connection.none)
        let closes = await model.done(pendingKey: nil)
        XCTAssertTrue(closes)
        XCTAssertEqual(providers.asked, ["ollama"])
    }

    func testOnlyDoneLeavesAIModeOn() {
        let (model, _, _, _, settings) = rig(on: true)
        model.closedWithoutDone()
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled))
        XCTAssertFalse(model.isOn)
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
    }

    func testTurningOffForgetsTheState() async {
        let (model, providers, _, services, _) = rig(on: true)
        providers.answers["ollama"] = .models(["llama4:8b"])
        model.choose(.ollama)
        await model.settle()
        model.setOn(false)
        XCTAssertEqual(model.connection, AISetupModel.Connection.none)
        XCTAssertEqual(model.models, [])
        model.tryAgain()
        await model.settle()
        XCTAssertEqual(providers.asked, ["ollama"], "nothing is asked while AI mode is off")
        XCTAssertFalse(services.runtime.isOn)
    }

    // MARK: Opening the pane

    func testOpeningThePaneMakesNoRequest() async throws {
        let saved = MemorySecretStore()
        try saved.save(try XCTUnwrap(AgentSecret(pasted: testKey)), for: AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443))
        let (model, providers, _, services, settings) = rig(store: saved, config: AIConfig(provider: "claude"), on: true)
        let window = SettingsWindowController(store: settings, fileViewer: nil, persistsFrame: false)
        defer { window.close() }
        window.showAI(model)
        window.select(.ai)
        XCTAssertTrue(window.aiSetupModel === model)
        window.showAI(model)
        XCTAssertEqual(window.selectedPane, .ai)
        try await Task.sleep(nanoseconds: 300_000_000)
        await model.settle()
        XCTAssertEqual(providers.asked, [], "opening Settings › AI asks nothing")
        XCTAssertEqual(services.runtime.clientBuildCount, 0)
        XCTAssertTrue(model.hasSavedKey)
        XCTAssertEqual(model.connection, AISetupModel.Connection.none)
        // The pane is at least as tall as its usual height.
        XCTAssertGreaterThanOrEqual(AISettingsView.height(for: model), SettingsPane.ai.height)
    }

    // MARK: Parts

    /// Every string held in `value`'s stored properties, and in theirs, a few levels down.
    private static func strings(in value: Any, depth: Int = 4) -> [String] {
        if let text = value as? String { return [text] }
        guard depth > 0 else { return [] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value, depth: depth - 1) }
    }
}

/// A key store that macOS refuses to save into.
private final class AISetupRefusingStore: AgentSecretStoring, @unchecked Sendable {
    func has(_ id: AgentSecretID) -> Bool { false }
    func secret(for id: AgentSecretID) throws -> AgentSecret? { throw AgentSecretError.denied }
    func save(_ secret: AgentSecret, for id: AgentSecretID) throws { throw AgentSecretError.denied }
    func remove(_ id: AgentSecretID) throws {}
    var isMemoryOnly: Bool { true }
}

/// A client for each provider that answers its model list from a table, keyed by the provider's identifier, with
/// the address's path after a slash for Other. A provider that takes a key is asked for it first, as the live
/// client does, so a refused keychain fails the same way. It keeps which providers were asked.
final class AISetupFakeProviders: @unchecked Sendable {
    enum Answer { case models([String]), failure(AgentFailure) }

    private let lock = NSLock()
    private var table: [String: Answer] = [:]
    private var names: [String: String] = [:]
    private var askedList: [String] = []
    private var askedPorts: [Int] = []

    var answers: [String: Answer] {
        get { lock.lock(); defer { lock.unlock() }; return table }
        set { lock.lock(); defer { lock.unlock() }; table = newValue }
    }
    /// The display names a list gives its models, as a ChatGPT plan's does.
    var labels: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return names }
        set { lock.lock(); defer { lock.unlock() }; names = newValue }
    }
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return askedList }
    var ports: [Int] { lock.lock(); defer { lock.unlock() }; return askedPorts }

    var makeClient: @Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient {
        { [self] profile, _, secrets in AISetupFakeClient(profile: profile, secrets: secrets, providers: self) }
    }

    fileprivate func models(for profile: AgentProviderProfile, secrets: any AgentSecretStoring) throws -> [AgentModelInfo] {
        lock.lock()
        askedList.append(profile.id.rawValue)
        askedPorts.append(profile.endpoint.port)
        let table = self.table, labels = self.names
        lock.unlock()
        if profile.needsKey || secrets.has(profile.secretID) {
            do {
                guard try secrets.secret(for: profile.secretID) != nil else { throw AgentFailure.noKey }
            } catch AgentSecretError.denied {
                throw AgentFailure.keyDenied
            }
        }
        var key = profile.id.rawValue
        if profile.id == .other { key += profile.endpoint.basePath }
        var answer = table[key]
        // The live client asks a typed address under /v1 when its first list fails.
        if profile.id == .other, profile.endpoint.basePath.isEmpty, answer.map(Self.fails) ?? true,
           let alternate = table[key + "/v1"] {
            answer = alternate
        }
        switch answer ?? .failure(.unreachable) {
        case .models(let names): return names.compactMap { AgentModelInfo(id: $0, label: labels[$0]) }
        case .failure(let failure): throw failure
        }
    }

    private static func fails(_ answer: Answer) -> Bool {
        if case .failure = answer { return true } else { return false }
    }
}

private final class AISetupFakeClient: AgentLiveClient, @unchecked Sendable {
    let profile: AgentProviderProfile
    let secrets: any AgentSecretStoring
    let providers: AISetupFakeProviders
    init(profile: AgentProviderProfile, secrets: any AgentSecretStoring, providers: AISetupFakeProviders) {
        self.profile = profile; self.secrets = secrets; self.providers = providers
    }
    var providerName: String { profile.name }
    var destination: String { profile.destination }
    var isLocal: Bool { profile.isLocal }
    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentFailure.unreachable) }
    }
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { [] }
    func structured(_ ask: AgentStructuredAsk) async throws -> Data { throw AgentFailure.unreachable }
    func models() async throws -> [AgentModelInfo] { try providers.models(for: profile, secrets: secrets) }
    func shutdown() async {}
}
#endif
