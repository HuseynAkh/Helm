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
/// A ChatGPT sign-in is kept the same way, in two items of its own under the same service: the registration, and the
/// tokens with the account's email as the item's comment, so Settings can say who is signed in without asking macOS
/// for the item itself.
///
/// This is the only file in Helm that names a keychain call, or any other call of the Security framework: the
/// signature check of a sign-in's ID token, `AgentTokenSignature`, is at the end. Tests and fixture runs use
/// `MemorySecretStore`.
public struct KeychainSecretStore: AgentSecretStoring {
    public static let service = "com.helm.filemanager.ai-key"
    public static let label = "Helm AI key"
    public static let signInLabel = "Helm ChatGPT sign-in"

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
        try deleteItem(account: id.account)
    }

    private func deleteItem(account: String) throws {
        let status = SecItemDelete(Self.itemQuery(account: account) as CFDictionary)
        switch Self.outcome(of: status) {
        case .found, .missing: return
        case .denied: throw AgentSecretError.denied
        case .failed: throw AgentSecretError.failed
        }
    }

    // MARK: Sign-in items

    public func hasSignIn(_ item: AgentSignInItem) -> Bool {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(Self.presenceQuery(account: item.account) as CFDictionary, &found)
        switch Self.outcome(of: status) {
        case .found, .denied: return true
        case .missing, .failed: return false
        }
    }

    public func signInData(_ item: AgentSignInItem) throws -> Data? {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(Self.dataQuery(account: item.account) as CFDictionary, &found)
        switch Self.outcome(of: status) {
        case .found:
            guard let data = found as? Data, data.count <= Self.signInBytes else { throw AgentSecretError.failed }
            return data
        case .missing: return nil
        case .denied: throw AgentSecretError.denied
        case .failed: throw AgentSecretError.failed
        }
    }

    /// Deletes any saved item, then adds the new one, as `save` does for a key.
    public func saveSignIn(_ data: Data, note: String?, for item: AgentSignInItem) throws {
        guard data.count <= Self.signInBytes else { throw AgentSecretError.failed }
        try deleteItem(account: item.account)
        switch Self.outcome(of: SecItemAdd(Self.signInAddQuery(data, note: note, for: item) as CFDictionary, nil)) {
        case .found: return
        case .denied: throw AgentSecretError.denied
        case .missing, .failed: throw AgentSecretError.failed
        }
    }

    public func removeSignIn(_ item: AgentSignInItem) throws {
        try deleteItem(account: item.account)
    }

    public func signInNote(_ item: AgentSignInItem) -> String? {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(Self.presenceQuery(account: item.account) as CFDictionary, &found)
        guard Self.outcome(of: status) == .found, let attributes = found as? [String: Any] else { return nil }
        return attributes[kSecAttrComment as String] as? String
    }

    /// The most a sign-in item may hold: tokens are a few kilobytes.
    static let signInBytes = 65_536

    /// A new sign-in item: its data, the label the person sees, and the note, the account's email, as its comment.
    static func signInAddQuery(_ data: Data, note: String?, for item: AgentSignInItem) -> [String: Any] {
        var query = itemQuery(account: item.account)
        query[kSecAttrLabel as String] = signInLabel
        query[kSecValueData as String] = data
        if let note, !note.isEmpty { query[kSecAttrComment as String] = note }
        return query
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
    static func itemQuery(_ id: AgentSecretID) -> [String: Any] { itemQuery(account: id.account) }

    static func itemQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Whether the item is there, from its attributes alone.
    static func presenceQuery(_ id: AgentSecretID) -> [String: Any] { presenceQuery(account: id.account) }

    static func presenceQuery(account: String) -> [String: Any] {
        var query = itemQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// The saved key itself.
    static func secretQuery(_ id: AgentSecretID) -> [String: Any] { dataQuery(account: id.account) }

    static func dataQuery(account: String) -> [String: Any] {
        var query = itemQuery(account: account)
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

/// The signature check of a ChatGPT sign-in's ID token, against a key from the sign-in host's published list. It is
/// here because this is the one file that may call the Security framework. It weighs a token's signature and nothing
/// else: no certificate, no server trust.
public enum AgentTokenSignature {
    /// Whether `signature` over `input` was made with `key`: "RS256" for an RSA key of 2048 bits or more, "ES256" for a
    /// P-256 key. Any other algorithm, a key of the other kind, or a key or signature of the wrong size is false.
    public static func verifies(_ signature: Data, over input: Data, algorithm: String, key: AgentSigningKey) -> Bool {
        switch (algorithm, key.kind) {
        case ("RS256", .rsa(let modulus, let exponent)):
            guard let publicKey = rsaKey(modulus: modulus, exponent: exponent) else { return false }
            return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData,
                                         signature as CFData, nil)
        case ("ES256", .p256(let x, let y)):
            guard signature.count == 64, let publicKey = p256Key(x: x, y: y) else { return false }
            let parts = (signature.prefix(32), signature.suffix(32))
            let der = sequence(integer(Data(parts.0)) + integer(Data(parts.1)))
            return SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, input as CFData, der as CFData, nil)
        default:
            return false
        }
    }

    /// The fewest bytes an RSA modulus may have: 2048 bits.
    static let rsaModulusBytes = 256

    /// An RSA public key from its modulus and exponent, written as PKCS #1 asks: a sequence of the two integers.
    static func rsaKey(modulus: Data, exponent: Data) -> SecKey? {
        let modulus = Data(modulus.drop { $0 == 0 })
        guard modulus.count >= rsaModulusBytes, !exponent.isEmpty, exponent.count <= 8 else { return nil }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(sequence(integer(modulus) + integer(exponent)) as CFData, attributes as CFDictionary, nil)
    }

    /// A P-256 public key from its two coordinates, written as an uncompressed point.
    static func p256Key(x: Data, y: Data) -> SecKey? {
        guard x.count == 32, y.count == 32 else { return nil }
        let point = Data([0x04]) + x + y
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                         kSecAttrKeySizeInBits as String: 256]
        return SecKeyCreateWithData(point as CFData, attributes as CFDictionary, nil)
    }

    /// A DER integer: no leading zero bytes, but one where the first byte would read as negative.
    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }

    static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }

    static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
