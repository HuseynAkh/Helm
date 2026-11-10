import Foundation
import HelmCore

/// A standardized star retains its original creation date across migration retries (F-029).
public struct StarRecord: Codable, Equatable, Sendable {
    public let path: String
    public let addedAt: Date
    public init(path: String, addedAt: Date) { self.path = path; self.addedAt = addedAt }
}

/// Offline bookmarks remain persisted and keep optional future access data (F-028, B-029).
public struct BookmarkRecord: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let addedAt: Date
    public let bookmarkData: Data?
    public init(path: String, name: String, addedAt: Date, bookmarkData: Data? = nil) {
        self.path = path; self.name = name; self.addedAt = addedAt; self.bookmarkData = bookmarkData
    }
}

/// Per-tab restoration is independent of UI controllers (F-068).
public struct SessionTab: Codable, Equatable, Sendable {
    public let location: Location
    public let viewMode: ViewMode
    public let sort: ItemSort
    public let showHidden: Bool
    public init(location: Location, viewMode: ViewMode = .grid, sort: ItemSort = .defaultSort, showHidden: Bool = false) {
        self.location = location; self.viewMode = viewMode; self.sort = sort; self.showHidden = showHidden
    }
}

/// Window frame autosave identity and selected tab survive relaunch (F-068).
public struct SessionWindow: Codable, Equatable, Sendable {
    public let frameAutosaveName: String
    public let tabs: [SessionTab]
    public let activeTabIndex: Int
    public init(frameAutosaveName: String, tabs: [SessionTab], activeTabIndex: Int = 0) {
        self.frameAutosaveName = frameAutosaveName; self.tabs = tabs
        self.activeTabIndex = min(max(0, activeTabIndex), max(0, tabs.count - 1))
    }
    private enum CodingKeys: String, CodingKey { case frameAutosaveName, tabs, activeTabIndex }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(frameAutosaveName: try c.decode(String.self, forKey: .frameAutosaveName),
                  tabs: try c.decode([SessionTab].self, forKey: .tabs),
                  activeTabIndex: try c.decode(Int.self, forKey: .activeTabIndex))
    }
}
