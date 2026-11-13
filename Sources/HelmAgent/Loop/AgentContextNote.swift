import Foundation
import HelmCore

/// The note Helm puts before the person's words in each request, built from fixed words only:
///
///     [Helm] Folders: r1 this_mac (on show); r2 cloud "Google Drive" syncs shared=unknown some_not_downloaded;
///     r3 server shared no_trash read_only not_responding. 12 items are selected in r1. Last plan: applied 210, skipped 4.
///
/// It names roots by alias and kind, never by a folder's name, so no name from the disk is ever outside a tool
/// result. A provider's name comes from the fixed list of `StorageClassifier.knownProviders`. Flags appear only when
/// they are true. It is one line, so a model reading the person's words after it can tell where it ends.
public enum AgentContextNote {
    /// `selectedRoot` is the alias of the root that holds the selection.
    public static func make(roots: [AgentScopeRoot], selectedCount: Int, selectedRoot: String?, lastPlan: AgentPlanOutcome?) -> String {
        make(roots: roots, selectedCount: selectedCount, selectedRoot: selectedRoot, lastPlan: lastPlan, holdingCloudOnly: [])
    }

    /// The same, with `some_not_downloaded` on each root under which a file that isn't downloaded was listed.
    static func make(roots: [AgentScopeRoot], selectedCount: Int, selectedRoot: String?, lastPlan: AgentPlanOutcome?,
                     holdingCloudOnly: Set<String>) -> String {
        let folders = roots.isEmpty ? "none" : roots.map { describe($0, holdsCloudOnly: holdingCloudOnly.contains($0.alias)) }
            .joined(separator: "; ")
        var note = mark + " Folders: " + folders + "."
        if selectedCount > 0, let selectedRoot {
            note += selectedCount == 1 ? " 1 item is selected in \(selectedRoot)." : " \(selectedCount) items are selected in \(selectedRoot)."
        }
        switch lastPlan {
        case .applied(let done, let skipped)?: note += " Last plan: applied \(done), skipped \(skipped)."
        case .dismissed?: note += " Last plan: dismissed."
        case nil: break
        }
        return note
    }

    /// What every note starts with.
    static let mark = "[Helm]"

    private static func describe(_ root: AgentScopeRoot, holdsCloudOnly: Bool) -> String {
        let facts = root.storage
        var words = [root.alias, facts.modelWord]
        if facts.kind == .cloud {
            let provider = StorageClassifier.knownProviders.first { $0 == facts.name } ?? "cloud folder"
            words.append("\"\(provider)\"")
        }
        if root.isTabFolder { words.append("(on show)") }
        if facts.syncs { words.append("syncs") }
        switch facts.shared {
        case .yes: words.append("shared")
        case .unknown: words.append("shared=unknown")
        case .no: break
        }
        if holdsCloudOnly { words.append("some_not_downloaded") }
        if facts.trash != .yes { words.append("no_trash") }
        if facts.isReadOnly { words.append("read_only") }
        if !facts.isResponding { words.append("not_responding") }
        return words.joined(separator: " ")
    }
}
