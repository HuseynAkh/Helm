#if os(macOS)
import AppKit
import Foundation
import XCTest
import HelmAgent
import HelmCore
import HelmPersistence
import HelmTestKit
@testable import HelmUI

/// A model with stand-ins for everything it could change: the permission, the file viewer and Dock, the mover, and AI
/// mode's settings, keys and provider. Nothing here opens System Settings, quits or reaches a network.
@MainActor private final class SetupRig {
    let privacy: MemoryPrivacyAccess
    let role: any FileViewerRegistering
    let mover: MemoryAppMover
    let center: PermissionCenter
    let model: OnboardingModel
    let settings: SettingsStore
    let ai: AISetupModel?
    var closed = 0
    var seen = 0
    /// What the move saved for the copy in Applications, in order; nil is a clear.
    var carried: [[SetupRow]?] = []
    /// How far the onboarding got, each time it was kept.
    var saved: [OnboardingProgress] = []
    var refused = 0
    var voiceOver = false
    var said: [String] = []

    init(access: PrivacyAccessStatus = .denied, placement: AppPlacement = .applications,
         appURL: URL? = URL(fileURLWithPath: "/Applications/Helm.app"), withViewer: Bool = true,
         role: (any FileViewerRegistering)? = nil, withAI: Bool = true) {
        privacy = MemoryPrivacyAccess(status: access, appURL: appURL)
        mover = MemoryAppMover(placement: placement)
        center = PermissionCenter(provider: privacy)
        self.role = role ?? MemoryFileViewerRole()
        settings = SettingsStore(storage: OnboardingAIMemory())
        let ai = withAI ? AISetupModel(settings: settings, services: .standIn(home: URL(fileURLWithPath: "/home/helm"), clock: FakeClock())) : nil
        self.ai = ai
        model = OnboardingModel(permissions: center, fileViewer: withViewer ? FileViewerModel(role: self.role) : nil, mover: mover)
        model.aiSource = { ai }
        model.finishDelay = 0
        model.close = { [unowned self] in self.closed += 1; self.model.closed() }
        model.seen = { [unowned self] in self.seen += 1 }
        model.carry = { [unowned self] rows in self.carried.append(rows) }
        model.saveProgress = { [unowned self] progress in self.saved.append(progress) }
        model.refused = { [unowned self] in self.refused += 1 }
        model.announce = { [unowned self] text in self.said.append(text) }
        model.isVoiceOverRunning = { [unowned self] in self.voiceOver }
    }
    /// Reads the permission, then opens the onboarding afresh at its welcome, as Help › Set Up Helm… does.
    func open() async {
        await center.refresh()
        model.begin(.setup)
    }
    /// What the window does when the permission changes.
    func access(_ status: PrivacyAccessStatus) async {
        privacy.status = status
        await center.refresh()
        model.permissionsChanged()
    }
    /// Presses `title`, then waits for the step's work and for a step that comes by itself.
    @discardableResult func press(_ title: String) async -> Bool {
        let pressed = model.press(title)
        await model.work?.value
        try? await Task.sleep(nanoseconds: 30_000_000)
        return pressed
    }
    /// The AI step's provider answers: the switch on and a key entered.
    func connectAI() async {
        guard let ai else { return }
        ai.setOn(true)
        ai.enterKey("test-key-for-the-onboarding")
        await ai.settle()
    }
}

/// macOS taking its time over the folder handler, as `setDefaultApplication` can. Answers when told to.
@MainActor private final class SlowRole: FileViewerRegistering {
    var isHelmDefault = false
    var opensAtLogin = false
    var isFirstInDock = false
    var canRegister: Bool { true }
    private var pending: (@MainActor (String?) -> Void)?
    func makeHelmDefault(_ done: @escaping @MainActor (String?) -> Void) { isHelmDefault = true; pending = done }
    func restoreFinder(_ done: @escaping @MainActor (String?) -> Void) { isHelmDefault = false; done(nil) }
    func setOpensAtLogin(_ on: Bool) -> String? { opensAtLogin = on; return nil }
    func setFirstInDock(_ on: Bool) -> String? { isFirstInDock = on; return nil }
    func answer() { pending?(nil); pending = nil }
}

/// The onboarding without a window: its steps in order, Back and Continue, what each step does through the stand-ins,
/// the AI step's Not Now and Continue, the move going first, and how far it got being kept for the next launch.
@MainActor final class OnboardingModelTests: XCTestCase {
    func testTheStepsComeInOrderAndOnlyThoseThatApply() async {
        let rig = SetupRig()
        await rig.open()
        XCTAssertEqual(rig.model.mode, .setup)
        XCTAssertEqual(rig.model.steps, [.welcome, .access, .viewer, .ai, .done])
        XCTAssertEqual(rig.model.step, .welcome)
        XCTAssertEqual(rig.model.rows, [], "Helm in Applications has no move")
        XCTAssertEqual(rig.model.primaryTitle, "Continue")
        XCTAssertNil(rig.model.backTitle, "nothing before the welcome")
        XCTAssertNil(rig.model.secondaryTitle)
        XCTAssertEqual(rig.model.headerLine, AgentText.setupHeader)
        XCTAssertFalse(rig.model.nothingToDo)
        // Running from a disk image adds the move to the welcome, ticked.
        rig.mover.placement = .diskImage
        XCTAssertEqual(rig.model.rows, [.moveToApplications])
        XCTAssertTrue(rig.model.hasCheckbox(.moveToApplications))
        XCTAssertTrue(rig.model.isChecked(.moveToApplications))
        // Without AI mode's model there's no AI step; outside an app bundle there's nothing to switch on; without the
        // switches there's no file viewer step.
        let plain = SetupRig(withAI: false)
        await plain.open()
        XCTAssertEqual(plain.model.steps, [.welcome, .access, .viewer, .done])
        let bare = SetupRig(appURL: nil, withViewer: false, withAI: false)
        await bare.open()
        XCTAssertEqual(bare.model.steps, [.welcome, .done])
        XCTAssertTrue(bare.model.nothingToDo)
        // A launch leaves out what's done already, and AI mode once it's been seen.
        let done = SetupRig(access: .granted)
        done.role.makeHelmDefault { _ in }
        _ = done.role.setFirstInDock(true)
        await done.open()
        XCTAssertEqual(done.model.plannedSteps(skippingDone: true), [.welcome, .ai, .done])
        XCTAssertEqual(done.model.plannedSteps(skippingDone: true, includesAI: false), [.welcome, .done])
        XCTAssertEqual(done.model.plannedSteps(skippingDone: false), [.welcome, .access, .viewer, .ai, .done],
                       "Help › Set Up Helm… shows them all")
        // The guide is the Full Disk Access row on its own, with no checkbox.
        rig.model.begin(.guide)
        XCTAssertEqual(rig.model.rows, [.fullDiskAccess])
        XCTAssertFalse(rig.model.hasCheckbox(.fullDiskAccess))
        XCTAssertNil(rig.model.backTitle)
    }

