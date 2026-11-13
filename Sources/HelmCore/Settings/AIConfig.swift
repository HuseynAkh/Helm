import Foundation

/// What AI mode remembers between launches, as it is written to `ai.json`: which provider and model were chosen, and
/// where a local or typed provider is found. Never a key, a folder or a conversation.
/// The fields are plain strings, so this file needs nothing from the module that talks to a provider.
public struct AIConfig: Codable, Equatable, Sendable {
    /// The chosen provider's identifier, or nil while none is chosen.
    public var provider: String?
    /// The model chosen for each provider, by the provider's identifier.
    public var models: [String: String]
    /// The port of each provider that runs on this Mac, by the provider's identifier.
    public var ports: [String: Int]
    /// The address typed for a provider that isn't on the list: an https host name, with an optional port and path,
    /// and never a name or a password.
    public var otherAddress: String?
    /// Which build of Helm last saved each key, by the key's keychain account. The key itself is only in the keychain.
    public var keyOwners: [String: String]

    public init(provider: String? = nil, models: [String: String] = [:], ports: [String: Int] = [:],
                otherAddress: String? = nil, keyOwners: [String: String] = [:]) {
        self.provider = provider; self.models = models; self.ports = ports
        self.otherAddress = otherAddress; self.keyOwners = keyOwners
    }

    /// Every field is optional on disk, so a file written by an older or a newer Helm still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        models = try values.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        ports = try values.decodeIfPresent([String: Int].self, forKey: .ports) ?? [:]
        otherAddress = try values.decodeIfPresent(String.self, forKey: .otherAddress)
        keyOwners = try values.decodeIfPresent([String: String].self, forKey: .keyOwners) ?? [:]
    }
}
