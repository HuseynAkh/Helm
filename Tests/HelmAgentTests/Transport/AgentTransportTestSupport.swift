import Foundation
@testable import HelmAgent

/// A key store that counts how often it is asked, around a memory store.
final class AgentCountingSecretStore: AgentSecretStoring, @unchecked Sendable {
    let inner = MemorySecretStore()
    private let lock = NSLock()
    private var presence = 0
    private var reads = 0

    var presenceAsks: Int { lock.lock(); defer { lock.unlock() }; return presence }
    var secretAsks: Int { lock.lock(); defer { lock.unlock() }; return reads }

    func has(_ id: AgentSecretID) -> Bool {
        lock.lock(); presence += 1; lock.unlock()
        return inner.has(id)
    }

    func secret(for id: AgentSecretID) throws -> AgentSecret? {
        lock.lock(); reads += 1; lock.unlock()
        return try inner.secret(for: id)
    }

    func save(_ secret: AgentSecret, for id: AgentSecretID) throws { try inner.save(secret, for: id) }
    func remove(_ id: AgentSecretID) throws { try inner.remove(id) }
    var isMemoryOnly: Bool { true }
}

/// Lines and the error a stream ended with, if any.
struct AgentStreamOutcome {
    var lines: [String] = []
    var failure: AgentTransportError?
    var otherError: Error?
}

enum AgentTransportTesting {
    /// Made-up keys. Each holds a word the key scan reads as made up.
    static let key = "fake-key-for-tests-0001"
    static let keyWithSlash = "fake/key/for/tests/0002"

    static func secret(_ text: String = key) -> AgentSecret {
        guard let secret = AgentSecret(pasted: text) else { preconditionFailure("a test key must be valid") }
        return secret
    }

    /// Room for any test that isn't about a limit, and no second tries.
    static let roomy = AgentTransportLimits(idleSeconds: 20, totalSeconds: 60, lineBytes: 4_000_000,
                                            responseBytes: 32_000_000, listBytes: 4_000_000, retries: 0)

    static func limits(idle: Double = 20, total: Double = 60, line: Int = 4_000_000, response: Int = 32_000_000,
                       list: Int = 4_000_000, retries: Int = 0) -> AgentTransportLimits {
        AgentTransportLimits(idleSeconds: idle, totalSeconds: total, lineBytes: line, responseBytes: response,
                             listBytes: list, retries: retries)
    }

    static func claude() throws -> AgentProviderProfile {
        AgentProviderProfile(id: .claude, endpoint: try AgentEndpoint(fixed: .claude))
    }
    static func gemini() throws -> AgentProviderProfile {
        AgentProviderProfile(id: .gemini, endpoint: try AgentEndpoint(fixed: .gemini))
    }
    static func openAI() throws -> AgentProviderProfile {
        AgentProviderProfile(id: .openAI, endpoint: try AgentEndpoint(fixed: .openAI))
    }
    static func other(_ address: String = "models.example.com") throws -> AgentProviderProfile {
        AgentProviderProfile(id: .other, endpoint: try AgentEndpoint(typed: address))
    }
    static func ollama(port: Int = 11434) throws -> AgentProviderProfile {
        AgentProviderProfile(id: .ollama, endpoint: try AgentEndpoint(localPort: port))
    }
    static func lmStudio(port: Int = 1234) throws -> AgentProviderProfile {
        AgentProviderProfile(id: .lmStudio, endpoint: try AgentEndpoint(localPort: port))
    }

    /// Reads a stream to its end.
    static func drain(_ stream: AsyncThrowingStream<String, Error>) async -> AgentStreamOutcome {
        var outcome = AgentStreamOutcome()
        do {
            for try await line in stream { outcome.lines.append(line) }
        } catch let failure as AgentTransportError {
            outcome.failure = failure
        } catch {
            outcome.otherError = error
        }
        return outcome
    }

    static func data(_ text: String) -> Data { Data(text.utf8) }
}
