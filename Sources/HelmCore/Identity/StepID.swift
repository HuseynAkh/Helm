import Foundation

/// Stable UUID identity for F-058; no filesystem or actor ownership is implied.
public struct StepID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
