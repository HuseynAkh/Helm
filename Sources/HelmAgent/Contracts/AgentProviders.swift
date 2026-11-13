import Foundation
import HelmCore

/// The model providers AI mode can use. The raw value is what `ai.json` holds and what a key's keychain account
/// starts with, so it never changes.
public enum AgentProviderID: String, Codable, Sendable, CaseIterable { case claude, openAI, gemini, grok, ollama, lmStudio, other }

/// The request and reply shapes a provider speaks.
public enum AgentWire: String, Sendable { case anthropicMessages, openAIResponses, chatCompletions }

/// Which header carries the key.
public enum AgentAuthStyle: String, Sendable { case none, xAPIKey, bearer, googAPIKey }

/// The requests Helm makes of a provider: a model turn, the model list, and a second place to look for that list.
public enum AgentRoute: Hashable, Sendable { case chat, models, modelsAlternate }

/// One route's fixed parts. Nothing here comes from a caller: the address is the endpoint's, and the key is added by
/// the transport.
public struct AgentRouteSpec: Hashable, Sendable {
    /// "GET" or "POST".
    public let method: String
    /// Added to the end of the endpoint's `basePath`.
    public let path: String
    /// Fixed query items. Never a key.
    public let query: [String: String]
    public let auth: AgentAuthStyle
    public init(method: String, path: String, query: [String: String] = [:], auth: AgentAuthStyle) {
        self.method = method; self.path = path; self.query = query; self.auth = auth
    }
}

/// Why text isn't an address Helm will send to.
public enum AgentEndpointRefusal: String, Error, Sendable {
    case notAnAddress, needsHTTPS, hasCredentials, hasQueryOrFragment, otherDevice, badPort, notFixed
}

/// Where requests go. A value can only be made by one of the three initializers, and each one checks what it is
/// given, so an endpoint is always one of: a provider's fixed address, a port on this Mac, or an https host name the
/// person typed. Plain http is only ever this Mac. It isn't Codable, so one can't be loaded from a file.
public struct AgentEndpoint: Hashable, Sendable {
    public let isSecure: Bool
    /// Lower case and ASCII.
    public let host: String
    public let port: Int
    /// What every route's path follows: empty, or a path that starts with a slash and doesn't end in one.
    public let basePath: String
    public let isLoopback: Bool

    /// The fixed address of Claude, OpenAI, Gemini or Grok. Any other provider throws `.notFixed`: it has no address
    /// of its own.
    public init(fixed provider: AgentProviderID) throws {
        guard let base = AgentProviderCatalog.fixedBase(provider) else { throw AgentEndpointRefusal.notFixed }
        self = try AgentEndpoint(secureAddress: base)
    }

    /// A model server on this Mac: plain http to the loopback address, on a port from 1024 to 65535.
    public init(localPort port: Int) throws {
        guard Self.localPorts.contains(port) else { throw AgentEndpointRefusal.badPort }
        self.init(isSecure: false, host: AgentProviderCatalog.loopbackHost, port: port, basePath: "", isLoopback: true)
    }

