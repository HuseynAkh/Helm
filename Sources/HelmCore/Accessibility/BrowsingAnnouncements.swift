// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Snapshot-based selection speech extends F-064 without synchronous size queries (B-058).
public enum SelectionAnnouncement {
    public static func describe(selectedCount: Int, itemCount: Int, selectedBytes: Int64? = nil,
                                formatting: AccessibilityFormatting) -> String {
        let total: Int = max(0, itemCount)
        let selected: Int = min(max(0, selectedCount), total)
        var result: String = "\(formatting.count(selected)) of \(formatting.count(total)) selected"
        if selected > 0, let bytes = selectedBytes, let size = formatting.bytes(bytes) {
            result += ", " + size
        }
        return result
    }
}

/// Folder transitions preserve navigation (F-025); loading/partial results never sound complete (B-017).
public enum NavigationAnnouncement {
    public enum State: Sendable { case loaded, loading, partial }
    public static func describe(folderName: String, itemCount: Int, state: State,
                                formatting: AccessibilityFormatting) -> String {
        let count: Int = max(0, itemCount)
        let items: String = "\(formatting.count(count)) " + (count == 1 ? "item" : "items")
        switch state {
        case .loaded: return "Entered \(folderName), \(items)"
        case .loading: return "Entered \(folderName), loading, \(items) so far"
        case .partial: return "Entered \(folderName), \(items), partial results"
        }
    }
}
