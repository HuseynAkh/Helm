import Foundation
import Security

/// Keys kept in the login keychain: one generic password per provider, host and port.
///
/// The item is found by its service and its account, and the account names the provider, the host and the port, so
/// a key saved for one address is never found for another. No attribute that would move the item to the data
/// protection keychain, share it with other apps or sync it to other devices is ever set: the login keychain needs
/// none, and an ad hoc signed app can't use those.
///
/// Every call here can block while macOS asks the person for their keychain password, so callers stay off the main
/// thread. `has` asks for the item's attributes only, which never brings that question up.
///
/// This is the only file in Helm that names a keychain call. Tests and fixture runs use `MemorySecretStore`.
public struct KeychainSecretStore: AgentSecretStoring {
    public static let service = "com.helm.filemanager.ai-key"
    public static let label = "Helm AI key"

    public init() {}

    public func has(_ id: AgentSecretID) -> Bool {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(Self.presenceQuery(id) as CFDictionary, &found)
        switch Self.outcome(of: status) {
        case .found, .denied: return true
        case .missing, .failed: return false
        }
    }

    public func secret(for id: AgentSecretID) throws -> AgentSecret? {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(Self.secretQuery(id) as CFDictionary, &found)
        switch Self.outcome(of: status) {
        case .found:
            // A saved item that isn't a key Helm could have saved is treated as broken, so the person enters it again.
            guard let data = found as? Data, let text = String(data: data, encoding: .utf8),
                  let secret = AgentSecret(pasted: text) else { throw AgentSecretError.failed }
            return secret
        case .missing: return nil
        case .denied: throw AgentSecretError.denied
        case .failed: throw AgentSecretError.failed
        }
    }

    /// Deletes any saved item for `id`, then adds the new one. Deleting first means saving never asks the person
    /// anything, and the build that saves an item is the one macOS lets read it.
    public func save(_ secret: AgentSecret, for id: AgentSecretID) throws {
        try deleteItem(id)
        let status = SecItemAdd(Self.addQuery(secret, for: id) as CFDictionary, nil)
        switch Self.outcome(of: status) {
        case .found: return
        case .denied: throw AgentSecretError.denied
        case .missing, .failed: throw AgentSecretError.failed
        }
    }

    /// Removing a key that isn't there is not an error.
    public func remove(_ id: AgentSecretID) throws {
        try deleteItem(id)
    }

    public var isMemoryOnly: Bool { false }

    private func deleteItem(_ id: AgentSecretID) throws {
        let status = SecItemDelete(Self.itemQuery(id) as CFDictionary)
        switch Self.outcome(of: status) {
        case .found, .missing: return
        case .denied: throw AgentSecretError.denied
        case .failed: throw AgentSecretError.failed
        }
    }

    // MARK: Queries

    /// What a keychain call answered, in the terms a caller needs.
    enum Outcome: Equatable {
        case found, missing, denied, failed
    }

    /// Success is `found`; no such item is `missing`. The person refusing macOS's question, a wrong keychain password
    /// and a question that couldn't be shown are all `denied`: the key is still there, so it is never "no key".
    static func outcome(of status: OSStatus) -> Outcome {
        switch status {
        case errSecSuccess: return .found
        case errSecItemNotFound: return .missing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .denied
        default: return .failed
        }
    }

    /// The one item for `id`: its class, service and account, and nothing else. A query never leaves out the
    /// service and the account, so it can't match another app's items.
    static func itemQuery(_ id: AgentSecretID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.account]
    }

    /// Whether the item is there, from its attributes alone.
    static func presenceQuery(_ id: AgentSecretID) -> [String: Any] {
        var query = itemQuery(id)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// The saved key itself.
    static func secretQuery(_ id: AgentSecretID) -> [String: Any] {
        var query = itemQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// A new item: the key, and the label the person sees in Keychain Access. The label isn't part of the queries
    /// that find an item, so an item the person renamed is still found and replaced.
    static func addQuery(_ secret: AgentSecret, for id: AgentSecretID) -> [String: Any] {
        var query = itemQuery(id)
        query[kSecAttrLabel as String] = label
        query[kSecValueData as String] = Data(secret.revealSecret().utf8)
        return query
    }
}
