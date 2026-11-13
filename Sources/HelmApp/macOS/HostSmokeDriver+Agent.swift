#if os(macOS)
import AppKit
import HelmAgent
import HelmCore
import HelmUI

/// Smoke verbs for the AI panel: opening it, its folders, suggestions, thread, plan card, Apply and Undo.
/// Every verb refuses to run outside a fixture run, and every verb that waits gives up after 10 seconds.
extension HostSmokeDriver {
    static func performAgentVerb(_ verb: String, _ argument: String, step: String,
                                 window: BrowserWindowController, app: AppController) async -> Bool {
        guard verb.hasPrefix("agent-") else { return false }
        guard app.options.isIsolated else { check(false, step, "only in a fixture run"); return true }
        let services = window.dependencies.agent
        var model: AgentPanelModel? { window.agentPanelModelForTesting }
        switch verb {
        case "agent-open", "agent-close":
            // A press of the spark, when the panel isn't already as asked.
            if window.isAgentPanelOpen != (verb == "agent-open") { window.clickSparkForTesting() }
            await wait(seconds: 0.4)
        case "agent-is":
            let state = window.isAgentPanelOpen ? "open" : "closed"
            check(state == argument, step, state)
        case "agent-phase":
            let reached = await until { model?.phaseForTesting == argument && model?.isWaitingForTesting == false }
            check(reached, step, model?.phaseForTesting ?? "no panel")
        case "agent-chips":
            let reached = await until { model?.chipsForTesting.joined(separator: ",") == argument }
            check(reached, step, model?.chipsForTesting.joined(separator: ",") ?? "no panel")
        case "agent-chip-kind":
            // agent-chip-kind <label>=<words>: the place line of that chip's tooltip.
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { check(false, step, "usage"); return true }
            let reached = await until { model?.chipKindsForTesting[bits[0]] == bits[1] }
            check(reached, step, model?.chipKindsForTesting[bits[0]] ?? "no such chip")
        case "agent-suggests":
            let wanted = argument == "none" ? "" : argument
            let reached = await until { model?.suggestionsForTesting.joined(separator: "|") == wanted }
            check(reached, step, model?.suggestionsForTesting.joined(separator: "|") ?? "no panel")
        case "agent-press":
            guard let model else { check(false, step, "no panel"); return true }
            model.press(argument)
            await wait(seconds: 0.3)
        case "agent-type":
            guard let model else { check(false, step, "no panel"); return true }
            model.type(argument)
        case "agent-send":
            guard let model else { check(false, step, "no panel"); return true }
            model.send()
            await wait(seconds: 0.3)
        case "agent-key":
            guard let model else { check(false, step, "no panel"); return true }
            model.key(argument)
            await wait(seconds: 0.3)
        case "agent-say":
            // Types and sends, then waits for the request to end.
            guard let model else { check(false, step, "no panel"); return true }
            model.type(argument)
            model.send()
            let ended = await until { model.phaseForTesting != "working" && !model.isWaitingForTesting }
            check(ended, step, model.phaseForTesting)
        case "agent-reads":
            let reached = await until { model?.threadTextForTesting.contains(argument) == true }
            check(reached, step, model?.threadTextForTesting.replacingOccurrences(of: "\n", with: " | ") ?? "no panel")
        case "agent-lacks":
            // The thread doesn't hold this text, after the request that might have put it there has ended.
            let thread = model?.threadTextForTesting ?? ""
            check(!thread.contains(argument), step, thread.replacingOccurrences(of: "\n", with: " | "))
        case "agent-plan-reads":
            let reached = await until { model?.planCountsForTesting == argument }
            check(reached, step, model?.planCountsForTesting ?? "no card")
        case "agent-group":
            // agent-group <title> on|off: the last word is the state.
            let state = argument.split(separator: " ").last.map(String.init) ?? ""
            let title = String(argument.dropLast(state.count + 1))
            let groups = model?.groupsForTesting ?? []
            let found = groups.contains { $0 == "\(title):\(state)" || $0.hasPrefix("\(title):\(state):") }
            check(found, step, groups.joined(separator: " | "))
        case "agent-group-mark":
            // agent-group-mark <title>=<mark>
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { check(false, step, "usage"); return true }
            let groups = model?.groupsForTesting ?? []
            let found = groups.contains { $0 == "\(bits[0]):on:\(bits[1])" || $0 == "\(bits[0]):off:\(bits[1])" }
            check(found, step, groups.joined(separator: " | "))
        case "agent-tick":
            guard let model else { check(false, step, "no panel"); return true }
            model.tick(argument)
            await wait(seconds: 0.1)
        case "agent-apply", "agent-undo":
            // The card's button, then the wait for what it started.
            guard let model else { check(false, step, "no panel"); return true }
            model.press(verb == "agent-apply" ? AgentText.apply : AgentText.undo)
            await wait(seconds: 0.2)
            let ended = await until { !model.isWaitingForTesting && !window.isRunningOperationsForTesting }
            check(ended, step, model.phaseForTesting)
            await wait(seconds: 0.3)
        case "agent-drop":
            guard let model else { check(false, step, "no panel"); return true }
            model.drop(URL(fileURLWithPath: argument, isDirectory: true))
            _ = await until { !model.isWaitingForTesting }
        case "agent-script":
            // Loads a scripted model's answers from a file of the fixture.
            guard let scripted = services.runtime.scriptedClientForTesting else { check(false, step, "no scripted model"); return true }
            do {
                let text = try String(contentsOfFile: argument, encoding: .utf8)
                try scripted.load(Data(text.utf8))
            } catch {
                check(false, step, "the script didn't load")
            }
        case "agent-sent-lacks":
            // Nothing recorded as sent, by the scripted model or the conversation, holds this text.
            var sent = services.runtime.scriptedClientForTesting?.allSentText() ?? ""
            if let conversation = model?.sessionForTesting as? StandInConversation {
                sent += conversation.sent.map(\.text).joined(separator: "\n")
            }
            check(!sent.contains(argument), step, "it was sent")
        case "agent-client-built":
            let built = services.runtime.clientBuildCount > 0 ? "yes" : "no"
            check(built == argument, step, built)
        case "agent-connected":
            // agent-connected <address>|none: the stand-in connector was handed this address, or nothing yet.
            guard let connector = services.connector as? MemoryServerConnector else { check(false, step, "not the stand-in connector"); return true }
            let opened = connector.opened.map(\.absoluteString)
            check(argument == "none" ? opened.isEmpty : opened.contains(argument), step, opened.joined(separator: ","))
        case "agent-fast-limits":
            // agent-fast-limits [off]: half a second for a listing, so a slow place fails fast; off puts the usual
            // limits back.
            services.runtime.listSecondsOverrideForTesting = argument == "off" ? nil : 0.5
        default:
            return false
        }
        return true
    }

    /// Waits for `condition`, for 10 seconds at most.
    private static func until(_ condition: () -> Bool) async -> Bool {
        var waited = 0.0
        while !condition() {
            if waited >= 10 { return false }
            await wait(seconds: 0.05)
            waited += 0.05
        }
        return true
    }
}
#endif