    /// An address the person typed for a provider that isn't on the list. It must be https, with or without the
    /// scheme written out, and name a public host: two or more labels, the last one a top-level name. A name or a
    /// password, a query or a fragment are refused. So is every address that could be another device on the
    /// network or this Mac itself, in any spelling: an IP address, a one-word host and a `.local` name all throw
    /// `.otherDevice`.
    public init(typed text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumLength, AgentTextEscaper.isClean(trimmed),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw AgentEndpointRefusal.notAnAddress
        }
        let separator = "://"
        guard let range = trimmed.range(of: separator) else {
            // Joined at run time: a scheme and separator added together in code are kept whole in the app as a
            // scheme-only address, which the release check finds and refuses.
            self = try AgentEndpoint(secureAddress: [AgentProviderCatalog.secureScheme, trimmed].joined(separator: separator))
            return
        }
        guard trimmed[..<range.lowerBound].lowercased() == AgentProviderCatalog.secureScheme else {
            throw AgentEndpointRefusal.needsHTTPS
        }
        self = try AgentEndpoint(secureAddress: trimmed)
    }

    /// The host in ASCII, as it is shown to the person. A look-alike name written with other letters shows in its
    /// encoded form here, which is how it is told from the real one.
    public var hostLabel: String { host }
    /// The host and port, as in "api.anthropic.com:443".
    public var hostAndPort: String { "\(host):\(port)" }

    // MARK: Checks

    private static let localPorts = 1024...65535
    private static let allPorts = 1...65535
    private static let securePort = 443
    /// The longest address taken, in bytes.
    private static let maximumLength = 2_048
    private static let maximumHostLength = 253
    private static let maximumLabelLength = 63

    private init(isSecure: Bool, host: String, port: Int, basePath: String, isLoopback: Bool) {
        self.isSecure = isSecure; self.host = host; self.port = port; self.basePath = basePath; self.isLoopback = isLoopback
    }

    /// An https address, read by Foundation's own address reader and then held to Helm's rules part by part.
    private init(secureAddress text: String) throws {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == AgentProviderCatalog.secureScheme else {
            throw AgentEndpointRefusal.notAnAddress
        }
        guard parts.user == nil, parts.password == nil else { throw AgentEndpointRefusal.hasCredentials }
        guard parts.query == nil, parts.fragment == nil else { throw AgentEndpointRefusal.hasQueryOrFragment }
        // The encoded host: a name written with letters outside ASCII is in its ASCII form here.
        let host = (parts.encodedHost ?? "").lowercased()
        if let refusal = Self.hostRefusal(host) { throw refusal }
        let port = parts.port ?? Self.securePort
        guard Self.allPorts.contains(port) else { throw AgentEndpointRefusal.badPort }
        guard let basePath = Self.basePath(from: parts.percentEncodedPath) else { throw AgentEndpointRefusal.notAnAddress }
        self.init(isSecure: true, host: host, port: port, basePath: basePath, isLoopback: false)
    }

    /// Nil when `host` is a public host name. The name is taken apart at its dots and each label is checked whole;
    /// nothing is decided from how the text starts or ends.
    private static func hostRefusal(_ host: String) -> AgentEndpointRefusal? {
        guard !host.isEmpty else { return .notAnAddress }
        // An IPv6 address, with or without its brackets.
        if host.contains(":") || host.contains("[") || host.contains("]") { return .otherDevice }
        guard host.utf8.count <= maximumHostLength else { return .notAnAddress }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= maximumLabelLength, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ isLetter($0) || isDigit($0) || $0 == "-" }) else { return .notAnAddress }
        }
        // One word is a name on the local network, or a whole IP address written as one number.
        guard labels.count >= 2, let last = labels.last else { return .otherDevice }
        // A top-level name is letters only, or an encoded name. Anything else in the last place is an IP address in
        // one of its spellings: "127.0.0.1", "127.1", "0x7f.0.0.1".
        let isTopLevelName = last.unicodeScalars.allSatisfy(isLetter) || last.hasPrefix("xn--")
        guard isTopLevelName, last != "local", last != "localhost" else { return .otherDevice }
        return nil
    }

    /// The path every route follows, without a slash at its end. Nil for a path with an escape, an empty part, or a
    /// part that climbs.
    private static func basePath(from path: String) -> String? {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" || parts.isEmpty else { return nil }
        if !parts.isEmpty { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..",
                  part.unicodeScalars.allSatisfy({ isLetter($0) || isDigit($0) || "-._~".unicodeScalars.contains($0) }) else {
                return nil
            }
        }
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
}

/// A provider and where it is reached.
public struct AgentProviderProfile: Hashable, Sendable {
    public let id: AgentProviderID
    public let endpoint: AgentEndpoint
    public init(id: AgentProviderID, endpoint: AgentEndpoint) {
        self.id = id; self.endpoint = endpoint
    }

    /// "Claude", "OpenAI", "Gemini", "Grok", "Ollama", "LM Studio" or "Other".
    public var name: String { AgentProviderCatalog.name(id) }
    /// Where requests go, as the person is told: the provider's name; "Ollama on this Mac" for a local one; the
    /// host for one that isn't on the list.
    public var destination: String {
        switch id {
        case .claude, .openAI, .gemini, .grok: return name
        case .ollama, .lmStudio: return AgentText.destinationOnThisMac(name)
        case .other: return endpoint.hostLabel
        }
    }
    public var wire: AgentWire { AgentProviderCatalog.wire(id) }
    /// Ollama and LM Studio: the model runs on this Mac.
    public var isLocal: Bool { id == .ollama || id == .lmStudio }
    /// The four cloud providers take nothing without a key. A local server and a typed address may have none.
    public var needsKey: Bool {
        switch id {
        case .claude, .openAI, .gemini, .grok: return true
        case .ollama, .lmStudio, .other: return false
        }
    }
    /// Which saved key is this profile's. The host and port are part of it, so a key saved for one address is never
    /// found for another.
    public var secretID: AgentSecretID { AgentSecretID(provider: id, host: endpoint.host, port: endpoint.port) }
}
