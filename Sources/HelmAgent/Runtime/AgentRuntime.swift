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
    public init(client: @escaping @Sendable () async -> Result<any AgentModelClient, AgentFailure>,
                disk: any AgentDisk, home: String, supportFolder: String, clock: any HelmClock,
                listSecondsOverride: @escaping @Sendable () -> Double? = { nil }) {
        self.client = client; self.disk = disk; self.home = home; self.supportFolder = supportFolder
        self.clock = clock; self.listSecondsOverride = listSecondsOverride
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
    public init(secrets: any AgentSecretStoring, disk: any AgentDisk, home: String, supportFolder: String,
                clock: any HelmClock, buildStamp: String, scripted: (any AgentModelClient)? = nil,
                makeClient: (@Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient)? = nil,
                makeSession: (@Sendable (AgentSessionParts) -> any AgentConversing)? = nil) {
        self.secrets = secrets; self.disk = disk; self.home = home; self.supportFolder = supportFolder
        self.clock = clock; self.buildStamp = buildStamp; self.scripted = scripted
        self.makeClient = makeClient; self.makeSession = makeSession
    }
}

/// Whether AI mode can be used right now.
public enum AgentRuntimeState: Equatable, Sendable {
    case off
    /// On, but there is no provider, no model, or no key for a provider that needs one.
    case notReady
    case ready(provider: String, destination: String, model: String, isLocal: Bool)
}

/// What asking a provider for its models came to.
public enum AgentConnection: Equatable, Sendable { case connected([AgentModelInfo]), noKey, wrongKey, cantReach, notRunning, noModels, keyDenied, off }

/// AI mode's switch. It holds whether the mode is on, which provider and model are chosen, and the one client that
/// talks to that provider. The client is built the first time it is needed and only while the mode is on: while it
/// is off there is no client, no conversation and no cached key, so nothing can be sent.
@MainActor public final class AgentRuntime {
    private let parts: AgentRuntimeParts
    private var liveClient: (any AgentLiveClient)?
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
              let model = AgentProviderCatalog.model(for: config),
              !profile.needsKey || parts.secrets.has(profile.secretID) else { return .notReady }
        return .ready(provider: profile.name, destination: profile.destination, model: model, isLocal: profile.isLocal)
    }

    /// Sent whenever the state changes, and never for a change that leaves it the same.
    public let changes = Broadcast<AgentRuntimeState>()

    /// Turns AI mode on or off. Off shuts the client down, which forgets the key it had cached, and stops and
    /// clears every conversation the runtime made. Those conversations are let go of: a new one is made after the
    /// mode is turned on again.
    public func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if !on {
            dropClient()
            let open = openSessions()
            sessions.removeAll()
            later { for session in open { await session.stop(); await session.clear() } }
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
            let open = openSessions()
            later { for session in open { await session.startOver() } }
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
        if profile.needsKey, !parts.secrets.has(profile.secretID) { return .failure(.noKey) }
        guard let makeClient = parts.makeClient else { return .failure(.notReady) }
        let built = makeClient(profile, model, parts.secrets)
        clientBuildCount += 1
        liveClient = built
        return .success(built)
    }

    /// Asks the provider a draft config names for its models, which is also how a connection is checked. The
    /// request goes the way every request does. A draft that differs from the config in use gets a client of its
    /// own, which is shut down when the answer is in. While AI mode is off the answer is `.off` and nothing is asked.
    public func check(_ draft: AIConfig) async -> AgentConnection {
        guard isOn else { return .off }
        let answer: AgentConnection
        if let scripted = parts.scripted {
            answer = await Self.connection(through: scripted)
        } else {
            guard let profile = Self.profile(for: draft) else { return .cantReach }
            if profile.needsKey, !parts.secrets.has(profile.secretID) {
                announce()
                return .noKey
            }
            let model = AgentProviderCatalog.model(for: draft)
            if profile == Self.profile(for: config), model == AgentProviderCatalog.model(for: config),
               case .success(let current) = client() {
                answer = await Self.connection(through: current)
            } else {
                guard let makeClient = parts.makeClient else { return .cantReach }
                let probe = makeClient(profile, model ?? "", parts.secrets)
                clientBuildCount += 1
                answer = await Self.connection(through: probe)
                await probe.shutdown()
            }
        }
        // A key may have been saved since the state was last worked out.
        announce()
        return isOn ? answer : .off
    }

    /// A new conversation. Nil unless the state is `.ready`. The runtime keeps hold of what it made only weakly, to
    /// stop and clear it when AI mode turns off and to start it over when the provider changes.
    public func makeSession() -> (any AgentConversing)? {
        guard case .ready = state else { return nil }
        let overrides = self.overrides
        let sessionParts = AgentSessionParts(
            client: { [weak self] in await self?.client() ?? .failure(.off) },
            disk: parts.disk, home: parts.home, supportFolder: parts.supportFolder, clock: parts.clock,
            listSecondsOverride: { overrides.listSeconds })
        let session = parts.makeSession?(sessionParts) ?? StandInConversation()
        sessions.removeAll { $0.session == nil }
        sessions.append(WeakSession(session))
        return session
    }

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

    private static func connection(through client: any AgentModelClient) async -> AgentConnection {
        do {
            let models = try await client.models()
            return models.isEmpty ? .noModels : .connected(Array(models.prefix(AgentModelInfo.listCap)))
        } catch let failure as AgentFailure {
            switch failure {
            case .off: return .off
            case .noKey: return .noKey
            case .keyDenied: return .keyDenied
            case .wrongKey: return .wrongKey
            case .notRunning: return .notRunning
            case .notReady, .outOfCredit, .rateLimited, .overloaded, .noSuchModel, .noTools, .badRequest, .tooLarge,
                 .unreachable, .timedOut, .unreadable, .cancelled:
                return .cantReach
            }
        } catch {
            return .cantReach
        }
    }

    private func announce() {
        let now = state
        guard now != announced else { return }
        announced = now
        changes.send(now)
    }

    private func dropClient() {
        guard let client = liveClient else { return }
        liveClient = nil
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
