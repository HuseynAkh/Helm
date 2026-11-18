import Foundation
import HelmCore

/// How far below the folder on show an Organize reaches. The raw value is the depth a listing is asked for, where
/// 0 means every level.
public enum AgentOrganizeDepth: Int, Sendable, CaseIterable { case thisFolder = 1, twoLevels = 2, allLevels = 0 }

/// What the panel offers to do in the folder on show: Organize. Moving or copying is asked for in the composer.
public struct AgentSuggestion: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case organize }
    public let kind: Kind
    /// The items in the folder, or the items selected.
    public let count: Int
    public let isSelection: Bool
    public var id: String { kind.rawValue }
    public init(kind: Kind, count: Int, isSelection: Bool) {
        self.kind = kind; self.count = count; self.isSelection = isSelection
    }

    /// The words on the button.
    public var title: String {
        switch kind {
        case .organize: return isSelection ? AgentText.suggestOrganizeSelected(count) : AgentText.suggestOrganize(count)
        }
    }
}

/// The suggestion, worked out from counts the window already holds. No model is asked, nothing is sent and nothing
/// is looked up on the disk.
public enum AgentSuggestions {
    /// Organize, for the folder on show, or for the selection when there is one. None for an empty folder, and none
    /// where nothing can be changed: a place that can only be viewed or that isn't responding.
    public static func make(itemCount: Int, selectedCount: Int, storage: StorageFacts) -> [AgentSuggestion] {
        guard itemCount > 0, !storage.isReadOnly, storage.isResponding else { return [] }
        let isSelection = selectedCount > 0
        return [AgentSuggestion(kind: .organize, count: isSelection ? selectedCount : itemCount, isSelection: isSelection)]
    }

    /// What a model is sent when Organize is pressed: a fixed sentence that holds an id and numbers and never a
    /// name from the disk, and says the answer is a plan. `root` is the alias of the folder on show, such as "r1".
    /// With a selection the depth isn't said, since the items are already chosen.
    public static func message(for suggestion: AgentSuggestion, depth: AgentOrganizeDepth, root: String) -> String {
        switch suggestion.kind {
        case .organize:
            if suggestion.isSelection {
                let items = suggestion.count == 1 ? "item" : "items"
                return "Organize the \(suggestion.count) selected \(items) in \(root) into folders by kind. \(answerWithPlan)"
            }
            return "Organize the items in \(root) into folders by kind. Depth: \(words(for: depth)). \(answerWithPlan)"
        }
    }

    /// The end of every sentence a suggestion sends: what a model answers it with.
    static let answerWithPlan = "List them, then call propose_changes."

    private static func words(for depth: AgentOrganizeDepth) -> String {
        switch depth {
        case .thisFolder: return "this folder"
        case .twoLevels: return "2 levels"
        case .allLevels: return "all levels"
        }
    }
}
