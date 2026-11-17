import Foundation
import HelmCore

/// What a conversation is made from. The client is asked for each time it is needed, so a conversation never holds
/// one past AI mode turning off or the provider changing.
public struct AgentSessionParts: Sendable {
    public var client: @Sendable () async -> Result<any AgentModelClient, AgentFailure>
    public var disk: any AgentDisk
    public var home: String, supportFolder: String
    public var clock: any HelmClock
    /// How long a listing may go without progress, in place of the usual limits. Nil except in a fixture run that
    /// asks for short waits.
    public var listSecondsOverride: @Sendable () -> Double?
    /// The disks mounted now, as paths, for Whole Mac. Each goes through the folder rules like any other folder. None
    /// by default, and none in a fixture run, so a test never reaches a real disk.
    public var mountedVolumes: @Sendable () async -> [String]
    /// What reads inside files on this Mac, for a thread with Read contents on. It lives where files may be opened,
    /// and answers only summaries. Nil reads nothing, and the switch then offers no tool.
    public var contents: (any AgentContentReading)?
    public init(client: @escaping @Sendable () async -> Result<any AgentModelClient, AgentFailure>,
                disk: any AgentDisk, home: String, supportFolder: String, clock: any HelmClock,
                listSecondsOverride: @escaping @Sendable () -> Double? = { nil },
                mountedVolumes: @escaping @Sendable () async -> [String] = { [] },
                contents: (any AgentContentReading)? = nil) {
        self.client = client; self.disk = disk; self.home = home; self.supportFolder = supportFolder
        self.clock = clock; self.listSecondsOverride = listSecondsOverride; self.mountedVolumes = mountedVolumes
        self.contents = contents
    }
}

/// What the runtime is made from. A fixture run gives a scripted client and no way to make a live one, so nothing
/// it does can reach a provider.
public struct AgentRuntimeParts: Sendable {
    public var secrets: any AgentSecretStoring
    public var disk: any AgentDisk
    public var home: String, supportFolder: String
    public var clock: any HelmClock
    /// Tells one build of Helm from another: the app's own size and modification date as text. It names no path.
    public var buildStamp: String
    /// A client that always answers from a script. When set, no live client is ever built.
    public var scripted: (any AgentModelClient)?
    /// Makes the client for a provider, a model and the key store. Nil in a fixture run.
    public var makeClient: (@Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient)?
    /// Makes a conversation. Nil gives a stand-in that answers without a model.
    public var makeSession: (@Sendable (AgentSessionParts) -> any AgentConversing)?
    /// Makes a ChatGPT sign-in over the key store. Nil in a fixture run, which never signs in.
    public var makeSignIn: (@Sendable (any AgentSecretStoring) -> AgentChatGPTSignIn)?
    /// The disks mounted now, as paths, for Whole Mac. None by default, and none in a fixture run.
    public var mountedVolumes: @Sendable () async -> [String]
    /// What reads inside files on this Mac while a thread's Read contents switch is on. Nil reads nothing.
    public var contents: (any AgentContentReading)?
    public init(secrets: any AgentSecretStoring, disk: any AgentDisk, home: String, supportFolder: String,
                clock: any HelmClock, buildStamp: String, scripted: (any AgentModelClient)? = nil,
                makeClient: (@Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient)? = nil,
                makeSession: (@Sendable (AgentSessionParts) -> any AgentConversing)? = nil,
                makeSignIn: (@Sendable (any AgentSecretStoring) -> AgentChatGPTSignIn)? = nil,
                mountedVolumes: @escaping @Sendable () async -> [String] = { [] },
                contents: (any AgentContentReading)? = nil) {
        self.secrets = secrets; self.disk = disk; self.home = home; self.supportFolder = supportFolder
        self.clock = clock; self.buildStamp = buildStamp; self.scripted = scripted
        self.makeClient = makeClient; self.makeSession = makeSession; self.makeSignIn = makeSignIn
        self.mountedVolumes = mountedVolumes; self.contents = contents
    }
}

/// Whether AI mode can be used right now.
public enum AgentRuntimeState: Equatable, Sendable {
    case off
    /// On, but there is no provider, no model, or no key for a provider that needs one.
    case notReady
    case ready(provider: String, destination: String, model: String, isLocal: Bool)
}

/// What asking a provider for its models came to. `planLimit` and `planNotCovered` come only from OpenAI with a
/// ChatGPT sign-in: the plan's usage limit was reached, or the plan doesn't cover Helm's requests.
public enum AgentConnection: Equatable, Sendable {
    case connected([AgentModelInfo]), noKey, wrongKey, cantReach, notRunning, noModels, keyDenied, off, planLimit, planNotCovered
}

