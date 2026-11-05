// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Validated system-delegation target extends F-031 with P-206; never stores credentials.
public struct ServerAddress: Hashable, Sendable {
    public let url: URL
    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !text.contains("\\"), var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased() else { throw ServerAddressError.invalidURL }
        guard ["smb", "afp", "nfs", "ftp", "https", "http", "webdav", "webdavs", "vnc"].contains(scheme) else {
            throw ServerAddressError.unsupportedScheme
        }
        guard parts.user == nil, parts.password == nil else { throw ServerAddressError.credentialsNotAllowed }
        guard let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.query == nil, parts.fragment == nil,
              !parts.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw ServerAddressError.invalidURL }
        parts.scheme = scheme == "webdav" ? "http" : scheme == "webdavs" ? "https" : scheme
        parts.host = host.lowercased()
        let defaults: [String: Int] = ["smb": 445, "afp": 548, "nfs": 2049, "ftp": 21, "https": 443, "http": 80, "vnc": 5900]
        if let normalizedScheme = parts.scheme, parts.port == defaults[normalizedScheme] { parts.port = nil }
        if parts.path == "/" { parts.path = "" }
        guard let url = parts.url else { throw ServerAddressError.invalidURL }
        self.url = url
    }
}

/// Validation failures for the P-206 extension of F-031.
public enum ServerAddressError: Error, Equatable, Sendable { case invalidURL, unsupportedScheme, credentialsNotAllowed }

/// Value-only favorites/recents for P-206 (F-031); recents are newest-first and both lists dedupe.
public struct ServerHistory: Equatable, Sendable {
    public private(set) var favorites: [ServerAddress]
    public private(set) var recents: [ServerAddress]
    public let capacity: Int
    public init(favorites: [ServerAddress] = [], recents: [ServerAddress] = [], capacity: Int = 20) {
        self.capacity = max(0, capacity)
        self.favorites = []; self.recents = []
        for address in favorites where !self.favorites.contains(address) && self.favorites.count < self.capacity { self.favorites.append(address) }
        for address in recents where !self.recents.contains(address) && self.recents.count < self.capacity { self.recents.append(address) }
    }
    public mutating func addFavorite(_ address: ServerAddress) {
        if !favorites.contains(address) && favorites.count < capacity { favorites.append(address) }
    }
    public mutating func removeFavorite(_ address: ServerAddress) { favorites.removeAll { $0 == address } }
    public mutating func recordConnection(_ address: ServerAddress) {
        recents.removeAll { $0 == address }
        recents.insert(address, at: 0)
        recents = Array(recents.prefix(capacity))
    }
}
