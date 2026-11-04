// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Ordered custom tabs preserve adjacent activation and last-tab behavior (F-002/F-003, B-020).
public struct WindowState: Sendable, Equatable {
    public private(set) var tabs: [TabID]
    public private(set) var activeTabID: TabID
    public var isSidebarVisible: Bool
    public var activeOperationIDs: [OperationID]
    /// Empty/duplicate input is normalized; the active tab always belongs to the window.
    public init(tabs: [TabID], activeTabID: TabID, isSidebarVisible: Bool = true,
                activeOperationIDs: [OperationID] = []) {
        var seen: Set<TabID> = []
        var unique: [TabID] = tabs.filter { seen.insert($0).inserted }
        if unique.isEmpty { unique = [activeTabID] }
        self.tabs = unique
        self.activeTabID = unique.contains(activeTabID) ? activeTabID : (unique.first ?? activeTabID)
        self.isSidebarVisible = isSidebarVisible; self.activeOperationIDs = activeOperationIDs
    }
    fileprivate mutating func add(_ id: TabID, activate: Bool) {
        if !tabs.contains(id) { tabs.append(id) }
        if activate { activeTabID = id }
    }
    fileprivate mutating func activate(_ id: TabID) { if tabs.contains(id) { activeTabID = id } }
    fileprivate mutating func close(_ id: TabID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(of: id) else { return false }
        if activeTabID == id { activeTabID = tabs[index > 0 ? index - 1 : 1] }
        tabs.remove(at: index); return true
    }
    fileprivate mutating func move(_ id: TabID, to index: Int) {
        guard tabs.indices.contains(index), let old = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: old); tabs.insert(id, at: index)
    }
}
/// Button-close and command-close are distinct, preserving the existing last-tab rule (F-003).
public enum WindowAction: Sendable, Equatable {
    case add(TabID, activate: Bool), activate(TabID), closeTab(TabID), closeCurrentTab
    case move(TabID, to: Int), setSidebarVisible(Bool)
}
/// Tab teardown is explicit; operations remain owned outside tab controllers (B-020).
public enum WindowEffect: Sendable, Equatable { case activate(TabID), deactivate(TabID), dispose(TabID), closeWindow }
/// Pure window transitions keep active identity valid during close and reorder (F-002/F-003).
public enum WindowReducer {
    public static func reduce(_ state: WindowState, _ action: WindowAction) -> (WindowState, [WindowEffect]) {
        var next: WindowState = state
        var effects: [WindowEffect] = []
        switch action {
        case .add(let id, let activate): next.add(id, activate: activate)
        case .activate(let id): next.activate(id)
        case .closeTab(let id): if next.close(id) { effects.append(.dispose(id)) }
        case .closeCurrentTab:
            if next.tabs.count == 1 { effects.append(.closeWindow) }
            else if next.close(state.activeTabID) { effects.append(.dispose(state.activeTabID)) }
        case .move(let id, let index): next.move(id, to: index)
        case .setSidebarVisible(let visible): next.isSidebarVisible = visible
        }
        if next.activeTabID != state.activeTabID {
            effects.insert(contentsOf: [.deactivate(state.activeTabID), .activate(next.activeTabID)], at: 0)
        }
        return (next, effects)
    }
}
