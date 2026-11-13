import Foundation

/// Keys kept in memory, for tests and fixture runs. Nothing is saved anywhere, and every key is gone when the app
/// quits. A key goes in and comes out as the same hidden value: this file never looks inside one.
/// All reads and writes hold the lock.
public final class MemorySecretStore: AgentSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: AgentSecret] = [:]
    private var refuses = false

    public init() {}

    /// While true, asking for a key throws `.denied`, as when the person refuses macOS's question. `has` still
    /// answers, since it never asks for the key itself.
    public var denies: Bool {
        get { locked { refuses } }
        set { locked { refuses = newValue } }
    }

    /// The accounts that hold a key, in order.
    public var accounts: [String] { locked { secrets.keys.sorted() } }

    public func has(_ id: AgentSecretID) -> Bool { locked { secrets[id.account] != nil } }

    public func secret(for id: AgentSecretID) throws -> AgentSecret? {
        try locked {
            if refuses { throw AgentSecretError.denied }
            return secrets[id.account]
        }
    }

    public func save(_ secret: AgentSecret, for id: AgentSecretID) throws {
        locked { secrets[id.account] = secret }
    }

    public func remove(_ id: AgentSecretID) throws {
        locked { secrets[id.account] = nil }
    }

    public var isMemoryOnly: Bool { true }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
