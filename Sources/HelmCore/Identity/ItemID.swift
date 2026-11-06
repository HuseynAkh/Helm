import Foundation

/// Path identity preserves selection across refreshes (F-035); renames produce a new ID.
public struct ItemID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(url: URL) { rawValue = PathSpelling.standardPath(url) }
    public init(rawValue: String) { self.init(url: URL(fileURLWithPath: rawValue)) }
    public var url: URL { URL(fileURLWithPath: rawValue) }
}