    func testContinueAndBackGoStepByStepAndEachStepIsKept() async {
        let rig = SetupRig()
        await rig.open()
        XCTAssertEqual(rig.saved.last, OnboardingProgress(step: .welcome, steps: [.welcome, .access, .viewer, .ai, .done]))
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .access)
        XCTAssertEqual(rig.model.stepIndex, 1)
        XCTAssertEqual(rig.model.backTitle, "Back")
        XCTAssertEqual(rig.said.last, "Full Disk Access. Step 2 of 5.")
        XCTAssertEqual(rig.saved.last?.step, .access)
        await rig.press("Back")
        XCTAssertEqual(rig.model.step, .welcome)
        XCTAssertEqual(rig.saved.last?.step, .welcome)
        let backs = rig.saved.count
        let wentBack = await rig.press("Back")
        XCTAssertFalse(wentBack, "no Back on the welcome")
        XCTAssertEqual(rig.saved.count, backs)
        // Continue past every step: nothing is done unless asked for, and Get Started ends it.
        await rig.press("Continue")
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .viewer)
        rig.model.setChecked(.fileViewer, false)
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .ai)
        XCTAssertEqual(rig.model.secondaryTitle, "Not Now")
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .done)
        XCTAssertEqual(rig.model.primaryTitle, "Get Started")
        XCTAssertEqual(rig.seen, 0, "the onboarding isn't through until it ends")
        XCTAssertEqual(rig.closed, 0)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertEqual(rig.model.summary.map(\.on), [false, false, false])
        await rig.press("Get Started")
        XCTAssertEqual(rig.seen, 1)
        XCTAssertEqual(rig.closed, 1)
        XCTAssertEqual(rig.mover.moves, 0)
        XCTAssertTrue(rig.mover.relaunches.isEmpty)
    }

    func testFullDiskAccessOpensSystemSettingsOnlyFromItsButtonAndGoesOnOnceItsOn() async throws {
        let rig = SetupRig()
        await rig.open()
        let openedEarly = await rig.press("Open System Settings")
        XCTAssertFalse(openedEarly, "only on its own step")
        await rig.press("Continue")
        XCTAssertEqual(rig.model.rows, [.fullDiskAccess])
        XCTAssertFalse(rig.model.hasCheckbox(.fullDiskAccess), "only the person can switch it on")
        XCTAssertTrue(rig.model.stepOpensSettings)
        XCTAssertEqual(rig.model.folderNote(.fullDiskAccess), SetupRow.fullDiskAccess.folderNote)
        XCTAssertEqual(OnboardingModel.reopenNote, "macOS will ask to quit and reopen Helm, and setup continues after.")
        XCTAssertFalse(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty, "the step opens nothing by itself")
        let opened = await rig.press("Open System Settings")
        XCTAssertTrue(opened)
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.isWaitingForAccess)
        XCTAssertEqual(rig.model.statusLine, "Waiting for Full Disk Access")
        XCTAssertEqual(rig.saved.last, OnboardingProgress(step: .access, steps: [.welcome, .access, .viewer, .ai, .done], askedForAccess: true))
        // Access arrives: a check mark, a moment to see it, and the next step comes by itself. Helm never quits or
        // reopens itself for it.
        await rig.access(.granted)
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .done)
        XCTAssertNil(rig.model.folderNote(.fullDiskAccess))
        XCTAssertEqual(rig.said.last, "Full Disk Access is on.")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.model.step, .viewer)
        XCTAssertEqual(rig.mover.moves, 0)
        XCTAssertTrue(rig.mover.relaunches.isEmpty)
        XCTAssertEqual(rig.closed, 0)
        // Continue without access goes on and opens nothing.
        let skip = SetupRig()
        await skip.open()
        await skip.press("Continue")
        await skip.press("Continue")
        XCTAssertEqual(skip.model.step, .viewer)
        XCTAssertTrue(skip.privacy.openedPanes.isEmpty)
    }

    func testTheFileViewerStepDoesItsRowOnContinue() async throws {
        let rig = SetupRig()
        await rig.open()
        await rig.press("Continue")
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .viewer)
        XCTAssertEqual(rig.model.rows, [.fileViewer])
        XCTAssertTrue(rig.model.hasCheckbox(.fileViewer))
        XCTAssertTrue(rig.model.isChecked(.fileViewer))
        XCTAssertFalse(rig.role.isHelmDefault, "nothing changes until Continue")
        await rig.press("Continue")
        XCTAssertTrue(rig.role.isHelmDefault)
        XCTAssertTrue(rig.role.isFirstInDock)
        XCTAssertFalse(rig.role.opensAtLogin, "only what the row says")
        XCTAssertTrue(rig.said.contains("Helm now opens instead of Finder."), "\(rig.said)")
        XCTAssertEqual(rig.model.step, .ai, "the next step comes once the check mark has shown")
        // Back shows it done, with no box.
        await rig.press("Back")
        XCTAssertEqual(rig.model.state(of: .fileViewer), .done)
        XCTAssertFalse(rig.model.hasCheckbox(.fileViewer))
        // Unticked, Continue leaves it alone.
        let other = SetupRig()
        await other.open()
        await other.press("Continue")
        await other.press("Continue")
        other.model.setChecked(.fileViewer, false)
        await other.press("Continue")
        XCTAssertEqual(other.model.step, .ai)
        XCTAssertFalse(other.role.isHelmDefault)
        XCTAssertFalse(other.role.isFirstInDock)
    }

    func testTheAIStepsNotNowLeavesAIModeOffAndGoesOn() async throws {
        let rig = SetupRig()
        let ai = try XCTUnwrap(rig.ai)
        await rig.open()
        rig.model.showAIStep()
        XCTAssertEqual(rig.model.step, .ai)
        XCTAssertTrue(rig.model.aiSetup === ai)
        XCTAssertEqual(rig.model.headerLine, AgentText.aiSentence)
        XCTAssertEqual(rig.model.backTitle, "Back")
        XCTAssertEqual(rig.model.secondaryTitle, "Not Now")
        XCTAssertEqual(rig.model.primaryTitle, "Continue")
        XCTAssertEqual(AIModeScreen.parts(for: ai, embedded: true), [.titleRow], "the switch; the header has the sentence")
        let switched = await rig.press(AgentText.settingsAIMode)
        XCTAssertTrue(switched, "the switch, by its label")
        XCTAssertTrue(ai.isOn)
        XCTAssertEqual(AIModeScreen.parts(for: ai, embedded: true), [.titleRow, .provider, .key, .state, .consent],
                       "the AI Mode screen's parts, without its Done")
        let leftOff = await rig.press("Not Now")
        XCTAssertTrue(leftOff)
        XCTAssertFalse(ai.isOn)
        XCTAssertTrue(rig.settings.snapshot.bool(.aiIntroSeen))
        XCTAssertEqual(rig.model.step, .done)
        XCTAssertNil(ai.donePressed, "the step let go of the screen's Done")
        XCTAssertEqual(rig.model.summary.last?.on, false)
    }

    func testTheAIStepsContinueGoesOnOnlyWhenOffOrConnected() async throws {
        let rig = SetupRig()
        let ai = try XCTUnwrap(rig.ai)
        await rig.open()
        rig.model.showAIStep()
        // With the switch off, Continue goes on and AI mode stays off.
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .done)
        XCTAssertFalse(ai.isOn)
        // With the switch on and no key, it stays, as Done does on the AI Mode screen, and says why.
        await rig.press("Back")
        XCTAssertEqual(rig.model.step, .ai)
        ai.setOn(true)
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .ai)
        XCTAssertEqual(rig.refused, 1)
        XCTAssertFalse(rig.model.isWorking)
        // Connected, it goes on and AI mode stays on.
        await rig.connectAI()
        XCTAssertEqual(ai.connectionForTesting, "connected")
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .done)
        XCTAssertTrue(ai.isOn)
        XCTAssertTrue(rig.settings.snapshot.bool(.aiModeEnabled))
        XCTAssertEqual(rig.model.summary.last?.on, true)
        // The screen's own Done, pressed from a script, does what Continue does.
        await rig.press("Back")
        XCTAssertNotNil(ai.donePressed)
        XCTAssertTrue(ai.pressed(AgentText.done))
        await rig.model.work?.value
        XCTAssertEqual(rig.model.step, .done)
        // The footer's Continue, clicked, first asks the screen for what was typed and not yet entered.
        await rig.press("Back")
        let before = rig.model.aiContinueRequests
        rig.model.continuePressed()
        XCTAssertEqual(rig.model.aiContinueRequests, before + 1)
        XCTAssertEqual(rig.model.step, .ai, "the screen hands over its key and presses Done")
    }

    func testClosingPartWayTurnsOffOnlyWhatTheAIStepTurnedOn() async throws {
        let rig = SetupRig()
        let ai = try XCTUnwrap(rig.ai)
        await rig.open()
        rig.model.showAIStep()
        ai.setOn(true)
        await rig.press("Back")
        rig.model.closed()
        XCTAssertFalse(ai.isOn, "only Continue leaves it on")
        // Closed before the AI step, AI mode stays as it was.
        let early = SetupRig()
        let earlyAI = try XCTUnwrap(early.ai)
        await early.connectAI()
        await early.open()
        early.model.closed()
        XCTAssertTrue(earlyAI.isOn)
        // Ready before the step showed, as when Help › Set Up Helm… runs again: left as it was.
        let again = SetupRig()
        let againAI = try XCTUnwrap(again.ai)
        await again.connectAI()
        await again.open()
        again.model.showAIStep()
        again.model.closed()
        XCTAssertTrue(againAI.isOn)
        // Answered with Continue, it stays.
        let answered = SetupRig()
        let answeredAI = try XCTUnwrap(answered.ai)
        await answered.open()
        answered.model.showAIStep()
        await answered.connectAI()
        await answered.press("Continue")
        XCTAssertEqual(answered.model.step, .done)
        answered.model.closed()
        XCTAssertTrue(answeredAI.isOn)
    }

    func testTheMoveGoesFirstAndTheMovedCopyCarriesOnAfterTheWelcome() async {
        let rig = SetupRig(placement: .diskImage)
        rig.mover.quitsOnRelaunch = true
        await rig.open()
        XCTAssertEqual(rig.model.rows, [.moveToApplications])
        await rig.press("Continue")
        XCTAssertEqual(rig.mover.moves, 1)
        XCTAssertEqual(rig.mover.relaunches, [[.moveToApplications]])
        // Saved before anything quits, so the copy carries on even if it's opened by hand: the rows, and the step after
        // the welcome.
        XCTAssertEqual(rig.carried, [[.moveToApplications]])
        let kept = OnboardingProgress(step: .access, steps: [.welcome, .access, .viewer, .ai, .done], moved: true)
        XCTAssertEqual(rig.saved.last, kept)
        // Nothing else changes here: the copy in Applications does the rest, so it points at that copy.
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
        XCTAssertEqual(rig.model.state(of: .moveToApplications), .working, "on its way out")
        XCTAssertEqual(rig.model.step, .welcome)
        // The copy in Applications, opened with --continue-setup, carries on at Full Disk Access.
        let copy = SetupRig()
        await copy.center.refresh()
        copy.model.continueSetup(SetupRow.rows(fromFlag: SetupRow.flagValue(rig.mover.relaunches[0])), resuming: kept)
        XCTAssertEqual(copy.model.step, .access)
        XCTAssertTrue(copy.model.moved)
        XCTAssertEqual(copy.mover.moves, 0)
        await copy.press("Back")
        XCTAssertEqual(copy.model.rows, [.moveToApplications])
        XCTAssertEqual(copy.model.state(of: .moveToApplications), .done)
        // With no progress kept, it starts after the welcome with the steps left to do.
        let fresh = SetupRig()
        await fresh.center.refresh()
        fresh.model.continueSetup([.moveToApplications])
        XCTAssertEqual(fresh.model.step, .access)
        XCTAssertTrue(fresh.model.moved)
        // A copy that still isn't in Applications starts again from the welcome, where the move is.
        let stuck = SetupRig(placement: .translocated)
        await stuck.center.refresh()
        stuck.model.continueSetup([.moveToApplications], resuming: kept)
        XCTAssertEqual(stuck.model.step, .welcome)
        XCTAssertFalse(stuck.model.moved)
        XCTAssertEqual(stuck.model.state(of: .moveToApplications), .pending)
    }

    func testAFailedOrRefusedMoveChangesNothingElse() async {
        let rig = SetupRig(placement: .elsewhere)
        rig.mover.result = .failed("Helm couldn’t be copied to /Applications: the disk is full.")
        await rig.open()
        await rig.press("Continue")
        XCTAssertEqual(rig.model.state(of: .moveToApplications), .failed("Helm couldn’t be copied to /Applications: the disk is full."))
        XCTAssertEqual(rig.model.step, .welcome)
        XCTAssertTrue(rig.mover.relaunches.isEmpty)
        XCTAssertEqual(rig.said.last, "Move to Applications didn’t work. Helm couldn’t be copied to /Applications: the disk is full.")
        // The person can untick the move and go on from where Helm is, which stays put in Downloads.
        XCTAssertTrue(rig.model.canChoose)
        rig.model.setChecked(.moveToApplications, false)
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .access)
        XCTAssertEqual(rig.mover.moves, 1)
        await rig.press("Continue")
        await rig.press("Continue")
        XCTAssertTrue(rig.role.isHelmDefault, "from Downloads, Helm can go in the Dock as it is")
        // Saying no to replacing the Helm already in Applications leaves everything as it was.
        let declined = SetupRig(placement: .elsewhere)
        declined.mover.result = .cancelled
        await declined.open()
        await declined.press("Continue")
        XCTAssertEqual(declined.model.state(of: .moveToApplications), .pending)
        XCTAssertEqual(declined.model.step, .welcome)
        XCTAssertTrue(declined.mover.relaunches.isEmpty)
        XCTAssertTrue(declined.model.canChoose)
    }

    /// Review finding onb-1: from a disk image or macOS's temporary copy, the Dock would point at a copy that goes away,
    /// so Use Helm instead of Finder goes only with the move. The copy in Applications does it.
    func testUseHelmInsteadOfFinderNeedsTheMoveFromACopyThatGoesAway() async {
        for placement in [AppPlacement.translocated, .diskImage] {
            let rig = SetupRig(placement: placement)
            await rig.open()
            rig.model.setChecked(.moveToApplications, false)
            await rig.press("Continue")
            await rig.press("Continue")
            XCTAssertEqual(rig.model.step, .viewer, "\(placement)")
            XCTAssertFalse(rig.model.isAvailable(.fileViewer))
            XCTAssertEqual(rig.model.unavailableReason(.fileViewer), "Only with Move to Applications.")
            XCTAssertTrue(rig.model.hasCheckbox(.fileViewer), "shown, but it can't be ticked")
            XCTAssertFalse(rig.model.isChecked(.fileViewer))
            rig.model.setChecked(.fileViewer, true)
            XCTAssertFalse(rig.model.isChecked(.fileViewer))
            await rig.press("Continue")
            XCTAssertEqual(rig.model.step, .ai)
            XCTAssertFalse(rig.role.isHelmDefault)
            XCTAssertFalse(rig.role.isFirstInDock)
            XCTAssertEqual(rig.mover.moves, 0)
        }
    }

    /// Review finding onb-3: a quit that doesn't happen (the person cancelled it, or the copy didn't open) no longer
    /// leaves the move spinning. The copy in Applications still finds the rows, and trying again only reopens it.
    func testAMoveWhoseQuitIsCancelledCanBeTriedAgain() async {
        let rig = SetupRig(placement: .diskImage)
        await rig.open()
        await rig.press("Continue")
        XCTAssertEqual(rig.mover.relaunches.count, 1)
        guard case .failed(let message) = rig.model.state(of: .moveToApplications) else {
            return XCTFail("the move can't still be working: \(rig.model.state(of: .moveToApplications))")
        }
        XCTAssertEqual(message, "Couldn’t reopen from /Applications, so quit Helm and open it there.")
        XCTAssertTrue(rig.model.canChoose)
        XCTAssertEqual(rig.model.primaryTitle, "Continue")
        XCTAssertEqual(rig.carried.last, [.moveToApplications])
        XCTAssertEqual(rig.saved.last?.step, .welcome, "this copy is still at the welcome")
        // Trying again doesn't copy Helm a second time.
        await rig.press("Continue")
        XCTAssertEqual(rig.mover.moves, 1)
        XCTAssertEqual(rig.mover.relaunches.count, 2)
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
    }

    /// Review finding onb-6: closing the window stops work that's still waiting on macOS. The row in progress finishes,
    /// but the onboarding doesn't move on behind the person's back, and a window opened afterwards starts clean.
    func testClosingStopsWorkThatIsStillRunning() async {
        let slow = SlowRole()
        let rig = SetupRig(role: slow)
        await rig.open()
        await rig.press("Continue")
        await rig.press("Continue")
        XCTAssertTrue(rig.model.press("Continue"))
        // macOS has been asked, and hasn't answered.
        for _ in 0..<50 where !slow.isHelmDefault { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(rig.model.state(of: .fileViewer), .working)
        XCTAssertTrue(rig.model.isWorking)
        XCTAssertFalse(rig.model.press("Back"), "the buttons wait for the work")
        rig.model.closed()
        // Help › Set Up Helm… opens it again before macOS has answered.
        rig.model.begin(.setup)
        slow.answer()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(slow.isHelmDefault)
        XCTAssertTrue(slow.isFirstInDock, "the row that had started is finished, not left half done")
        XCTAssertEqual(rig.model.step, .welcome, "the new onboarding didn't move on")
        XCTAssertFalse(rig.model.isWorking)
    }

    /// Review finding onb-4: Full Disk Access asked for while the onboarding is open goes to its step, with Helm's icon,
    /// and its button changes nothing else.
    func testAskingForAccessWhileTheOnboardingIsOpen() async {
        let rig = SetupRig()
        await rig.open()
        XCTAssertFalse(rig.model.showsAccessHelp)
        rig.model.requestAccessHelp()
        XCTAssertEqual(rig.model.step, .access)
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.accessHelpRequested)
        let opened = await rig.press("Open System Settings")
        XCTAssertTrue(opened)
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertFalse(rig.role.isFirstInDock)
        await rig.access(.granted)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.model.step, .viewer)
        XCTAssertEqual(rig.closed, 0)
    }

    /// Review finding onb-5: the guide turning into the onboarding keeps the wait for Full Disk Access, at its step.
    func testTheGuideBecomesTheAccessStepStillWaiting() async {
        let rig = SetupRig()
        await rig.center.refresh()
        rig.model.begin(.guide)
        XCTAssertTrue(rig.model.press("Open System Settings"))
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        rig.model.switchToSetup()
        XCTAssertEqual(rig.model.mode, .setup)
        XCTAssertEqual(rig.model.step, .access)
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.isWaitingForAccess)
        XCTAssertEqual(rig.model.backTitle, "Back")
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.saved.last?.askedForAccess, true)
        await rig.access(.granted)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.model.step, .viewer, "the wait it kept moves it on")
    }

    /// Review finding onb-5: asked for again just as it was about to move on by itself, the onboarding stays.
    func testAskedForAgainItStays() async throws {
        let rig = SetupRig()
        rig.model.finishDelay = 0.2
        await rig.open()
        await rig.press("Continue")
        await rig.press("Open System Settings")
        await rig.access(.granted)
        XCTAssertTrue(rig.model.isFinishing)
        rig.model.askedForAgain()
        XCTAssertFalse(rig.model.isFinishing)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(rig.model.step, .access)
        // Something changing later doesn't move it on either; Continue does.
        rig.model.refresh()
        XCTAssertFalse(rig.model.isFinishing)
        await rig.press("Continue")
        XCTAssertEqual(rig.model.step, .viewer)
    }

    /// Review finding onb-9: VoiceOver hears each row that's done or didn't work, and the onboarding doesn't move on by
    /// itself while VoiceOver is on. Anyone who can't drag is told about the + button.
    func testChangesAreAnnouncedAndVoiceOverKeepsTheStep() async throws {
        let rig = SetupRig()
        await rig.open()
        XCTAssertTrue(rig.said.isEmpty, "what's done already isn't news")
        await rig.press("Continue")
        await rig.press("Open System Settings")
        await rig.access(.granted)
        XCTAssertEqual(rig.said.last, "Full Disk Access is on.")
        XCTAssertEqual(rig.model.lastAnnouncement, rig.said.last)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.model.step, .viewer)
        XCTAssertEqual(rig.said.last, "Default File Viewer. Step 3 of 5.")
        // With VoiceOver on it says so, and the person goes on.
        let reading = SetupRig()
        reading.voiceOver = true
        await reading.open()
        await reading.press("Continue")
        await reading.press("Open System Settings")
        await reading.access(.granted)
        XCTAssertEqual(reading.said.last, "Full Disk Access is on.")
        XCTAssertFalse(reading.model.isFinishing)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reading.model.step, .access)
        await reading.press("Continue")
        XCTAssertEqual(reading.model.step, .viewer)
        await reading.press("Continue")
        XCTAssertTrue(reading.role.isHelmDefault)
        XCTAssertEqual(reading.model.step, .viewer, "the file viewer step stays too")
        // The way to add Helm without dragging is on Helm's icon, for VoiceOver: the steps beside it leave it out.
        let icon = AppIconDragView(appURL: URL(fileURLWithPath: "/Applications/Helm.app", isDirectory: true), image: NSImage())
        XCTAssertEqual(icon.accessibilityLabel(), "Helm icon: drag it into the Full Disk Access list, or click + there and choose Helm.")
    }

    func testTheGuideStandsAlone() async throws {
        let rig = SetupRig()
        await rig.open()
        rig.model.begin(.guide)
        XCTAssertEqual(rig.model.primaryTitle, "Open System Settings")
        XCTAssertEqual(rig.model.secondaryTitle, "Not Now")
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.isWaitingForAccess)
        XCTAssertEqual(rig.model.statusLine, "Full Disk Access is off")
        XCTAssertFalse(rig.model.press("Continue"))
        XCTAssertTrue(rig.model.press("Open System Settings"))
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.model.statusLine, "Waiting for Full Disk Access")
        XCTAssertEqual(rig.model.primaryTitle, "Done")
        // Its row can open System Settings again.
        XCTAssertTrue(rig.model.press("Open System Settings"))
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess, .fullDiskAccess])
        XCTAssertFalse(rig.role.isHelmDefault, "the guide never touches the file viewer")
        XCTAssertEqual(rig.seen, 0)
        XCTAssertEqual(rig.saved.count, 1, "only the onboarding that opened first was kept, never the guide")
        await rig.access(.granted)
        XCTAssertEqual(rig.model.statusLine, "Full Disk Access is on")
        XCTAssertFalse(rig.model.showsAccessHelp)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.closed, 1)
    }

    func testOutsideAnAppBundleThereIsNothingToSwitchOn() async {
        let rig = SetupRig(appURL: nil, withAI: false)
        await rig.open()
        XCTAssertEqual(rig.model.steps, [.welcome, .viewer, .done])
        rig.model.begin(.guide)
        XCTAssertTrue(rig.model.isOutsideApp)
        XCTAssertFalse(rig.model.isWaitingForAccess)
        XCTAssertEqual(rig.model.primaryTitle, "Done")
        XCTAssertFalse(rig.model.press("Open System Settings"))
        rig.model.openFullDiskAccess()
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
    }

    /// After macOS's Quit & Reopen, or any quit, the onboarding carries on from the step it kept: past Full Disk Access
    /// once it's on, waiting again while it isn't, with the same steps, and back at the welcome for a copy left behind
    /// after a move.
    func testResumingCarriesOnFromTheKeptStep() async {
        let steps: [OnboardingStep] = [.welcome, .access, .viewer, .ai, .done]
        let reopened = SetupRig(access: .granted)
        await reopened.center.refresh()
        reopened.model.resume(OnboardingProgress(step: .access, steps: steps, askedForAccess: true))
        XCTAssertEqual(reopened.model.mode, .setup)
        XCTAssertEqual(reopened.model.step, .viewer, "Full Disk Access is on now, so the next step")
        XCTAssertEqual(reopened.model.steps, steps, "the same steps, though access is done")
        XCTAssertEqual(reopened.saved.last?.step, .viewer)
        XCTAssertTrue(reopened.privacy.openedPanes.isEmpty, "System Settings isn't opened again")
        // Quit for another reason while it waited: back at the step, still waiting, and it moves on once access is on.
        let waiting = SetupRig()
        await waiting.center.refresh()
        waiting.model.resume(OnboardingProgress(step: .access, steps: steps, askedForAccess: true))
        XCTAssertEqual(waiting.model.step, .access)
        XCTAssertEqual(waiting.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertTrue(waiting.model.showsAccessHelp)
        await waiting.access(.granted)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(waiting.model.step, .viewer)
        // Any other step is where it carries on, and a step that no longer applies is left out.
        let later = SetupRig(withAI: false)
        await later.center.refresh()
        later.model.resume(OnboardingProgress(step: .ai, steps: steps))
        XCTAssertEqual(later.model.steps, [.welcome, .access, .viewer, .done])
        XCTAssertEqual(later.model.step, .done)
        // A copy left behind after a move starts again from the welcome.
        let behind = SetupRig(placement: .diskImage)
        await behind.center.refresh()
        behind.model.resume(OnboardingProgress(step: .access, steps: steps, moved: true))
        XCTAssertEqual(behind.model.step, .welcome)
        XCTAssertEqual(behind.model.rows, [.moveToApplications])
    }
}

