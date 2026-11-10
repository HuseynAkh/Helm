import Foundation

/// Stable UUID identity for F-058; no filesystem or actor ownership is implied.
public struct OperationID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
