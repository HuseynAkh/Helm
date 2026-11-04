// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Plain identifiers preserve the F-003 toolbar order without importing UI frameworks.
public enum ToolbarItem: String, CaseIterable, Hashable, Sendable, Codable {
    case sidebar, navigation, location, viewMode, search, flexibleSpace
    public static let defaultLayout: [ToolbarItem] = [.sidebar, .navigation, .location, .viewMode, .search]
}

/// Portable toolbar command IDs preserve F-003/F-043 keyboard entry points (M24).
public enum ToolbarCommand: String, CaseIterable, Hashable, Sendable, Codable {
    case toggleSidebar, back, forward, focusLocation, gridView, listView, focusSearch
    public var keyEquivalent: String? {
        switch self {
        case .focusLocation: return "Cmd+L"
        case .focusSearch: return "Cmd+F"
        case .gridView: return "Cmd+1"
        case .listView: return "Cmd+2"
        case .back: return "Cmd+["
        case .forward: return "Cmd+]"
        case .toggleSidebar: return "Ctrl+Cmd+S"
        }
    }
    public var toolbarItem: ToolbarItem {
        switch self {
        case .toggleSidebar: return .sidebar
        case .back, .forward: return .navigation
        case .focusLocation: return .location
        case .gridView, .listView: return .viewMode
        case .focusSearch: return .search
        }
    }
}

/// Validation reports missing keyboard routes even when fields are visible (F-003, F-043, M24).
public enum ToolbarLayoutIssue: Equatable, Sendable {
    case duplicateItem(ToolbarItem), unreachableCommand(ToolbarCommand)
}

/// Keyboard routes must open/focus editors independently of hidden/removed toolbar fields (M24).
public enum ToolbarLayoutValidation {
    public static func validate(_ items: [ToolbarItem], reachableKeyboardCommands: Set<ToolbarCommand>) -> [ToolbarLayoutIssue] {
        var issues: [ToolbarLayoutIssue] = []
        var seen: Set<ToolbarItem> = []
        for item in items where item != .flexibleSpace {
            if !seen.insert(item).inserted { issues.append(.duplicateItem(item)) }
        }
        for command in [ToolbarCommand.focusLocation, .focusSearch] {
            if !reachableKeyboardCommands.contains(command) { issues.append(.unreachableCommand(command)) }
        }
        return issues
    }
}
