#if os(macOS)
import Foundation
import HelmAgent
import HelmCore
import HelmPersistence

/// What Settings › AI and the AI mode screen show and change: whether AI mode is on, the provider, its key or its
/// ChatGPT sign-in, and its model, with a line and a page on how to connect each provider. Both are drawn from one
/// model, so they always agree.
///
/// Nothing here asks a provider anything until the person does something that needs an answer: enters a key, signs
/// in, picks a provider that runs on this Mac or has a saved key or sign-in, sets an address, or presses Try Again or
/// Refresh Models. Opening either screen asks nothing. A saved key or sign-in is never read back: the store is asked
/// only whether one is there, and for the email saved beside a sign-in.
@MainActor public final class AISetupModel: ObservableObject {
    /// Where the chosen provider stands, as the state line beside its key or local app says.
    public enum Connection: Equatable {
        case none, checking, connected(Int), noKey, wrongKey, cantReach, notRunning, noModels, keyDenied, planLimit, planNotCovered
    }
    /// Where a ChatGPT sign-in stands: none under way, waiting for the browser, or ended with a line to show.
    public enum SignIn: Equatable { case idle, waiting, failed(String) }

    private let settings: SettingsStore
    private let services: AgentServices

    @Published public private(set) var isOn: Bool
    /// The saved provider, else Claude.
    @Published public private(set) var provider: AgentProviderID
    @Published public private(set) var connection: Connection = .none
    @Published public private(set) var models: [AgentModelInfo] = []
    /// The model requests go to: the one chosen for this provider, else the provider's own first choice.
    @Published public private(set) var model: String?
    /// Why the address typed for Other wasn't taken, as one line. Nil when it was, or when none was typed.
    @Published private(set) var addressProblem: String?
    /// How many times Done was pressed and the screen couldn't close, since the provider was last shown. The screen
    /// marks a missing key as the problem and puts the caret back in its field each time.
    @Published private(set) var refusedDone = 0
    @Published public private(set) var signIn: SignIn = .idle
    /// Said after Remove when OpenAI didn't confirm that it revoked the sign-in.
    @Published private(set) var signOutLine: String?
    /// The sign-in under way, for Cancel and tests.
    private(set) var signInTask: Task<Void, Never>?
    /// The last sign-in was declined or didn't allow plan use, so the next one asks the person to agree again.
    private var signInAsksConsent = false

    /// What pressing Done does on the AI mode screen, with the key typed into its field and not yet entered. The
    /// window showing the screen sets it.
    var donePressed: ((String?) -> Void)?
    /// The check under way, for tests and Done to wait on.
    private(set) var checking: Task<Void, Never>?
    /// Moves on with every check, so an answer that arrives after a newer question is dropped.
    private var checkCount = 0

    public init(settings: SettingsStore, services: AgentServices) {
        self.settings = settings; self.services = services
        isOn = settings.snapshot.bool(.aiModeEnabled)
        let config = services.config.config
        let saved = config.provider.flatMap(AgentProviderID.init(rawValue:)) ?? .claude
        provider = saved
        model = Self.model(for: saved, in: config)
        connection = restingConnection
        // The runtime follows the switch wherever it is changed: here, in Settings, or by a script.
        services.runtime.setOn(isOn)
        _ = settings.changes.subscribe { [weak self] snapshot in self?.settingsChanged(snapshot) }
        _ = services.config.changes.subscribe { [weak self] config in self?.configChanged(config) }
    }

    // MARK: What the screens show

    /// The one line that says what is sent and to whom, and that Helm itself collects nothing.
    public var consentLine: String {
        if let profile { return AgentText.consentSetup(profile.destination) }
        return AgentText.consentSetup(provider == .other ? AgentText.destinationNotSet : providerName)
    }

