#if os(macOS)
import Foundation
import HelmAgent
import HelmCore
import HelmPersistence

/// What Settings › AI and the AI mode screen show and change: whether AI mode is on, the provider, its key and its
/// model. Both are drawn from one model, so they always agree.
///
/// Nothing here asks a provider anything until the person does something that needs an answer: enters a key, picks
/// a provider that runs on this Mac or has a saved key, sets an address, or presses Try Again. Opening either screen
/// asks nothing. A saved key is never read back: the store is asked only whether one is there.
@MainActor public final class AISetupModel: ObservableObject {
    /// Where the chosen provider stands, as the state line beside its key or local app says.
    public enum Connection: Equatable { case none, checking, connected(Int), noKey, wrongKey, cantReach, notRunning, noModels, keyDenied }

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

    /// The one line that says what is sent and to whom.
    public var consentLine: String {
        if let profile { return AgentText.consent(profile.destination) }
        return AgentText.consent(provider == .other ? AgentText.destinationNotSet : providerName)
    }

    /// Whether a key is saved for the provider at its address. The key itself is never read.
    public var hasSavedKey: Bool { profile.map { services.secrets.has($0.secretID) } ?? false }

    /// A local provider whose server isn't answering: its port may be the reason.
    public var showsPort: Bool { isLocal && connection == .notRunning }

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
    /// key is always saved under the address it is for.
    var showsKeyField: Bool { takesKey && profile != nil }
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
        case .noKey: return AgentText.stateNoKey
        case .wrongKey: return AgentText.stateWrongKey
        case .cantReach: return AgentText.stateCantReach(destinationName)
        case .notRunning: return provider == .lmStudio ? AgentText.failLMStudioNotRunning : AgentText.failOllamaNotRunning
        case .noModels: return AgentText.stateNoModels(destinationName)
        case .keyDenied: return AgentText.failKeyDenied
        }
    }
    /// The state line has Try Again beside it.
    var offersTryAgain: Bool {
        switch connection {
        case .cantReach, .notRunning, .keyDenied: return true
        case .none, .checking, .connected, .noKey, .wrongKey, .noModels: return false
        }
    }
    var isConnected: Bool { if case .connected = connection { return true } else { return false } }
    /// The models the menu offers: the provider's list, with the chosen one first if the list doesn't have it.
    var modelChoices: [String] {
        let listed = models.map(\.id)
        guard let model, !listed.contains(model) else { return listed }
        return [model] + listed
    }

    // MARK: What the person does

    public func setOn(_ on: Bool) {
        if on { keepProvider() }
        guard settings.snapshot.bool(.aiModeEnabled) != on else { return }
        settings.set(.bool(on), for: .aiModeEnabled)
    }

    /// A local provider, or one with a saved key, is checked at once.
    public func choose(_ provider: AgentProviderID) {
        services.config.update { $0.provider = provider.rawValue }
        if self.provider != provider { show(provider) }
        if isLocal || (takesKey && hasSavedKey) { check() } else { stopChecking() }
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
        if isOn, connection == .none, isLocal || hasSavedKey || provider == .other {
            check()
            await settle()
        }
        let leaves = !isOn || isConnected
        if leaves { markSeen() }
        return leaves
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
        case AgentText.done:
            guard let donePressed else { return false }
            donePressed(nil)
        default:
            guard isOn, let id = AgentProviderID.allCases.first(where: { AgentProviderCatalog.name($0) == title }) else { return false }
            choose(id)
        }
        return true
    }

    /// "none", "checking", "connected", "noKey", "wrongKey", "cantReach", "notRunning", "noModels" or "keyDenied".
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
        }
    }

    /// Every line of words the AI mode screen shows now, top to bottom.
    public var linesForTesting: [String] {
        var lines = [AgentText.aiTitle, AgentText.aiSentence]
        guard isOn else { return lines }
        lines.append(consentLine)
        if let addressProblem { lines.append(addressProblem) }
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

    /// How the provider stands before anything has been asked: a cloud provider with no key has none, which needs
    /// no question to know.
    private var restingConnection: Connection {
        guard isOn else { return .none }
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
        case .connected(let listed):
            models = listed
            connection = .connected(listed.count)
            // A provider with no first choice of its own runs the first model it lists until another is picked.
            if model == nil, let first = listed.first { chooseModel(first.id) }
        case .noKey: models = []; connection = .noKey
        case .wrongKey: models = []; connection = .wrongKey
        case .cantReach: models = []; connection = .cantReach
        case .notRunning: models = []; connection = .notRunning
        case .noModels: models = []; connection = .noModels
        case .keyDenied: models = []; connection = .keyDenied
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
        stopChecking()
        models = []
        connection = restingConnection
    }

    private func configChanged(_ config: AIConfig) {
        if let saved = config.provider.flatMap(AgentProviderID.init(rawValue:)), saved != provider { show(saved) }
        let chosen = Self.model(for: provider, in: config)
        if chosen != model { model = chosen }
    }

    /// Shows another provider, with nothing asked yet.
    private func show(_ next: AgentProviderID) {
        stopChecking()
        provider = next
        models = []
        addressProblem = nil
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