/// AI mode's switch. It holds whether the mode is on, which provider and model are chosen, and the one client that
/// talks to that provider. The client is built the first time it is needed and only while the mode is on: while it
/// is off there is no client, no conversation and no cached key, so nothing can be sent.
@MainActor public final class AgentRuntime {
    private let parts: AgentRuntimeParts
    private var liveClient: (any AgentLiveClient)?
    /// Clients made for checking a draft config, while their check is out. Turning AI mode off shuts them down too.
    private var probes: [UUID: any AgentLiveClient] = [:]
    private var sessions: [WeakSession] = []
    private var announced: AgentRuntimeState = .off
    private let overrides = Overrides()
    /// The last piece of work set going without being waited for. Each piece runs after the one before it.
    private var tail: Task<Void, Never>?

    /// Starts off, with an empty config.
    public init(parts: AgentRuntimeParts) { self.parts = parts }

    public private(set) var isOn = false
    public private(set) var config = AIConfig()

    /// With a scripted client the state is `.ready` as soon as AI mode is on, whatever the config and the key
    /// store hold. Otherwise it is ready when a client could be made: a provider with an address, a model, and a key
    /// where the provider needs one.
    public var state: AgentRuntimeState {
        guard isOn else { return .off }
        if let scripted = parts.scripted {
            return .ready(provider: scripted.providerName, destination: scripted.destination,
                          model: AgentProviderCatalog.model(for: config) ?? Self.scriptedModel, isLocal: scripted.isLocal)
        }
        guard parts.makeClient != nil, let profile = Self.profile(for: config),
              let model = AgentProviderCatalog.model(for: config), hasCredential(profile) else { return .notReady }
        return .ready(provider: profile.name, destination: profile.destination, model: model, isLocal: profile.isLocal)
    }

    /// Sent whenever the state changes, and never for a change that leaves it the same.
    public let changes = Broadcast<AgentRuntimeState>()

    /// Told how every check of a provider came out: the provider and where it was asked, and the models it listed,
    /// or nil when it answered with none or not at all. The app keeps the lists, so the panel's model menu can offer
    /// them without asking again. Never told anything while AI mode is off, and never anything but model names.
    public var checked: (@MainActor (AgentProviderProfile, [AgentModelInfo]?) -> Void)?