    /// Whether a key is saved for the provider at its address. The key itself is never read. Never for OpenAI while it
    /// is reached with a ChatGPT sign-in.
    public var hasSavedKey: Bool { !usesChatGPT && (profile.map { services.secrets.has($0.secretID) } ?? false) }

    /// OpenAI, reached with the person's ChatGPT sign-in: the usual way, unless they chose to use a key instead.
    public var usesChatGPT: Bool { provider == .openAI && !services.config.config.openAIUsesKey }
    /// Signed in with ChatGPT, from the keychain item's attributes alone.
    public var isSignedIn: Bool { services.secrets.hasSignIn(.chatGPTTokens) }
    /// What the provider needs before it can be asked: a saved key, or the ChatGPT sign-in.
    var hasCredential: Bool { usesChatGPT ? isSignedIn : hasSavedKey }
    /// Who is signed in with ChatGPT, by the email saved beside the sign-in. Nil unless signed in.
    var accountLine: String? {
        guard usesChatGPT, isSignedIn else { return nil }
        return services.secrets.signInNote(.chatGPTTokens).map(AgentText.signedInAs) ?? AgentText.signedIn
    }
    /// The line a sign-in under way or one that ended shows.
    var signInLine: String? {
        switch signIn {
        case .idle: return nil
        case .waiting: return AgentText.signInWaiting
        case .failed(let line): return line
        }
    }

    /// The info button's tooltip: what the provider uses and what it costs.
    var helpLine: String { AgentText.providerHelp(provider, usesChatGPT: usesChatGPT) }
    /// The provider's page on connecting. Nil for Other.
    var helpPage: URL? { AgentHelpLinks.howToConnect(provider, usesChatGPT: usesChatGPT) }
    /// The providers whose model must be one their list names: what runs on this Mac, a typed address and a ChatGPT
    /// plan offer only what they list.
    var picksFromList: Bool { isLocal || provider == .other || usesChatGPT }
    /// Refresh Models can ask now: the provider has an address, and what it needs to be asked.
    var canRefreshModels: Bool {
        isOn && profile != nil && connection != .checking && (isLocal || provider == .other || hasCredential)
    }

    /// A local provider whose server isn't answering, or can't be reached: its port may be the reason.
    public var showsPort: Bool { isLocal && (connection == .notRunning || connection == .cantReach) }
    /// Done was pressed with no key for a provider that needs one, so "No key" is the problem to fix.
    var flagsMissingKey: Bool { connection == .noKey && refusedDone > 0 }
    /// The state line is drawn as a problem, in orange.
    var stateIsProblem: Bool { offersTryAgain || connection == .wrongKey || flagsMissingKey }
    /// The provider is reached where it is: for Other, once an address has been taken.
    var hasProfile: Bool { profile != nil }

    /// Other, when its address gave no list of models to choose from.
    public var showsModelField: Bool {
        guard provider == .other, profile != nil, models.isEmpty else { return false }
        return connection == .noModels || connection == .cantReach
    }

    /// Ollama and LM Studio: no key, and a state in its place.
    var isLocal: Bool { provider == .ollama || provider == .lmStudio }
    /// The providers that take a key: the four cloud ones and a typed address.
    var takesKey: Bool { provider != .ollama && provider != .lmStudio }
    /// The key field shows for a provider that takes a key, and for Other only once its address has been taken, so a
    /// key is always saved under the address it is for. OpenAI shows it only when the person chose a key over their
    /// ChatGPT sign-in.
    var showsKeyField: Bool { takesKey && profile != nil && !usesChatGPT }
    /// The port a local provider is asked on.
    var port: Int? { services.config.config.ports[provider.rawValue] ?? AgentProviderCatalog.defaultPort(provider) }
    /// The address saved for Other, as it was taken.
    var address: String { services.config.config.otherAddress ?? "" }
    /// The provider's name, as the menu lists it.
    var providerName: String { AgentProviderCatalog.name(provider) }

