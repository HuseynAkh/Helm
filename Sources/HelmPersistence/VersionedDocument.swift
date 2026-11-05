import Foundation

/// Shared envelope preserves F-028–F-030 data and refuses unknown future schemas.
public struct VersionedDocument<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let items: Payload
    public init(schemaVersion: Int = 1, items: Payload) { self.schemaVersion = schemaVersion; self.items = items }
}

/// Failures reach the composition root; future user-data files are never rewritten (F-028–F-030).
public enum PersistenceError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case modifiedDuringLoad
}
