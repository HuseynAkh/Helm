#if os(macOS)
import AppKit
import HelmAgent
import HelmUI

/// Smoke verbs for the AI mode screen and Settings › AI: the screen itself, the switch, the provider, a key and the
/// connection state. They drive the same model a click does, and refuse to run outside a fixture run.
extension HostSmokeDriver {
    static func performAgentSetupVerb(_ verb: String, _ argument: String, step: String,
                                      window: BrowserWindowController, app: AppController) async -> Bool {
        guard verb.hasPrefix("ai-screen") || ["ai-provider", "ai-key", "ai-models-fail", "ai-state-is"].contains(verb) else {
            return false
        }
        guard app.options.isIsolated else { check(false, step, "only in a fixture run"); return true }
        switch verb {
        case "ai-screen":
            // ai-screen open|close: the AI mode screen as the window's spark opens it, or closed by its close button.
            switch argument {
            case "open": app.showAIModeScreen(from: window)
            case "close": app.onboardingForTesting?.window?.performClose(nil)
            default: check(false, step, "usage: ai-screen open|close"); return true
            }
            await wait(seconds: 0.6)
        case "ai-screen-is":
            // ai-screen-is open|closed
            let open = app.onboardingForTesting?.modeForTesting == "ai"
            check((open ? "open" : "closed") == argument, step, app.onboardingForTesting?.modeForTesting ?? "closed")
        case "ai-screen-press":
            // ai-screen-press <title>: a button, the switch ("AI Mode") or a provider in the menu, as a click would.
            let screen = app.onboardingForTesting
            check(screen?.modeForTesting == "ai" && screen?.pressForTesting(argument) == true, step, "no such control")
            await wait(seconds: 0.6)
        case "ai-screen-reads":
            // ai-screen-reads <text>: a line the AI mode screen shows contains it.
            let lines = app.onboardingForTesting?.modeForTesting == "ai" ? (app.aiSetupModelForTesting?.linesForTesting ?? []) : []
            check(lines.contains { $0.contains(argument) }, step, lines.joined(separator: " | "))
        case "ai-screen-shot":
            // ai-screen-shot <file>: a capture of the AI mode screen, title bar included.
            await wait(seconds: 0.3)
            let screen = app.onboardingForTesting
            check(screen?.modeForTesting == "ai" && screen?.captureForTesting(to: URL(fileURLWithPath: argument)) == true, step)
        case "ai-provider":
            // ai-provider <id>: picks a provider by its identifier, as the menu does.
            guard let model = app.aiSetupModelForTesting, let id = AgentProviderID(rawValue: argument) else {
                check(false, step, "no such provider"); return true
            }
            model.choose(id)
            await wait(seconds: 0.3)
        case "ai-key":
            // ai-key <text>: enters a key. Only ever into keys kept in memory, so no real keychain is touched.
            guard app.agentServicesForTesting?.secrets.isMemoryOnly == true, let model = app.aiSetupModelForTesting else {
                check(false, step, "the key store isn't the memory one"); return true
            }
            model.enterKey(argument)
            await wait(seconds: 0.3)
        case "ai-models-fail":
            // ai-models-fail <failure>|none: what the scripted model answers when asked for its models.
            guard let scripted = app.agentServicesForTesting?.runtime.scriptedClientForTesting else {
                check(false, step, "no scripted model"); return true
            }
            if argument == "none" {
                scripted.modelsFailure = nil
            } else if let failure = AgentFailure(rawValue: argument) {
                scripted.modelsFailure = failure
            } else {
                check(false, step, "no such failure")
            }
        case "ai-state-is":
            // ai-state-is <connection>: the provider's state, waiting up to 10 seconds for it.
            let model = app.aiSetupModelForTesting
            let deadline = Date().addingTimeInterval(10)
            while model?.connectionForTesting != argument, Date() < deadline { await wait(seconds: 0.1) }
            check(model?.connectionForTesting == argument, step, model?.connectionForTesting ?? "no model")
        default:
            return false
        }
        return true
    }
}
#endif