    /// Turns AI mode on or off. Off shuts the client down, and any client out for a check, which forgets the key
    /// they had cached, and stops and clears every conversation the runtime made. Those conversations stay on the
    /// runtime's list while something holds them, so a later change of provider or a later off still reaches them.
    public func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if !on {
            dropClient()
            let out = Array(probes.values)
            probes.removeAll()
            for probe in out { probe.refuseRequests() }
            let held = openSessions()
            later {
                for probe in out { await probe.shutdown() }
                for session in held { await session.stop(); await session.clear() }
            }
        }
        announce()
    }

    /// Takes a new config. When the provider, a local provider's port or a typed address changes, the client is
    /// dropped and every conversation starts over, so names listed for one provider are never sent to another.
    /// When only the model changes, or a key was saved or removed, the client is dropped and the threads are kept.
    public func configure(_ config: AIConfig) {
        let old = self.config
        self.config = config
        let movedAway = config.provider != old.provider || Self.profile(for: config) != Self.profile(for: old)
        if movedAway || AgentProviderCatalog.model(for: config) != AgentProviderCatalog.model(for: old)
            || config.keyOwners != old.keyOwners {
            dropClient()
        }
        if movedAway {
            let held = openSessions()
            later { for session in held { await session.startOver() } }
        }
        announce()
    }

    /// The client for the chosen provider and model, built on first use. While AI mode is off the answer is
    /// `.off` and nothing is built; with no provider, address or model it is `.notReady`; with no key for a
    /// provider that needs one it is `.noKey`.
    public func client() -> Result<any AgentModelClient, AgentFailure> {
        guard isOn else { return .failure(.off) }
        if let scripted = parts.scripted { return .success(scripted) }
        if let liveClient { return .success(liveClient) }
        guard let profile = Self.profile(for: config), let model = AgentProviderCatalog.model(for: config) else {
            return .failure(.notReady)
        }
        if !hasCredential(profile) { return .failure(.noKey) }
        guard let makeClient = parts.makeClient else { return .failure(.notReady) }
        let built = makeClient(profile, model, parts.secrets)
        clientBuildCount += 1
        liveClient = built
        return .success(built)
    }

    /// Asks the provider a draft config names for its models, which is also how a connection is checked. The
    /// request goes the way every request does. The config in use is checked through its client made again, so a
    /// key saved since, even under the same account, is the one used from then on. A draft that differs from the
    /// config in use gets a client of its own, which is shut down when the answer is in, or when AI mode turns off
    /// first. While AI mode is off the answer is `.off` and nothing is asked.
    public func check(_ draft: AIConfig) async -> AgentConnection {
        guard isOn else { return .off }
        let answer: AgentConnection
        if let scripted = parts.scripted {
            answer = await Self.connection(through: scripted)
        } else {
            guard let profile = Self.profile(for: draft) else { return .cantReach }
            if !hasCredential(profile) {
                announce()
                report(.noKey, for: profile)
                return .noKey
            }
            let model = AgentProviderCatalog.model(for: draft)
            let inUse = profile == Self.profile(for: config) && model == AgentProviderCatalog.model(for: config)
            if inUse { dropClient() }
            if inUse, case .success(let current) = client() {
                answer = await Self.connection(through: current, chatGPT: profile.usesChatGPT)
            } else {
                guard let makeClient = parts.makeClient else { return .cantReach }
                let probe = makeClient(profile, model ?? "", parts.secrets)
                clientBuildCount += 1
                let id = UUID()
                probes[id] = probe
                answer = await Self.connection(through: probe, chatGPT: profile.usesChatGPT)
                // Turning AI mode off meanwhile has already shut it down.
                if probes.removeValue(forKey: id) != nil { await probe.shutdown() }
            }
        }
        // A key may have been saved since the state was last worked out.
        announce()
        guard isOn else { return .off }
        if let profile = Self.profile(for: draft) { report(answer, for: profile) }
        return answer
    }

    /// Asks Ollama or LM Studio, as a draft config names it, for its models again, through a client of its own that
    /// is shut down once it has answered, so the client in use and any request under way are left alone. Only a
    /// provider on this Mac is asked this way; a cloud provider is asked only when the person checks it. The answer
    /// goes to `checked` as a check's does. While AI mode is off, or for any other provider, nothing is asked.
    @discardableResult public func relistLocal(_ draft: AIConfig) async -> AgentConnection {
        guard isOn, let profile = Self.profile(for: draft), profile.isLocal else { return .off }
        let answer: AgentConnection
        if let scripted = parts.scripted {
            answer = await Self.connection(through: scripted)
        } else {
            guard let makeClient = parts.makeClient else { return .cantReach }
            let probe = makeClient(profile, AgentProviderCatalog.model(for: draft) ?? "", parts.secrets)
            clientBuildCount += 1
            let id = UUID()
            probes[id] = probe
            answer = await Self.connection(through: probe)
            // Turning AI mode off meanwhile has already shut it down.
            if probes.removeValue(forKey: id) != nil { await probe.shutdown() }
        }
        guard isOn else { return .off }
        report(answer, for: profile)
        return answer
    }

    /// A new conversation. Nil unless the state is `.ready`. The runtime keeps hold of what it made only weakly, to
    /// stop and clear it when AI mode turns off and to start it over when the provider changes.
    public func makeSession() -> (any AgentConversing)? {
        guard case .ready = state else { return nil }
        let overrides = self.overrides
        let sessionParts = AgentSessionParts(
            client: { [weak self] in await self?.client() ?? .failure(.off) },
            disk: parts.disk, home: parts.home, supportFolder: parts.supportFolder, clock: parts.clock,
            listSecondsOverride: { overrides.listSeconds }, mountedVolumes: parts.mountedVolumes, contents: parts.contents)
        let session = parts.makeSession?(sessionParts) ?? StandInConversation()
        sessions.removeAll { $0.session == nil }
        sessions.append(WeakSession(session))
        return session
    }

    // MARK: ChatGPT sign-in

    /// A ChatGPT sign-in, while AI mode is on in a run that can sign in. Nil otherwise: a fixture run never signs in,
    /// and nothing reaches OpenAI's sign-in host while AI mode is off.
    public func chatGPTSignIn() -> AgentChatGPTSignIn? {
        guard isOn, let makeSignIn = parts.makeSignIn else { return nil }
        return makeSignIn(parts.secrets)
    }

    /// The ChatGPT sign-in was made or removed: the client lets go of the tokens it held, and the state is worked out
    /// again.
    public func chatGPTSignInChanged() {
        dropClient()
        announce()
    }

    /// Signs out of ChatGPT: the tokens are removed from the keychain, and while AI mode is on in a run that can sign
    /// in, the refresh token is revoked at OpenAI first. Answers whether OpenAI confirmed the revocation.
    public func signOutOfChatGPT() async -> Bool {
        dropClient()
        let confirmed: Bool
        if let signIn = chatGPTSignIn() {
            confirmed = await signIn.signOut()
        } else {
            let had = parts.secrets.hasSignIn(.chatGPTTokens)
            try? parts.secrets.removeSignIn(.chatGPTTokens)
            confirmed = !had
        }
        announce()
        return confirmed
    }

    /// Whether this run can read inside files at all. The Read contents switches show only when it can.
    public var canReadContents: Bool { parts.contents != nil }

    /// How many live clients were built since launch. A fixture run stays at 0.
    public private(set) var clientBuildCount = 0

    /// Seconds a listing may go without progress, in place of the usual limits. A fixture run sets it so that a
    /// slow place fails fast. Conversations ask for it at each listing.
    public var listSecondsOverrideForTesting: Double? {
        get { overrides.listSeconds }
        set { overrides.listSeconds = newValue }
    }

    /// The scripted client, when the runtime was given one.
    public var scriptedClientForTesting: ScriptedModelClient? { parts.scripted as? ScriptedModelClient }

    /// Waits until what `setOn` and `configure` set going has finished: the client's shutdown and the calls to
    /// each conversation.
    func settle() async { await tail?.value }

    // MARK: Parts

    /// The model a scripted client is said to run when the config names none.
    private static let scriptedModel = "scripted-1"

    private static func profile(for config: AIConfig) -> AgentProviderProfile? {
        try? AgentProviderCatalog.profile(for: config).get()
    }

    /// What a profile needs before a request can go: its key, or its ChatGPT sign-in, asked of the store without
    /// asking for either.
    private func hasCredential(_ profile: AgentProviderProfile) -> Bool {
        if profile.usesChatGPT { return parts.secrets.hasSignIn(.chatGPTTokens) }
        return !profile.needsKey || parts.secrets.has(profile.secretID)
    }

    private static func connection(through client: any AgentModelClient, chatGPT: Bool = false) async -> AgentConnection {
        do {
            let models = try await client.models()
            return models.isEmpty ? .noModels : .connected(Array(models.prefix(AgentModelInfo.listCap)))
        } catch let failure as AgentFailure {
            if chatGPT, failure == .outOfCredit { return .planLimit }
            if chatGPT, failure == .noSuchModel { return .planNotCovered }
            switch failure {
            case .off: return .off
            case .noKey: return .noKey
            case .keyDenied: return .keyDenied
            case .wrongKey: return .wrongKey
            case .notRunning: return .notRunning
            case .notReady, .outOfCredit, .rateLimited, .overloaded, .noSuchModel, .noTools, .badRequest, .tooLarge,
                 .unreachable, .timedOut, .unreadable, .cancelled, .declined:
                return .cantReach
            }
        } catch {
            return .cantReach
        }
    }

    /// Tells `checked` how a check of `profile` came out. AI mode turning off meanwhile says nothing about it.
    private func report(_ answer: AgentConnection, for profile: AgentProviderProfile) {
        switch answer {
        case .connected(let models): checked?(profile, models)
        case .off: break
        default: checked?(profile, nil)
        }
    }

    private func announce() {
        let now = state
        guard now != announced else { return }
        announced = now
        changes.send(now)
    }

    /// The client is let go at once: a caller that still holds it, such as a conversation between two turns, finds
    /// every request turned away. The rest of its shutdown waits its turn.
    private func dropClient() {
        guard let client = liveClient else { return }
        liveClient = nil
        client.refuseRequests()
        later { await client.shutdown() }
    }

    private func openSessions() -> [any AgentConversing] {
        sessions.removeAll { $0.session == nil }
        return sessions.compactMap(\.session)
    }

    /// Sets going work that the caller doesn't wait for, after any that was set going before it.
    private func later(_ work: @escaping @Sendable () async -> Void) {
        let before = tail
        tail = Task {
            await before?.value
            await work()
        }
    }

    private final class WeakSession {
        weak var session: (any AgentConversing)?
        init(_ session: any AgentConversing) { self.session = session }
    }

    /// What a fixture run may change about the limits. Conversations read it from their own threads, so it is
    /// behind a lock.
    private final class Overrides: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double?
        var listSeconds: Double? {
            get { lock.lock(); defer { lock.unlock() }; return seconds }
            set { lock.lock(); defer { lock.unlock() }; seconds = newValue }
        }
    }
}