    /// The state line, or nil when there is nothing to say.
    var stateLine: String? {
        switch connection {
        case .none: return nil
        case .checking: return AgentText.stateChecking
        case .connected: return AgentText.stateConnected
        // With ChatGPT the button is the call to act; Done pressed without it says what is missing.
        case .noKey where usesChatGPT: return refusedDone > 0 ? AgentText.signInFirst : nil
        case .noKey: return AgentText.stateNoKey
        case .wrongKey: return AgentText.stateWrongKey
        case .cantReach: return AgentText.stateCantReach(destinationName)
        case .notRunning: return provider == .lmStudio ? AgentText.failLMStudioNotRunning : AgentText.failOllamaNotRunning
        case .noModels: return AgentText.stateNoModels(destinationName)
        case .keyDenied: return AgentText.failKeyDenied
        case .planLimit: return AgentText.planLimit
        case .planNotCovered: return AgentText.statePlanNotCovered
        }
    }
    /// The state line has Try Again beside it. A provider with no models yet is asked again once one is loaded.
    var offersTryAgain: Bool {
        switch connection {
        case .cantReach, .notRunning, .keyDenied, .noModels: return true
        case .none, .checking, .connected, .noKey, .wrongKey, .planLimit, .planNotCovered: return false
        }
    }
    var isConnected: Bool { if case .connected = connection { return true } else { return false } }
    /// The models the menu offers: the provider's list, with the chosen one first if the list doesn't have it.
    var modelChoices: [String] {
        let listed = models.map(\.id)
        guard let model, !listed.contains(model) else { return listed }
        return [model] + listed
    }
    /// What the menu shows for a model: its name from a ChatGPT plan's list, else its id.
    func modelTitle(_ id: String) -> String { models.first { $0.id == id }?.title ?? id }

    // MARK: What the person does

    public func setOn(_ on: Bool) {
        if on { keepProvider() }
        guard settings.snapshot.bool(.aiModeEnabled) != on else { return }
        settings.set(.bool(on), for: .aiModeEnabled)
    }

    /// A local provider, or one with a saved key or sign-in, is checked at once.
    public func choose(_ provider: AgentProviderID) {
        services.config.update { $0.provider = provider.rawValue }
        if self.provider != provider { show(provider) }
        if isLocal || (takesKey && hasCredential) { check() } else { stopChecking() }
    }

    /// Asks the provider for its models again, as Try Again does: Refresh Models beside the model menu.
    public func refreshModels() {
        guard canRefreshModels else { return }
        check(triesV1: false)
    }

    // MARK: ChatGPT

    /// Continue with ChatGPT: signs in through the browser, and checks the connection once signed in. While AI mode is
    /// off, in a fixture run, or with a sign-in already under way, nothing starts.
    public func continueWithChatGPT() {
        guard isOn, usesChatGPT, signIn != .waiting else { return }
        keepProvider()
        signOutLine = nil
        guard let session = services.runtime.chatGPTSignIn() else {
            signIn = .failed(AgentText.signInUnavailable)
            return
        }
        signIn = .waiting
        let open = services.openInBrowser
        let asksConsent = signInAsksConsent
        signInTask = Task { [weak self] in
            var failure: AgentSignInFailure?
            do {
                _ = try await session.run(asksConsent: asksConsent) { address in await MainActor.run { open(address) } }
            } catch {
                failure = error as? AgentSignInFailure ?? .failed
            }
            guard let self else { return }
            self.finishSignIn(failure)
        }
    }

    /// Stops a sign-in under way. The browser may stay open on OpenAI's page; nothing comes back from it.
    public func cancelSignIn() { signInTask?.cancel() }