/// How far the onboarding got, as Settings keeps it: step names, commas and colons, read back the same.
final class OnboardingProgressTests: XCTestCase {
    func testItReadsBackWhatItWrites() {
        let progress = OnboardingProgress(step: .viewer, steps: [.welcome, .access, .viewer, .ai, .done], askedForAccess: true, moved: true)
        XCTAssertEqual(progress.text, "viewer:welcome,access,viewer,ai,done:asked,moved")
        XCTAssertEqual(OnboardingProgress(text: progress.text), progress)
        let plain = OnboardingProgress(step: .welcome, steps: [.welcome, .done])
        XCTAssertEqual(plain.text, "welcome:welcome,done:")
        XCTAssertEqual(OnboardingProgress(text: plain.text), plain)
        XCTAssertEqual(SettingsSchema.validated(.string(progress.text), for: .setupProgress), .string(progress.text))
    }

    func testAnythingElseReadsAsNoOnboardingUnderWay() {
        for text in ["", "access", "access:welcome,done:", "lobby:welcome,lobby,done:", "welcome:access,done:",
                     "welcome:welcome,access:", "welcome:welcome,welcome,done:", "welcome:welcome,done", "a:b:c:d"] {
            XCTAssertNil(OnboardingProgress(text: text), text)
        }
        XCTAssertEqual(OnboardingProgress(text: "welcome:welcome,later,done:soon")?.steps, [.welcome, .done],
                       "names it doesn't know are left out")
    }
}

