import Foundation

/// Keys and sign-ins kept in memory, for tests and fixture runs. Nothing is saved anywhere, and every key is gone when
/// the app quits. A key goes in and comes out as the same hidden value: this file never looks inside one.
/// All reads and writes hold the lock.
public final class MemorySecretStore: AgentSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: AgentSecret] = [:]
    private var signIns: [AgentSignInItem: (data: Data, note: String?)] = [:]
    private var refuses = false

    public init() {}

    /// While true, asking for a key throws `.denied`, as when the person refuses macOS's question. `has` still
    /// answers, since it never asks for the key itself.
    public var denies: Bool {
        get { locked { refuses } }
        set { locked { refuses = newValue } }
    }

    /// The accounts that hold a key, in order. A sign-in's items are kept apart and aren't among them.
    public var accounts: [String] { locked { secrets.keys.sorted() } }

    /// The sign-in items saved, in order.
    public var signInItems: [AgentSignInItem] { locked { AgentSignInItem.allCases.filter { signIns[$0] != nil } } }

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

    public func hasSignIn(_ item: AgentSignInItem) -> Bool { locked { signIns[item] != nil } }

    public func signInData(_ item: AgentSignInItem) throws -> Data? {
        try locked {
            if refuses { throw AgentSecretError.denied }
            return signIns[item]?.data
        }
    }

    public func saveSignIn(_ data: Data, note: String?, for item: AgentSignInItem) throws {
        locked { signIns[item] = (data, note) }
    }

    public func removeSignIn(_ item: AgentSignInItem) throws {
        locked { signIns[item] = nil }
    }

    public func signInNote(_ item: AgentSignInItem) -> String? { locked { signIns[item]?.note } }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