    /// Remove: signs out of ChatGPT. The tokens leave the keychain, and OpenAI is asked to revoke the sign-in; when it
    /// doesn't confirm, a line says where to disconnect Helm by hand.
    public func removeSignIn() {
        guard usesChatGPT, isSignedIn else { return }
        stopChecking()
        models = []
        let runtime = services.runtime
        signOutTask = Task { [weak self] in
            let confirmed = await runtime.signOutOfChatGPT()
            guard let self else { return }
            self.signOutLine = confirmed ? nil : AgentText.signOutUnconfirmed
            self.objectWillChange.send()
            self.connection = self.restingConnection
            self.signOutTask = nil
        }
    }
    /// The sign-out under way, for tests to wait on.
    private(set) var signOutTask: Task<Void, Never>?

    /// "Use an API key instead", or back to the ChatGPT sign-in. Either is checked at once when it is ready.
    public func useKey(_ key: Bool) {
        guard provider == .openAI, services.config.config.openAIUsesKey != key else { return }
        cancelSignIn()
        keepProvider()
        services.config.update { $0.openAIUsesKey = key }
        show(provider)
        if hasCredential { check() }
    }

    /// Opens the provider's page on connecting in the browser.
    public func openHowToConnect() {
        guard let page = helpPage else { return }
        _ = services.openInBrowser(page)
    }

    /// Opens ChatGPT's usage settings in the browser.
    public func openManageUsage() {
        guard let page = AgentHelpLinks.manageUsage else { return }
        _ = services.openInBrowser(page)
    }

    private func finishSignIn(_ failure: AgentSignInFailure?) {
        signInTask = nil
        services.runtime.chatGPTSignInChanged()
        objectWillChange.send()
        guard let failure else {
            signInAsksConsent = false
            signIn = .idle
            if usesChatGPT { check() }
            return
        }
        if failure == .declined || failure == .planOff { signInAsksConsent = true }
        signIn = AgentText.signInFailure(failure).map(SignIn.failed) ?? .idle
        if usesChatGPT, connection != .checking { connection = restingConnection }
    }

