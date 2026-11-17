#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for searching with a model's help: the field's toggle, Read contents, Return, each result's reason and
/// the status bar's line. They run only in a fixture run, where the model is the scripted one, and every verb that
/// waits gives up after 10 seconds. The kind row's verbs are the plain search's, with the header's.
extension HostSmokeDriver {
    static func performAISearchVerb(_ verb: String, _ argument: String, step: String,
                                    window: BrowserWindowController, app: AppController) async -> Bool {
        let verbs: Set<String> = ["search-ai", "search-ai-is", "search-return", "result-reason", "search-status-reads",
                                  "search-queries-read", "search-mark-is", "search-contents", "search-contents-is",
                                  "search-contents-read"]
        guard verbs.contains(verb) else { return false }
        guard app.options.isIsolated else { check(false, step, "not a fixture run"); return true }
        switch verb {
        case "search-ai":
            // "on" or "off": presses the spark in the search field, which opens the field first.
            window.setAISearchForTesting(argument == "on")
            await wait(seconds: 0.3)
        case "search-mark-is":
            // search-mark-is magnifier|spark|spark lit: the search field's leading mark. The spark shows whenever AI
            // mode is on, and lights while AI search is on.
            check(window.searchFieldMarkForTesting == argument, step, window.searchFieldMarkForTesting)
        case "search-ai-is":
            let shown = window.isAISearchOnForTesting ? "on" : "off"
            check(shown == argument, step, shown)
        case "search-contents":
            // search-contents on|off: a click on the Read contents switch at the end of the kind row, when it isn't
            // already as asked.
            guard argument == "on" || argument == "off" else { check(false, step, "usage"); return true }
            if window.aiSearchContentsForTesting.on != (argument == "on") {
                check(window.clickAISearchContentsForTesting(), step, "the switch doesn't show")
            }
            await wait(seconds: 0.3)
            check(window.aiSearchContentsForTesting.on == (argument == "on"), step, window.aiSearchContentsForTesting.on ? "on" : "off")
        case "search-contents-is":
            // search-contents-is on|off|hidden: the switch at the end of the kind row.
            let state = window.aiSearchContentsForTesting
            let shown = !state.shown ? "hidden" : state.on ? "on" : "off"
            check(shown == argument, step, shown)
        case "search-contents-read":
            // search-contents-read <n>: pictures and videos this search session has read inside.
            let count = window.aiSearchContentsReadForTesting
            check(count == Int(argument), step, "\(count)")
        case "search-return":
            // Return in the search field, then waits until the model has answered or failed. With Read contents on,
            // every candidate is read on this Mac first, which takes longer.
            window.submitSearchForTesting()
            let answered = await aiSearchWaitUntil(seconds: 30) {
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
    private static func aiSearchWaitUntil(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        var waited = 0.0
        while !condition() {
            if waited >= seconds { return false }
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
