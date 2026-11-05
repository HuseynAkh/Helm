// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Named controls preserve F-003 toolbar and F-038 context-menu actions, addressing B-061.
/// Descriptions never execute commands or infer enabled state; validation remains the caller's job.
public enum ActionDescriptions {
    public static func toolbar(_ command: ToolbarCommand) -> String {
        switch command {
        case .toggleSidebar: return "Toggle sidebar"
        case .back: return "Go back"
        case .forward: return "Go forward"
        case .focusLocation: return "Edit location"
        case .gridView: return "Show as icons"
        case .listView: return "Show as list"
        case .focusSearch: return "Search files"
        }
    }

    /// Uses the actual (possibly localized or dynamic) menu title to avoid command/title drift.
    public static func contextMenu(_ item: CommandMenuItem, targetName: String? = nil,
                                   enabled: Bool = true) -> String {
        var parts: [String] = [item.title]
        if let name = targetName, !name.isEmpty { parts.append(name) }
        if !enabled { parts.append("unavailable") }
        return parts.joined(separator: ", ")
    }
}
