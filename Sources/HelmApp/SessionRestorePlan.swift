// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmPersistence

/// Initial contents, including reveal selection, reach the first tab (F-002, B-018).
public struct TabCreationRequest: Equatable, Sendable {
    public let tab: SessionTab
    public let selectedURLs: [URL]
    public let unavailableLocation: Location?
    public init(tab: SessionTab, selectedURLs: [URL] = [], unavailableLocation: Location? = nil) {
        self.tab = tab; self.selectedURLs = selectedURLs; self.unavailableLocation = unavailableLocation
    }
}

/// One creation request owns a unique frame identity and active tab (F-068).
public struct WindowCreationRequest: Equatable, Sendable {
    public let frameAutosaveName: String
    public let tabs: [TabCreationRequest]
    public let activeTabIndex: Int
    public init(frameAutosaveName: String, tabs: [TabCreationRequest], activeTabIndex: Int = 0) {
        self.frameAutosaveName = frameAutosaveName; self.tabs = tabs
        self.activeTabIndex = min(max(0, activeTabIndex), max(0, tabs.count - 1))
    }
}

/// Pure restoration preserves tab preferences and reports missing folders (F-068, B-029).
/// SessionStore currently persists [SessionWindow], rather than a SessionRecord wrapper.
public struct SessionRestorePlan: Equatable, Sendable {
    public let windows: [WindowCreationRequest]
    public init(windows: [SessionWindow], home: URL, isAvailableDirectory: (URL) -> Bool) {
        var usedNames: Set<String> = []
        self.windows = windows.enumerated().map { index, window in
            var name = window.frameAutosaveName
            if name.isEmpty || usedNames.contains(name) {
                var ordinal = index + 1
                name = Self.frameName(ordinal: ordinal)
                while usedNames.contains(name) { ordinal += 1; name = Self.frameName(ordinal: ordinal) }
            }
            usedNames.insert(name)
            let tabs = window.tabs.isEmpty ? [SessionTab(location: .directory(home))] : window.tabs
            let requests: [TabCreationRequest] = tabs.map { tab in
                if case .directory(let url) = tab.location,
                   !url.isFileURL || !isAvailableDirectory(url) {
                    return TabCreationRequest(tab: SessionTab(location: .directory(home), viewMode: tab.viewMode,
                        sort: tab.sort, showHidden: tab.showHidden), unavailableLocation: tab.location)
                }
                return TabCreationRequest(tab: tab)
            }
            return WindowCreationRequest(frameAutosaveName: name, tabs: requests, activeTabIndex: window.activeTabIndex)
        }
    }
    public static func frameName(ordinal: Int) -> String {
        ordinal <= 1 ? "HelmMainWindow" : "HelmMainWindow-\(ordinal)"
    }
}
