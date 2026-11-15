import Foundation
import HelmCore

/// How far below the folder on show an Organize reaches. The raw value is the depth a listing is asked for, where
/// 0 means every level.
public enum AgentOrganizeDepth: Int, Sendable, CaseIterable { case thisFolder = 1, twoLevels = 2, allLevels = 0 }

/// One of the three things the panel offers to do in the folder on show.
public struct AgentSuggestion: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case organize, moveAll, copyAll }
    public let kind: Kind
    /// The items in the folder, or the items selected.
    public let count: Int
    public let isSelection: Bool
    public var id: String { kind.rawValue }
    public init(kind: Kind, count: Int, isSelection: Bool) {
        self.kind = kind; self.count = count; self.isSelection = isSelection
    }

    /// The words on the chip.
    public var title: String {
        switch kind {
        case .organize: return isSelection ? AgentText.suggestOrganizeSelected(count) : AgentText.suggestOrganize(count)
        case .moveAll: return isSelection ? AgentText.suggestMoveSelected(count) : AgentText.suggestMoveAll
        case .copyAll: return isSelection ? AgentText.suggestCopySelected(count) : AgentText.suggestCopyAll
        }
    }

    /// Organize runs as soon as it is pressed, on this folder alone. Move and Copy fill the composer and wait for a
    /// folder to be named.
    public var runsAtOnce: Bool { kind == .organize }
}

/// The three suggestions, worked out from counts the window already holds. No model is asked, nothing is sent and
/// nothing is looked up on the disk.
public enum AgentSuggestions {
    /// Organize, Move and Copy for the folder on show, or for the selection when there is one. None for an empty
    /// folder, and none where nothing can be changed: a place that can only be viewed or that isn't responding.
    public static func make(itemCount: Int, selectedCount: Int, storage: StorageFacts) -> [AgentSuggestion] {
        guard itemCount > 0, !storage.isReadOnly, storage.isResponding else { return [] }
        let isSelection = selectedCount > 0
        let count = isSelection ? selectedCount : itemCount
        return [AgentSuggestion.Kind.organize, .moveAll, .copyAll].map {
            AgentSuggestion(kind: $0, count: count, isSelection: isSelection)
        }
    }

    /// What a model is sent when Organize is pressed: a fixed sentence that holds an id and numbers and never a
    /// name from the disk, and says the answer is a plan. `root` is the alias of the folder on show, such as "r1".
    /// With a selection the depth isn't said, since the items are already chosen. Move and Copy send nothing by
    /// themselves, so theirs is the sentence the composer is filled with.
    public static func message(for suggestion: AgentSuggestion, depth: AgentOrganizeDepth, root: String) -> String {
        switch suggestion.kind {
        case .moveAll, .copyAll:
            return composerText(for: suggestion)
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

    /// What Move and Copy type into the composer: a sentence that ends where the person names a folder. Organize
    /// types nothing.
    public static func composerText(for suggestion: AgentSuggestion) -> String {
        switch suggestion.kind {
        case .organize: return ""
        case .moveAll: return suggestion.isSelection ? AgentText.fillMoveSelected(suggestion.count) : AgentText.fillMoveAll
        case .copyAll: return suggestion.isSelection ? AgentText.fillCopySelected(suggestion.count) : AgentText.fillCopyAll
        }
    }

    private static func words(for depth: AgentOrganizeDepth) -> String {
        switch depth {
        case .thisFolder: return "this folder"
        case .twoLevels: return "2 levels"
        case .allLevels: return "all levels"
        }
    }
}