    /// Takes a pasted key, saves it under the provider and the address it is for, clears the field and checks it.
    /// A key with a control character, a character outside ASCII or nothing in it is refused and nothing is saved.
    public func enterKey(_ text: String) {
        guard takesKey else { return }
        guard let secret = AgentSecret(pasted: text) else {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stopChecking(); connection = .wrongKey }
            return
        }
        guard let profile else { return }
        keepProvider()
        do {
            try services.secrets.save(secret, for: profile.secretID)
        } catch {
            stopChecking()
            connection = .keyDenied
            return
        }
        let stamp = Self.buildStamp()
        services.config.update { $0.keyOwners[profile.secretID.account] = stamp }
        objectWillChange.send()
        check()
    }

    public func removeKey() {
        guard let profile, services.secrets.has(profile.secretID) else { return }
        do {
            try services.secrets.remove(profile.secretID)
        } catch {
            connection = .keyDenied
            return
        }
        services.config.update { $0.keyOwners[profile.secretID.account] = nil }
        stopChecking()
        refusedDone = 0
        models = []
        objectWillChange.send()
        connection = restingConnection
    }

    public func tryAgain() { check() }

    /// Digits only, kept to 1024 to 65535. The next Try Again asks on the new port.
    public func setPort(_ text: String) {
        guard isLocal else { return }
        let digits = String(text.unicodeScalars.filter { ("0"..."9").contains($0) }.prefix(Self.portDigits))
        guard let number = Int(digits) else { return }
        let port = min(max(number, Self.ports.lowerBound), Self.ports.upperBound)
        keepProvider()
        services.config.update { $0.ports[provider.rawValue] = port }
        objectWillChange.send()
    }

    /// The address of a provider that isn't on the list. It must be an https host name on the internet; plain http,
    /// an IP address, a one-word name and a `.local` name are refused with their line. A good one is saved and asked
    /// for its models.
    public func setAddress(_ text: String) {
        guard provider == .other else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            addressProblem = nil
            services.config.update { $0.otherAddress = nil }
            stopChecking()
            models = []
            connection = .none
            return
        }
        let endpoint: AgentEndpoint
        do {
            endpoint = try AgentEndpoint(typed: trimmed)
        } catch let refusal as AgentEndpointRefusal {
            addressProblem = refusal == .otherDevice ? AgentText.addressOtherDevice : AgentText.addressNeedsHTTPS
            return
        } catch {
            addressProblem = AgentText.addressNeedsHTTPS
            return
        }
        addressProblem = nil
        let saved = Self.address(of: endpoint)
        keepProvider()
        if saved != address {
            models = []
            services.config.update { $0.otherAddress = saved }
        }
        check(triesV1: true)
    }

    public func chooseModel(_ id: String) {
        guard let info = AgentModelInfo(id: id) else { return }
        keepProvider()
        services.config.update { $0.models[provider.rawValue] = info.id }
        model = info.id
    }

    /// Other only: a model named by hand, when the address gives no list.
    public func typeModel(_ text: String) {
        guard provider == .other else { return }
        chooseModel(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Commits a typed key, and answers whether the screen may close: when the switch is off, or the state is
    /// Connected. A provider that hasn't been asked yet is asked now, since Done is the person's own press.
    public func done(pendingKey: String?) async -> Bool {
        if isOn, let pendingKey, !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            enterKey(pendingKey)
        }
        await settle()
        if isOn, connection == .none, isLocal || hasCredential || provider == .other {
            check()
            await settle()
        }
        let leaves = !isOn || isConnected
        if leaves { markSeen() } else { refusedDone += 1 }
        return leaves
    }

    /// What was typed into the address, port and model name fields and not yet entered with Return: each is entered
    /// now, when it holds something and says something other than what is saved. Done does this before it checks, so
    /// a typed address is asked, and Settings does it as a field or the pane is left.
    func commitTyped(address typedAddress: String? = nil, port typedPort: String? = nil, model typedModel: String? = nil) {
        if let typedAddress, provider == .other {
            let trimmed = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let same = (try? AgentEndpoint(typed: trimmed)).map { Self.address(of: $0) == address } ?? false
            if !trimmed.isEmpty, !same { setAddress(trimmed) }
        }
        if let typedPort, isLocal {
            let digits = String(typedPort.unicodeScalars.filter { ("0"..."9").contains($0) })
            if let number = Int(digits.prefix(Self.portDigits)), number != port { setPort(digits) }
        }
        if let typedModel, provider == .other {
            let trimmed = typedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != model { typeModel(trimmed) }
        }
    }

    /// The AI mode screen was left some way other than Done, so AI mode is off: only Done leaves it on.
    public func closedWithoutDone() {
        setOn(false)
        markSeen()
    }

    /// Presses a control by its title, as a click would. Scripts use this.
    public func press(_ title: String) { _ = pressed(title) }

    /// What `press` did: false when nothing on show has that title.
    func pressed(_ title: String) -> Bool {
        switch title {
        case AgentText.aiTitle, AgentText.settingsAIMode: setOn(!isOn)
        case AgentText.tryAgain where offersTryAgain: tryAgain()
        case AgentText.removeKey where hasSavedKey: removeKey()
        case AgentText.continueWithChatGPT where isOn && usesChatGPT && !isSignedIn && signIn != .waiting: continueWithChatGPT()
        case AgentText.cancel where signIn == .waiting: cancelSignIn()
        case AgentText.removeSignIn where isOn && usesChatGPT && isSignedIn: removeSignIn()
        case AgentText.useKeyInstead where isOn && usesChatGPT: useKey(true)
        case AgentText.useChatGPTInstead where isOn && provider == .openAI && !usesChatGPT: useKey(false)
        case AgentText.howToConnect where isOn && helpPage != nil: openHowToConnect()
        case AgentText.refreshModels where canRefreshModels: refreshModels()
        case AgentText.done:
            guard let donePressed else { return false }
            donePressed(nil)
        default:
            guard isOn, let id = AgentProviderID.allCases.first(where: { AgentProviderCatalog.name($0) == title }) else { return false }
            choose(id)
        }
        return true
    }

    /// "none", "checking", "connected", "noKey", "wrongKey", "cantReach", "notRunning", "noModels", "keyDenied",
    /// "planLimit" or "planNotCovered".
    public var connectionForTesting: String {
        switch connection {
        case .none: return "none"
        case .checking: return "checking"
        case .connected: return "connected"
        case .noKey: return "noKey"
        case .wrongKey: return "wrongKey"
        case .cantReach: return "cantReach"
        case .notRunning: return "notRunning"
        case .noModels: return "noModels"
        case .keyDenied: return "keyDenied"
        case .planLimit: return "planLimit"
        case .planNotCovered: return "planNotCovered"
        }
    }

    /// Every line of words the AI mode screen shows now, top to bottom.
    public var linesForTesting: [String] {
        var lines = [AgentText.aiTitle, AgentText.aiSentence]
        guard isOn else { return lines }
        lines.append(consentLine)
        if let addressProblem { lines.append(addressProblem) }
        if let accountLine { lines.append(accountLine) }
        if let signInLine { lines.append(signInLine) }
        if let signOutLine { lines.append(signOutLine) }
        if let stateLine { lines.append(stateLine) }
        if hasSavedKey { lines.append(AgentText.keySaved) }
        return lines
    }

    /// Waits for the check under way, if there is one.
    func settle() async {
        while let task = checking {
            await task.value
            if checking == task { break }
        }
    }

    // MARK: Checking

    /// The provider and where it is reached, from what is saved now.
    private var profile: AgentProviderProfile? {
        var config = services.config.config
        config.provider = provider.rawValue
        return try? AgentProviderCatalog.profile(for: config).get()
    }

    /// How the provider stands before anything has been asked: a cloud provider with no key has none, and OpenAI
    /// with no ChatGPT sign-in has none either, which needs no question to know.
    private var restingConnection: Connection {
        guard isOn else { return .none }
        if usesChatGPT { return isSignedIn ? .none : .noKey }
        if let profile, profile.needsKey, !services.secrets.has(profile.secretID) { return .noKey }
        return .none
    }

    private var destinationName: String {
        provider == .other ? (profile?.endpoint.hostLabel ?? providerName) : providerName
    }

    /// Asks the provider for its models, which is how a connection is checked. A typed address that answers is
    /// asked once more under /v1, since that is where most such servers keep their requests; when it answers there
    /// too, the address is saved with /v1 on its end.
    private func check(triesV1: Bool = false) {
        guard isOn, profile != nil else { return }
        keepProvider()
        checkCount += 1
        let count = checkCount
        let runtime = services.runtime
        let draft = services.config.config
        connection = .checking
        checking = Task { [weak self] in
            let answer = await runtime.check(draft)
            guard let self, count == self.checkCount else { return }
            if triesV1, case .connected = answer, let longer = self.addressWithV1(draft) {
                var other = draft
                other.otherAddress = longer
                if case .connected = await runtime.check(other), count == self.checkCount {
                    self.services.config.update { $0.otherAddress = longer }
                }
                guard count == self.checkCount else { return }
            }
            self.apply(answer)
            self.checking = nil
        }
    }

    private func apply(_ answer: AgentConnection) {
        switch answer {
        case .connected(let listed) where listed.isEmpty:
            // Connected means a model can run, so a provider that lists none says so instead.
            models = []
            connection = .noModels
        case .connected(let listed):
            models = listed
            connection = .connected(listed.count)
            // A Connected provider is always ready to run. One with no first choice of its own runs the first model it
            // lists until another is picked. LM Studio, Ollama, Other and a ChatGPT plan also leave a model the list no
            // longer has, or a first choice the plan doesn't offer, for the plan's own first choice or the first listed.
            let listedIDs = Set(listed.map(\.id))
            let unlisted = model.map { !listedIDs.contains($0) } ?? true
            if model == nil || (picksFromList && unlisted), let first = listed.first {
                chooseModel(AgentModelLister.preselected(listed, provider: provider) ?? first.id)
            }
        case .noKey: models = []; connection = .noKey
        case .wrongKey: models = []; connection = .wrongKey
        case .cantReach: models = []; connection = .cantReach
        case .notRunning: models = []; connection = .notRunning
        case .noModels: models = []; connection = .noModels
        case .keyDenied: models = []; connection = .keyDenied
        case .planLimit: models = []; connection = .planLimit
        case .planNotCovered: models = []; connection = .planNotCovered
        case .off: models = []; connection = .none
        }
    }

    private func stopChecking() {
        checkCount += 1
        checking = nil
    }

    /// The typed address with /v1 on its end, or nil when it already ends there.
    private func addressWithV1(_ config: AIConfig) -> String? {
        guard provider == .other, let text = config.otherAddress, let endpoint = try? AgentEndpoint(typed: text),
              !endpoint.basePath.hasSuffix(Self.versionPath) else { return nil }
        return Self.address(of: endpoint) + Self.versionPath
    }

    // MARK: Following changes made elsewhere

    private func settingsChanged(_ snapshot: SettingsSnapshot) {
        let on = snapshot.bool(.aiModeEnabled)
        services.runtime.setOn(on)
        guard on != isOn else { return }
        isOn = on
        refusedDone = 0
        cancelSignIn()
        stopChecking()
        models = []
        connection = restingConnection
    }

    private func configChanged(_ config: AIConfig) {
        if let saved = config.provider.flatMap(AgentProviderID.init(rawValue:)), saved != provider { show(saved) }
        objectWillChange.send()
        let chosen = Self.model(for: provider, in: config)
        if chosen != model { model = chosen }
    }

    /// Shows another provider, with nothing asked yet.
    private func show(_ next: AgentProviderID) {
        stopChecking()
        if next != provider || signIn != .waiting { cancelSignIn() }
        provider = next
        refusedDone = 0
        models = []
        addressProblem = nil
        signOutLine = nil
        if signIn != .waiting { signIn = .idle }
        model = Self.model(for: next, in: services.config.config)
        connection = restingConnection
    }

    /// The provider on show is saved once the person acts on it, so the runtime knows which one to use.
    private func keepProvider() {
        guard services.config.config.provider != provider.rawValue else { return }
        services.config.update { $0.provider = provider.rawValue }
    }

    /// The screen has been seen: it doesn't open by itself at launch again.
    private func markSeen() {
        if !settings.snapshot.bool(.aiIntroSeen) { settings.set(.bool(true), for: .aiIntroSeen) }
    }

    // MARK: Parts

    private static let ports = 1024...65535
    private static let portDigits = 5
    private static let versionPath = "/v1"

    private static func model(for provider: AgentProviderID, in config: AIConfig) -> String? {
        var chosen = config
        chosen.provider = provider.rawValue
        return AgentProviderCatalog.model(for: chosen)
    }

    /// An endpoint written back as an address: the host in ASCII, the port when it isn't the usual one, and the path.
    /// It has no scheme, since a typed address is always read as https.
    private static func address(of endpoint: AgentEndpoint) -> String {
        let port = endpoint.port == securePort ? "" : ":\(endpoint.port)"
        return endpoint.host + port + endpoint.basePath
    }
    private static let securePort = 443

    /// Which build saved a key: the app's own size and modification date, as the app works it out for the runtime.
    /// It names no path.
    private static func buildStamp() -> String {
        guard let executable = Bundle.main.executableURL,
              let values = try? executable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "" }
        let size = values.fileSize.map(String.init) ?? "?"
        let modified = values.contentModificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        return "\(size)-\(modified)"
    }
}
#endif
