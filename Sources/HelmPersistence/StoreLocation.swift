import Foundation

/// Injected Application Support root keeps persistence and tests isolated (F-068, B-068).
public struct StoreLocation: Sendable, Equatable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var stars: URL { directory.appendingPathComponent("stars.json") }
    public var bookmarks: URL { directory.appendingPathComponent("bookmarks.json") }
    public var recent: URL { directory.appendingPathComponent("recent.json") }
    public var session: URL { directory.appendingPathComponent("session.json") }
    public var trashOrigins: URL { directory.appendingPathComponent("trash-origins.json") }
}
