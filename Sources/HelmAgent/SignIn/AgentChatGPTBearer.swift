import Foundation

/// The ChatGPT sign-in's access token, for the transport to OpenAI's API.
///
/// The tokens are read from the keychain the first time a request needs them, off the main thread since macOS may ask
/// for the keychain password, and held until AI mode turns off. The access token is renewed two minutes before it runs
/// out, and again when OpenAI turns it away. OpenAI rotates the refresh token at each renewal, so renewals are made one
/// at a time across all of Helm, each starting from the newest saved tokens: two at once would spend the same refresh
/// token twice, and the second would end the sign-in. Every renewal is saved with the new refresh token before it is
/// used.
///
/// A refresh token OpenAI says can't be used again ends the sign-in: the tokens are removed and the person is asked to
/// sign in again. A network failure or a busy server keeps them.
public final class AgentChatGPTBearer: AgentBearerSource, @unchecked Sendable {
    private let store: any AgentSecretStoring
    private let transport: any AgentSignInTransport
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var held: AgentChatGPTTokens?
    private var forgotten = false

    /// Seconds before its end that an access token is renewed.
    static let renewMargin: TimeInterval = 120
    /// One renewal at a time, for every bearer Helm makes.
    static let gate = AgentSerialGate()

    public init(store: any AgentSecretStoring, transport: any AgentSignInTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.transport = transport; self.now = now
    }

    public func bearerToken() async throws -> AgentSecret {
        if let tokens = locked({ held }), !tokens.expires(within: Self.renewMargin, of: now()), let bearer = tokens.bearer {
            return bearer
        }
        return try await renewed(rejecting: nil)
    }

    public func renewedToken() async throws -> AgentSecret {
        try await renewed(rejecting: locked { held?.accessToken })
    }

    /// Lets go of the tokens and shuts the sign-in transport down. Nothing is renewed afterwards.
    public func forget() {
        let first = locked { () -> Bool in
            held = nil
            defer { forgotten = true }
            return !forgotten
        }
        guard first else { return }
        let transport = self.transport
        Task { await transport.shutdown() }
    }

    /// The newest saved tokens, renewed when they are about to run out or are the ones OpenAI turned away.
    private func renewed(rejecting rejected: String?) async throws -> AgentSecret {
        try await Self.gate.run { [self] in
            try ensureHeld()
            let saved = try await savedTokens()
            guard saved.allowsPlan else {
                end()
                throw AgentTransportError.noKey
            }
            if saved.accessToken != rejected, !saved.expires(within: Self.renewMargin, of: now()), let bearer = saved.bearer {
                try keep(saved)
                return bearer
            }
            let fresh = try await refresh(saved)
            try keep(fresh)
            guard let bearer = fresh.bearer else { throw AgentTransportError.noKey }
            return bearer
        }
    }

    /// The tokens in the keychain. No sign-in is `.noKey`; a refusal from macOS is `.keyDenied`.
    private func savedTokens() async throws -> AgentChatGPTTokens {
        let store = self.store
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard store.hasSignIn(.chatGPTTokens), let data = try store.signInData(.chatGPTTokens),
                          let tokens = AgentChatGPTTokens(data: data) else {
                        return continuation.resume(throwing: AgentTransportError.noKey)
                    }
                    continuation.resume(returning: tokens)
                } catch AgentSecretError.denied {
                    continuation.resume(throwing: AgentTransportError.keyDenied)
                } catch {
                    continuation.resume(throwing: AgentTransportError.noKey)
                }
            }
        }
    }

    /// A refresh at the token endpoint. The answer is saved, with the new refresh token, before it is handed on.
    private func refresh(_ tokens: AgentChatGPTTokens) async throws -> AgentChatGPTTokens {
        let reply: AgentHTTPReply
        do {
            reply = try await transport.post(.token, form: AgentChatGPTSignIn.refreshForm(tokens))
        } catch let failure as AgentTransportError where failure == .cancelled {
            throw failure
        } catch is CancellationError {
            throw AgentTransportError.cancelled
        } catch {
            throw AgentTransportError.unreachable
        }
        if (200...299).contains(reply.status), let answer = AgentTokenReply(data: reply.body) {
            let fresh = tokens.refreshed(by: answer, now: now())
            guard fresh.allowsPlan else {
                end()
                throw AgentTransportError.noKey
            }
            try? store.saveSignIn(fresh.encoded(), note: store.signInNote(.chatGPTTokens), for: .chatGPTTokens)
            return fresh
        }
        let code = AgentTokenReply.errorCode(in: reply.body)
        let ended = code.map { AgentTokenReply.endedCodes.contains($0) || $0 == "invalid_client" } ?? false
        if ended || reply.status == 400 || reply.status == 401 {
            end()
            throw AgentTransportError.noKey
        }
        throw AgentTransportError.unreachable
    }

    /// The sign-in can't be renewed: its tokens go, and the next request asks the person to sign in again.
    private func end() {
        locked { held = nil }
        try? store.removeSignIn(.chatGPTTokens)
    }

    private func keep(_ tokens: AgentChatGPTTokens) throws {
        try locked {
            if forgotten { throw AgentTransportError.cancelled }
            held = tokens
        }
    }

    private func ensureHeld() throws {
        try locked { if forgotten { throw AgentTransportError.cancelled } }
    }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Runs one piece of work at a time, in the order they arrive.
actor AgentSerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<Value: Sendable>(_ work: @Sendable () async throws -> Value) async throws -> Value {
        await enter()
        defer { leave() }
        return try await work()
    }

    private func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
