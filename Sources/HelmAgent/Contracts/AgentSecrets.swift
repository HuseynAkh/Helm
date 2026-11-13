import Foundation

/// A provider's key. It prints as "AgentSecret(hidden)" however it is printed, and it isn't Codable, Equatable or
/// Hashable, so it can't be written to a file, compared in an assertion message or used as a dictionary key by
/// accident. The text comes out through `revealSecret()` alone, and the privacy check lists the files that may
/// name that method.
public struct AgentSecret: Sendable {
    private let text: String

    /// A key as the person pasted it, with the space round it removed. Nil for an empty key, a control character,
    /// a character outside ASCII, or more than 512 characters: a key is none of these, and a line break in one could
    /// add a header to a request.
    public init?(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= Self.maximumLength,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return nil }
        self.text = trimmed
    }

    /// The key itself, for the one place that puts it on a request and the one that saves it.
    public func revealSecret() -> String { text }

    static let maximumLength = 512
}

extension AgentSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "AgentSecret(hidden)" }
    public var debugDescription: String { "AgentSecret(hidden)" }
    /// No children, so `dump` and a debugger's summary show nothing either.
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Which saved key: the provider, and the host and port it was saved for. A key is found only under the address it
/// was saved for, so a changed address can't send it somewhere else.
public struct AgentSecretID: Hashable, Sendable {
    public let provider: AgentProviderID, host: String, port: Int
    public init(provider: AgentProviderID, host: String, port: Int) {
        self.provider = provider; self.host = host; self.port = port
    }
    /// The keychain account, as in "claude|api.anthropic.com:443".
    public var account: String { "\(provider.rawValue)|\(host):\(port)" }
}

/// A key couldn't be had: macOS refused, or the store failed.
public enum AgentSecretError: Error, Equatable, Sendable { case denied, failed }

/// Where keys are kept.
public protocol AgentSecretStoring: Sendable {
    /// Whether a key is saved. Looks at the item's attributes only, so macOS never asks the person anything.
    func has(_ id: AgentSecretID) -> Bool
    /// The saved key, or nil when there is none. Throws `.denied` when macOS refused to hand it over.
    func secret(for id: AgentSecretID) throws -> AgentSecret?
    /// Saves a key in place of any that was there: the old item is deleted, then the new one is added.
    func save(_ secret: AgentSecret, for id: AgentSecretID) throws
    func remove(_ id: AgentSecretID) throws
    /// True for a store that lasts only as long as the app runs. A fixture run types a key into no other kind.
    var isMemoryOnly: Bool { get }
}

/// Tells text that is shaped like a provider's key, so one typed into the wrong place is never sent to a model.
public enum AgentKeyShape {
    /// The starts of the keys the providers hand out.
    static let prefixes = ["sk-", "xai-", "AIza", "gsk_", "hf_", "pplx-"]
    static let minimumLength = 20

    /// Whether `text` is one word of 20 characters or more that starts the way a provider's key does and holds only
    /// the characters keys are made of.
    public static func looksLikeKey(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.unicodeScalars.count >= minimumLength, prefixes.contains(where: word.hasPrefix) else { return false }
        return word.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "-" || scalar == "_"
        }
    }
}