/// The onboarding window: one size for every step, through once it ends (Get Started or closing it), never by quitting,
/// which keeps the step for the next launch. The guide never counts, and the window floats over System Settings only
/// while that helps. AI mode is a step in the window's own appearance; on its own, the AI Mode screen stays dark.
@MainActor final class OnboardingWindowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func controller(_ privacy: MemoryPrivacyAccess? = nil, role: MemoryFileViewerRole? = nil,
                            ai: AISetupModel? = nil) -> OnboardingWindowController {
        let controller = OnboardingWindowController(permissions: PermissionCenter(provider: privacy ?? MemoryPrivacyAccess()),
                                                    fileViewer: FileViewerModel(role: role ?? MemoryFileViewerRole()), mover: MemoryAppMover())
        controller.model.isVoiceOverRunning = { false }
        controller.model.finishDelay = 0
        if let ai { controller.model.aiSource = { ai } }
        return controller
    }

    private func aiModel() -> (AISetupModel, SettingsStore) {
        let settings = SettingsStore(storage: OnboardingAIMemory())
        return (AISetupModel(settings: settings, services: .standIn(home: URL(fileURLWithPath: "/home/helm"), clock: FakeClock())), settings)
    }

    func testTheOnboardingIsThroughOnceItEndsAndQuittingKeepsItsStep() async throws {
        let controller = controller()
        defer { controller.close() }
        var seen = 0
        var kept: [OnboardingProgress] = []
        controller.onSeen = { seen += 1 }
        controller.onProgress = { kept.append($0) }
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        XCTAssertEqual(controller.stepForTesting, "welcome")
        XCTAssertEqual(seen, 0, "opening isn't going through it")
        XCTAssertTrue(controller.pressForTesting("Continue"))
        XCTAssertEqual(kept.last?.step, .access)
        // Quitting, as macOS's Quit & Reopen does, counts nothing: the step is kept for the next launch.
        controller.quitting()
        XCTAssertEqual(seen, 0)
        XCTAssertEqual(controller.stepForTesting, "access")
        controller.endWithProcess()
        XCTAssertEqual(seen, 0, "the window going with the process isn't going through it")
        XCTAssertEqual(controller.modeForTesting, "closed")
        // Closing it is going through it, once each time it opens.
        controller.show(.setup, activate: false)
        controller.close()
        XCTAssertEqual(seen, 1)
        controller.close()
        XCTAssertEqual(seen, 1)
        // So is Get Started.
        controller.show(.setup, activate: false)
        while controller.stepForTesting != "done" {
            controller.model.setChecked(.fileViewer, false)
            XCTAssertTrue(controller.pressForTesting("Continue"))
            await controller.model.work?.value
        }
        XCTAssertTrue(controller.pressForTesting("Get Started"))
        XCTAssertEqual(seen, 2)
        XCTAssertEqual(controller.modeForTesting, "closed")
        // The guide on its own isn't the welcome.
        controller.show(.guide, activate: false)
        XCTAssertEqual(controller.modeForTesting, "guide")
        controller.quitting()
        controller.close()
        XCTAssertEqual(seen, 2)
    }

    func testEveryStepIsTheSameSize() async throws {
        let (ai, _) = aiModel()
        let controller = controller(ai: ai)
        defer { controller.close() }
        controller.show(.setup, activate: false)
        let window = try XCTUnwrap(controller.window)
        var sizes: Set<String> = []
        var frames: Set<String> = []
        var shown: [String] = []
        while true {
            try await Task.sleep(nanoseconds: 50_000_000)
            let size = try XCTUnwrap(window.contentView?.frame.size)
            sizes.insert("\(Int(size.width))x\(Int(size.height))")
            frames.insert("\(Int(window.frame.minX)),\(Int(window.frame.maxY))")
            shown.append(controller.stepForTesting)
            XCTAssertNil(window.appearance, "every step, AI mode's included, follows the Mac")
            XCTAssertEqual(window.title, controller.model.step.title)
            if controller.stepForTesting == "done" { break }
            if controller.stepForTesting == "ai" {
                ai.setOn(true)
                try await Task.sleep(nanoseconds: 50_000_000)
                sizes.insert("\(Int(window.contentView?.frame.width ?? 0))x\(Int(window.contentView?.frame.height ?? 0))")
                ai.setOn(false)
            }
            controller.model.setChecked(.fileViewer, false)
            XCTAssertTrue(controller.pressForTesting("Continue"))
            await controller.model.work?.value
        }
        XCTAssertEqual(shown, ["welcome", "access", "viewer", "ai", "done"])
        XCTAssertEqual(sizes, ["\(Int(OnboardingView.width))x\(Int(OnboardingView.stepHeight))"])
        XCTAssertEqual(frames.count, 1, "the window stays where it is")
        // The AI Mode screen on its own is still dark and fits what it shows.
        controller.close()
        controller.showAIMode(ai, activate: false) { _ in }
        XCTAssertEqual(controller.modeForTesting, "ai")
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertNotEqual(window.contentView?.frame.height, OnboardingView.stepHeight)
    }

    func testAskingForTheGuideGoesToTheAccessStep() {
        let controller = controller()
        defer { controller.close() }
        controller.show(.setup, activate: false)
        controller.show(.guide, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        XCTAssertEqual(controller.stepForTesting, "access")
        XCTAssertTrue(controller.model.showsAccessHelp)
        controller.close()
        controller.show(.guide, activate: false)
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        XCTAssertEqual(controller.stepForTesting, "access")
    }

    /// Review finding onb-4: a card's Grant Access… while the onboarding is open shows the Full Disk Access step, whose
    /// button opens System Settings and changes nothing else.
    func testTheOnboardingAskedForTheGuideOpensSystemSettingsOnlyFromItsButton() {
        let privacy = MemoryPrivacyAccess()
        let role = MemoryFileViewerRole()
        let controller = controller(privacy, role: role)
        defer { controller.close() }
        controller.show(.setup, activate: false)
        XCTAssertFalse(controller.pressForTesting("Open System Settings"))
        controller.show(.guide, activate: false)
        XCTAssertTrue(privacy.openedPanes.isEmpty)
        XCTAssertTrue(controller.pressForTesting("Open System Settings"))
        XCTAssertEqual(privacy.openedPanes, [.fullDiskAccess])
        XCTAssertFalse(role.isHelmDefault)
        XCTAssertFalse(role.isFirstInDock)
        XCTAssertTrue(controller.model.permissions.isWatching, "it watches for the switch")
    }

    /// Review finding onb-5: Help › Set Up Helm… while the guide waits keeps the wait, and asked for again just before it
    /// moves on by itself, the window stays.
    func testAskingAgainKeepsWhatTheWindowIsDoing() async throws {
        let privacy = MemoryPrivacyAccess()
        let controller = controller(privacy)
        defer { controller.close() }
        controller.model.finishDelay = 0.2
        controller.show(.guide, activate: false)
        XCTAssertTrue(controller.pressForTesting("Open System Settings"))
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        XCTAssertEqual(controller.stepForTesting, "access")
        XCTAssertEqual(controller.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertTrue(controller.model.permissions.isWatching)
        XCTAssertEqual(privacy.openedPanes, [.fullDiskAccess])
        privacy.status = .granted
        await controller.model.permissions.refresh()
        XCTAssertTrue(controller.model.isFinishing)
        controller.show(.setup, activate: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(controller.stepForTesting, "access")
    }

    /// Review finding onb-7: hidden along with Helm (Command-H), the onboarding is still open, so quitting then keeps its
    /// step, and asked for again it keeps what it was doing.
    func testQuittingWhileHelmIsHiddenKeepsTheStep() async throws {
        let app = NSApplication.shared
        let controller = controller()
        defer { controller.close(); app.unhide(nil) }
        var seen = 0
        var kept: [OnboardingProgress] = []
        controller.onSeen = { seen += 1 }
        controller.onProgress = { kept.append($0) }
        controller.show(.setup, activate: false)
        XCTAssertTrue(controller.pressForTesting("Continue"))
        XCTAssertTrue(controller.pressForTesting("Continue"))
        app.hide(nil)
        for _ in 0..<20 where controller.window?.isVisible == true { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(controller.stepForTesting, "viewer")
        controller.quitting()
        XCTAssertEqual(seen, 0)
        XCTAssertEqual(kept.last?.step, .viewer)
        // Asked for again while hidden, it keeps what it was doing rather than starting over.
        controller.model.setChecked(.fileViewer, false)
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.stepForTesting, "viewer")
        XCTAssertFalse(controller.model.isChecked(.fileViewer))
        app.unhide(nil)
        controller.close()
        XCTAssertFalse(controller.isShown)
    }

    /// Review finding onb-10: the file viewer row is read again when the window is asked for and when Helm comes back
    /// to the front, so a change made elsewhere shows.
    func testTheFileViewerRowIsReadAgain() async throws {
        let role = MemoryFileViewerRole()
        role.makeHelmDefault { _ in }
        _ = role.setFirstInDock(true)
        let controller = controller(MemoryPrivacyAccess(status: .granted), role: role)
        defer { controller.close() }
        controller.show(.setup, activate: false)
        XCTAssertTrue(controller.pressForTesting("Continue"))
        XCTAssertTrue(controller.pressForTesting("Continue"))
        XCTAssertEqual(controller.stepForTesting, "viewer")
        XCTAssertEqual(controller.model.state(of: .fileViewer), .done)
        // As `Helm --dock-first off` or dragging the tile would: the switch changes, the window isn't told.
        _ = role.setFirstInDock(false)
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.model.state(of: .fileViewer), .pending)
        XCTAssertTrue(controller.model.hasCheckbox(.fileViewer))
        _ = role.setFirstInDock(true)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(controller.model.state(of: .fileViewer), .done)
    }

    func testItWatchesForAccessOnlyWhileItWaits() async {
        let privacy = MemoryPrivacyAccess()
        let controller = controller(privacy)
        defer { controller.close() }
        let center = controller.model.permissions
        controller.show(.setup, activate: false)
        XCTAssertTrue(controller.pressForTesting("Continue"))
        XCTAssertFalse(center.isWatching, "nothing to wait for before System Settings opens")
        XCTAssertTrue(controller.pressForTesting("Open System Settings"))
        XCTAssertTrue(center.isWatching)
        XCTAssertEqual(privacy.openedPanes, [.fullDiskAccess])
        XCTAssertTrue(controller.pressForTesting("Back"))
        XCTAssertFalse(center.isWatching, "only on its step")
        XCTAssertTrue(controller.pressForTesting("Continue"))
        XCTAssertTrue(center.isWatching)
        controller.close()
        XCTAssertFalse(center.isWatching)
    }

    func testTheWindowFloatsOnlyOverSystemSettingsWhileItWaits() {
        let settings = OnboardingWindowController.systemSettings
        XCTAssertEqual(settings, "com.apple.systempreferences")
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: false, frontmost: settings), .floating)
        // Anywhere else it's an ordinary window, which other apps cover as usual.
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: false, frontmost: "com.apple.Safari"), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: false, frontmost: nil), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: true, frontmost: settings), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: false, interactive: true, hasAccess: false, frontmost: settings), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: false, hasAccess: false, frontmost: settings), .normal)
    }

    /// The AI mode screen on its own is the window's third mode: no step, nothing counted as seen, and closing it is a
    /// way out that turns AI mode off. Asked for while the onboarding is open, it's the onboarding's AI step instead.
    func testTheAIModeScreenIsTheWindowsThirdModeAndTheOnboardingsAIStep() async throws {
        let controller = controller()
        defer { controller.close() }
        let (ai, settings) = aiModel()
        var seen = 0, done: [Bool] = [], closed: [OnboardingModel.Mode] = []
        controller.onSeen = { seen += 1 }
        controller.onClosed = { closed.append($0) }
        controller.show(.setup, activate: false)
        controller.showAIMode(ai, activate: false) { done.append($0) }
        XCTAssertEqual(controller.modeForTesting, "setup", "the onboarding stays")
        XCTAssertEqual(controller.stepForTesting, "ai")
        XCTAssertEqual(controller.model.steps, [.welcome, .access, .viewer, .ai, .done], "the AI step comes before done")
        XCTAssertTrue(controller.model.aiSetup === ai)
        XCTAssertNil(controller.window?.appearance)
        XCTAssertEqual(seen, 0)
        controller.close()
        XCTAssertEqual(seen, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(closed, [.setup])
        // On its own.
        controller.showAIMode(ai, activate: false) { done.append($0) }
        XCTAssertEqual(controller.modeForTesting, "ai")
        XCTAssertEqual(controller.model.rows, [])
        XCTAssertNil(controller.model.headerLine)
        XCTAssertFalse(controller.isSetupShown)
        XCTAssertFalse(controller.pressForTesting("Not Now"), "the onboarding's buttons aren't there")
        XCTAssertTrue(controller.pressForTesting(AgentText.aiTitle), "the title row is the switch")
        XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled))
        controller.close()
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(done, [], "only Done reports how it ended")
        XCTAssertFalse(settings.snapshot.bool(.aiModeEnabled), "closing it turns AI mode off")
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
        XCTAssertNil(ai.donePressed)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(closed, [.setup, .ai])
        // Done with the switch off closes it and reports it ended unconnected.
        controller.showAIMode(ai, activate: false) { done.append($0) }
        XCTAssertTrue(controller.pressForTesting(AgentText.done))
        await controller.aiDoneWork?.value
        XCTAssertEqual(controller.modeForTesting, "closed")
        XCTAssertEqual(done, [false])
    }
}

private final class OnboardingAIMemory: KeyValueStoring {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func register(defaults: [String: Any]) { values.merge(defaults) { old, _ in old } }
}
#endif
