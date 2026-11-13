#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for searching with a model's help: the field's toggle, Return, each result's reason and the
/// status bar's line. They run only in a fixture run, where the model is the scripted one, and every verb that
/// waits gives up after 10 seconds.
extension HostSmokeDriver {
    static func performAISearchVerb(_ verb: String, _ argument: String, step: String,
                                    window: BrowserWindowController, app: AppController) async -> Bool {
        let verbs: Set<String> = ["search-ai", "search-ai-is", "search-return", "result-reason", "search-status-reads",
                                  "search-queries-read"]
        guard verbs.contains(verb) else { return false }
        guard app.options.isIsolated else { check(false, step, "not a fixture run"); return true }
        switch verb {
        case "search-ai":
            // "on" or "off": presses the spark in the search field, which opens the field first.
            window.setAISearchForTesting(argument == "on")
            await wait(seconds: 0.3)
        case "search-ai-is":
            let shown = window.isAISearchOnForTesting ? "on" : "off"
            check(shown == argument, step, shown)
        case "search-return":
            // Return in the search field, then waits until the model has answered or failed.
            window.submitSearchForTesting()
            let answered = await aiSearchWaitUntil {
                guard let search = window.activeTab?.search, search.query.usesAI else { return false }
                return search.assist.map { $0.phase != .thinking } ?? !search.isGathering
            }
            check(answered, step, "still \(window.activeTab?.search?.assist?.phase.rawValue ?? "not searching")")
        case "result-reason":
            // "<name>=<reason>": the result's tooltip in the view on show.
            let (name, reason) = aiSearchSplit(argument)
            let matched = await aiSearchWaitUntil { window.matchReasonForTesting(named: name) == reason }
            check(matched, step, window.matchReasonForTesting(named: name) ?? "no reason")
        case "search-status-reads":
            // The status bar's line holds these words.
            let reads = await aiSearchWaitUntil { window.aiSearchStatusForTesting?.text.contains(argument) == true }
            check(reads, step, window.aiSearchStatusForTesting?.text ?? "the usual words")
        case "search-queries-read":
            // One line of the status bar's list of queries that ran holds these words.
            let reads = await aiSearchWaitUntil { window.aiSearchStatusForTesting?.queries.contains { $0.contains(argument) } == true }
            check(reads, step, window.aiSearchStatusForTesting?.queries.joined(separator: " | ") ?? "no queries")
        default:
            return false
        }
        return true
    }

    /// Waits up to 10 seconds for `condition`.
    private static func aiSearchWaitUntil(_ condition: () -> Bool) async -> Bool {
        var waited = 0.0
        while !condition() {
            if waited >= 10 { return false }
            await wait(seconds: 0.05); waited += 0.05
        }
        return true
    }

    /// "name=words", split at the first "=", so the reason may hold one and the name may not.
    private static func aiSearchSplit(_ argument: String) -> (String, String) {
        guard let mark = argument.firstIndex(of: "=") else { return (argument, "") }
        return (String(argument[..<mark]), String(argument[argument.index(after: mark)...]))
    }
}
#endif
