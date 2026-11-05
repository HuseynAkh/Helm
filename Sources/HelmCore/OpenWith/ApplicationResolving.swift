// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-062 application identity uses its installed URL, distinguishing multiple installed copies.
public struct ApplicationChoice: Hashable, Sendable, Identifiable {
    public let url: URL
    public let name: String
    public var id: URL { url }
    public init(url: URL, name: String) { self.url = url.standardizedFileURL; self.name = name }
}

/// F-062 application lookup stays outside Core; the UI adapter owns NSWorkspace isolation (B-070).
public protocol ApplicationResolving: Sendable {
    func applications(for item: ItemID) async throws -> [ApplicationChoice]
    func defaultApplication(for item: ItemID) async throws -> ApplicationChoice?
}

/// Deterministic F-062 resolver for tests and previews; folders use the same lookup as files.
public struct InMemoryApplicationResolver: ApplicationResolving, Sendable {
    private let choices: [ItemID: [ApplicationChoice]]
    private let defaults: [ItemID: ApplicationChoice]
    public init(choices: [ItemID: [ApplicationChoice]] = [:], defaults: [ItemID: ApplicationChoice] = [:]) {
        self.choices = choices; self.defaults = defaults
    }
    public func applications(for item: ItemID) async throws -> [ApplicationChoice] { choices[item] ?? [] }
    public func defaultApplication(for item: ItemID) async throws -> ApplicationChoice? { defaults[item] }
}
