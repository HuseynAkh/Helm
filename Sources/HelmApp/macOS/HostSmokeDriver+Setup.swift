#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for the onboarding and its steps. Everything here runs against the fixture's stand-ins: the file viewer
/// and Dock switches, the permission and the mover change nothing outside Helm, open nothing and never quit, and
/// macOS's Quit & Reopen is stood in for in this one process (`setup-quit-reopen`).
extension HostSmokeDriver {
    /// System Settings panes the stand-in had opened when `panes-mark` ran.
    private static var paneBaseline = 0

    static func performSetupVerb(_ verb: String, _ argument: String, step: String,
                                 window: BrowserWindowController, app: AppController) async -> Bool {
        let model = app.onboardingForTesting?.model
        switch verb {
        case "setup-step":
            // setup-step welcome|access|viewer|ai|done|closed: the onboarding's step on show.
            let shown = app.onboardingForTesting?.stepForTesting ?? "closed"
            check(shown == argument, step, shown)
        case "setup-steps":
            // setup-steps <steps, in order>: the onboarding's steps, as its step indicator counts them.
            let steps = app.onboardingForTesting.map { $0.isSetupShown ? $0.model.steps.map(\.rawValue).joined(separator: ",") : "closed" } ?? "closed"
            check(steps == argument, step, steps)
        case "setup-progress":
            // setup-progress <step:steps:flags>|none: how far the onboarding got, as Settings keeps it for the next launch.
            let kept = window.dependencies.settings.snapshot.string(.setupProgress)
            check((kept.isEmpty ? "none" : kept) == argument, step, kept.isEmpty ? "none" : kept)
        case "setup-quit-reopen":
            // setup-quit-reopen granted|same: what macOS's Quit & Reopen does, stood in for in this process. Helm quits as
            // it would, with the onboarding open; with granted, the stand-in permission turns on only then, as macOS
            // applies Full Disk Access to the next launch; and that launch carries on. Nothing really quits.
            guard let privacy = app.privacyForTesting else { check(false, step, "not a fixture run"); return true }
            await app.access.quitAndReopenForTesting { if argument == "granted" { privacy.status = .granted } }
            await wait(seconds: 0.8)
        case "onboarding-size":
            // onboarding-size <width>x<height>: the window's content, the same size on every step of the onboarding.
            let size = app.onboardingForTesting?.window?.contentView?.frame.size
            let text = size.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" } ?? "closed"
            check(text == argument, step, text)
        case "setup-summary":
            // setup-summary <on|off for each line of the done step, in order>
            let lines = app.onboardingForTesting?.model.summary.map { $0.on ? "on" : "off" }.joined(separator: ",") ?? "closed"
            check(lines == argument, step, lines)
        case "setup-ai-reads":
            // setup-ai-reads <text>: a line the onboarding's AI step shows contains it.
            let onStep = app.onboardingForTesting?.stepForTesting == "ai"
            let lines = onStep ? (app.aiSetupModelForTesting?.linesForTesting ?? []) : []
            check(lines.contains { $0.contains(argument) }, step, lines.joined(separator: " | "))
        case "setup-rows":
            // setup-rows viewer|access|move|none: the rows on the step on show.
            let rows = model.map { names($0.rows) } ?? "closed"
            check(rows == argument, step, rows)
        case "setup-row":
            // setup-row <row> pending|working|waiting|done|failed
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2, let model, let row = SetupRow(rawValue: bits[0]) else { check(false, step, "usage, or no window"); return true }
            let state = model.state(of: row).name
            check(state == bits[1], step, state)
        case "setup-checked":
            // setup-checked <rows whose checkbox is ticked>|none. A row that's already done has no checkbox.
            guard let model else { check(false, step, "no window"); return true }
            let ticked = names(model.rows.filter { model.hasCheckbox($0) && model.isChecked($0) })
            check(ticked == argument, step, ticked)
        case "setup-check":
            // setup-check <row> on|off: clicks the row's checkbox.
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2, let model, let row = SetupRow(rawValue: bits[0]), model.hasCheckbox(row), model.canChoose else {
                check(false, step, "no checkbox to click"); return true
            }
            model.setChecked(row, bits[1] == "on")
            await wait(seconds: 0.2)
        case "setup-buttons":
            // setup-buttons <titles, left to right>: the footer's buttons.
            guard let model else { check(false, step, "no window"); return true }
            let titles = ([model.backTitle, model.secondaryTitle].compactMap { $0 } + [model.primaryTitle]).joined(separator: ",")
            check(titles == argument, step, titles)
        case "setup-first-launch":
            // What the first launch does, which a fixture run otherwise skips: opens the onboarding, unless it's been
            // through already or nothing is left to do, or carries on from where a quit left it.
            app.access.openOnFirstLaunch()
            await wait(seconds: 0.6)
        case "setup-continue":
            // setup-continue <rows>: as the copy that was just moved into Applications opens, with --continue-setup.
            app.access.continueSetup(SetupRow.rows(fromFlag: argument))
            await wait(seconds: 0.8)
        case "setup-launch":
            // What a launch without the flag does about the welcome, as when the copy in Applications is opened by hand.
            // A fixture run skips the first launch's onboarding, so this only carries on with rows the move saved.
            app.access.showWelcomeIfNeeded()
            await wait(seconds: 0.8)
        case "setup-build":
            // setup-build <identity>|none: the build the stand-in permission says is running, as its code signature's
            // designated requirement would. With none, only whether setup was seen counts.
            guard let privacy = app.privacyForTesting else { check(false, step, "not a fixture run"); return true }
            privacy.buildIdentity = argument == "none" ? nil : argument
        case "setup-built":
            // setup-built <identity>|none: the build kept as the one that last went through setup.
            let kept = window.dependencies.settings.snapshot.string(.setupBuild)
            check((kept.isEmpty ? "none" : kept) == argument, step, kept.isEmpty ? "none" : kept)
        case "setup-owed":
            // setup-owed yes|no: whether a person's launch would show setup before any window now.
            let owed = app.access.setupOwed ? "yes" : "no"
            check(owed == argument, step, owed)
        case "setup-note":
            // setup-note <row> <words>|none: the line about folder access on that row's step.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let model, let row = SetupRow(rawValue: bits[0]) else { check(false, step, "usage, or no window"); return true }
            let note = model.folderNote(row) ?? "none"
            check(note == bits[1], step, note)
        case "setup-carried":
            // setup-carried <rows saved for the copy in Applications>|none
            let saved = window.dependencies.settings.snapshot.string(.setupCarriedRows)
            check((saved.isEmpty ? "none" : saved) == argument, step, saved.isEmpty ? "none" : saved)
        case "setup-unavailable":
            // setup-unavailable <rows that can't be done from where this copy runs>|none
            guard let model else { check(false, step, "no window"); return true }
            let rows = names(model.rows.filter { !model.isAvailable($0) })
            check(rows == argument, step, rows)
        case "setup-preview":
            // setup-preview move|translocated|none: the stand-in mover says Helm runs from a disk image (or macOS's
            // temporary copy), so the move row shows.
            guard let mover = app.moverForTesting else { check(false, step, "not a fixture run"); return true }
            mover.placement = argument == "move" ? .diskImage : argument == "translocated" ? .translocated : .applications
            model?.refresh()
            await wait(seconds: 0.4)
        case "setup-voiceover":
            // setup-voiceover on|off: whether the welcome window takes VoiceOver to be running. Only a stand-in.
            app.access.voiceOverForTesting = argument == "on"
        case "onboarding-announced":
            // onboarding-announced <words>: what the welcome window last said to VoiceOver contains them.
            let said = model?.lastAnnouncement ?? "nothing"
            check(said.contains(argument), step, said)
        case "setup-moves":
            let moves = app.moverForTesting?.moves ?? -1
            check(moves == Int(argument), step, "\(moves)")
        case "setup-relaunched":
            // setup-relaunched <rows the moved copy was asked to carry on with>|none
            let last = app.moverForTesting?.relaunches.last.map { names($0) } ?? "none"
            check(last == argument, step, last)
        case "viewer-is":
            // viewer-is helm|finder: who the stand-in says the file viewer is.
            let viewer = app.fileViewerForTesting?.isHelmDefault == true ? "helm" : "finder"
            check(viewer == argument, step, viewer)
        case "dock-is":
            // dock-is first|not-first: where the stand-in says Helm is in the Dock.
            let dock = app.fileViewerForTesting?.isFirstInDock == true ? "first" : "not-first"
            check(dock == argument, step, dock)
        case "panes-mark":
            paneBaseline = app.privacyForTesting?.openedPanes.count ?? 0
        case "panes-opened":
            // panes-opened <count>: System Settings panes opened since panes-mark.
            let count = (app.privacyForTesting?.openedPanes.count ?? 0) - paneBaseline
            check(count == Int(argument), step, "\(count)")
        default: return false
        }
        return true
    }

    private static func names(_ rows: [SetupRow]) -> String { SetupRow.flagValue(rows) }
}
#endif
