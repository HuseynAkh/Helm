#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence
import HelmUI

/// Full Disk Access across the app: the shared permission, the welcome window and its guide, and trying blocked
/// places again when Helm comes back to the front. A fixture run uses stand-ins for the permission and for moving Helm
/// into Applications, never opens the welcome by itself, and never opens System Settings, copies Helm or relaunches.
/// The same window shows the AI mode screen, which a fixture run never opens by itself either.
///
/// Setup comes before anything macOS guards. While setup is owed, a launch shows the welcome checklist and holds every
/// window back until it closes (`setUpBeforeWindows`), so macOS asks about no folder before the person has seen
/// it. Setup is owed until it has been seen once, and again whenever another build runs: macOS treats a new build of
/// an ad hoc signed app as a new app and forgets its folder access and Full Disk Access.
@MainActor final class AccessCoordinator {
    /// Where launch stands with setup: not looked at yet, waiting for the checklist to close, or through.
    enum LaunchGate { case unchecked, waiting, open }

    let privacy: any PrivacyAccessProviding
    let permissions: PermissionCenter
    let mover: any AppMoving
    private let isIsolated: Bool
    /// False for scripted runs and tests, which stay in the background: the welcome window is then invisible and never
    /// brings Helm forward. Set before the window is first made.
    var isInteractive: Bool
    private var settings: SettingsStore?
    private var fileViewer: () -> FileViewerModel? = { nil }
    private var windows: () -> [BrowserWindowController] = { [] }
    /// The browser window in front, if any. Done opens the panel there when no window's spark asked.
    private var frontWindow: () -> BrowserWindowController? = { nil }
    private(set) var onboarding: OnboardingWindowController?
    private var activation: NSObjectProtocol?
    private var termination: NSObjectProtocol?
    /// Asked for from the Help menu before launch finished; shown once it has.
    private var pendingRequest: OnboardingModel.Mode?
    /// What a fixture run's welcome window takes VoiceOver to be doing. A scripted run never asks the real Mac.
    var voiceOverForTesting = false
    /// What Settings › AI and the AI mode screen show, made the first time either is needed.
    var aiSetup: AISetupModel?
    /// What Done does once AI mode ended connected: for the window whose spark opened the AI mode screen, or else for
    /// the window in front.
    var openAgentPanel: (BrowserWindowController) -> Void = { $0.openAgentPanel() }
    /// Lets a test's background run open the AI mode screen by itself at launch, as a person's launch would.
    var opensAIIntroForTesting = false
    /// The first launch's checklist is open: the AI mode screen waits for it to close.
    private var aiIntroAfterWelcome: AISetupModel?
    /// Where launch stands with setup.
    private(set) var launchGate: LaunchGate = .unchecked
    /// Everything waiting for the checklist to close before it opens a window.
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Lets a test's background run hold its windows back for setup, as a person's launch does.
    var gatesLaunchForTesting = false

    init(isolated: Bool, interactive: Bool) {
        isIsolated = isolated
        isInteractive = interactive
        privacy = isolated ? MemoryPrivacyAccess() : SystemPrivacyAccess()
        mover = isolated ? MemoryAppMover() : SystemAppMover()
        permissions = PermissionCenter(provider: privacy)
        permissions.presentGuide = { [weak self] pane in self?.showGuide(pane) }
        // Quit & Reopen ends Helm with the welcome still open; it mustn't open again on the next launch.
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitting() }
        }
    }

    /// Helm is quitting: an open welcome counts as seen.
    func quitting() { onboarding?.quitting() }

    /// Checks access before the first window draws, then again whenever Helm comes back to the front, which
    /// is when an answered macOS question or a new permission shows up.
    func start(settings: SettingsStore, fileViewer: @escaping () -> FileViewerModel?, windows: @escaping () -> [BrowserWindowController],
               front: (() -> BrowserWindowController?)? = nil) async {
        self.settings = settings; self.fileViewer = fileViewer; self.windows = windows
        frontWindow = front ?? { windows().first }
        await permissions.refresh()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        if let request = pendingRequest { pendingRequest = nil; present(request) }
    }

    private func becameActive() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.permissions.refresh()
            for window in self.windows() { window.retryBlockedLoads() }
        }
    }

    // MARK: Setup before any window

    /// Whether this run holds its windows back for setup: one a person sees, or a test that asks. A fixture or
    /// scripted run opens its windows at once, and shows the welcome only when a step asks.
    var launchWaitsForSetup: Bool { (!isIsolated && isInteractive) || gatesLaunchForTesting }

    /// Whether setup is owed: it has never been seen, or another build saw it last.
    var setupOwed: Bool {
        guard let settings else { return false }
        let snapshot = settings.snapshot
        if !snapshot.bool(.onboardingCompleted) { return true }
        guard let build = privacy.buildIdentity else { return false }
        return snapshot.string(.setupBuild) != build
    }

    /// Whether a window asked for now must wait for the checklist that is on show.
    var windowsWaitForSetup: Bool { launchGate == .waiting }
    /// Whether a window may open straight away: setup is through for this run, or this run doesn't wait for it.
    var windowsMayOpen: Bool { launchGate == .open || (launchGate == .unchecked && !launchWaitsForSetup) }

    /// Every way to a window comes here first. When setup is owed, the welcome checklist opens, or carries on for a
    /// copy that was just moved into Applications, and this returns once it has closed; until then nothing reads a
    /// folder macOS guards. When nothing is owed, every row is done, or this run doesn't wait, it returns at once.
    /// Later calls return at once too, or wait for the same checklist.
    func setUpBeforeWindows(continuing rows: [SetupRow]? = nil) async {
        switch launchGate {
        case .open: return
        case .waiting:
            await withCheckedContinuation { gateWaiters.append($0) }
            return
        case .unchecked:
            break
        }
        guard launchWaitsForSetup, settings != nil else { launchGate = .open; return }
        launchGate = .waiting
        showWelcomeIfNeeded(continuing: rows)
        guard onboarding?.isSetupShown == true else { openGate(); return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    /// The checklist has gone, or made way: the windows waiting for it open.
    private func openGate() {
        guard launchGate != .open else { return }
        launchGate = .open
        let waiting = gateWaiters
        gateWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Once, on the first launch, unless everything is set up already. A copy that was just moved into Applications
    /// opens it again to carry on: with the flag the moving copy gave it, or, opened by hand, with the rows Set Up saved.
    /// Fixture runs only show the first launch's welcome when a smoke step asks.
    func showWelcomeIfNeeded(continuing rows: [SetupRow]? = nil) {
        if let rows { continueSetup(rows); return }
        // Only the copy in Applications takes them: one still on the disk image leaves them for it.
        if let saved = carriedRows(), mover.placement == .applications { continueSetup(saved); return }
        guard launchWaitsForSetup else { return }
        openOnFirstLaunch()
    }

    /// The rows Set Up saved for the copy in Applications, if any are waiting.
    private func carriedRows() -> [SetupRow]? {
        guard let text = settings?.snapshot.string(.setupCarriedRows), !text.isEmpty else { return nil }
        return SetupRow.rows(fromFlag: text)
    }

    /// Saves the rows for the copy in Applications, or clears them with nil.
    private func saveCarried(_ rows: [SetupRow]?) {
        guard let settings else { return }
        let text = rows.map { $0.map(\.rawValue).joined(separator: ",") } ?? ""
        if settings.snapshot.string(.setupCarriedRows) != text { settings.set(.string(text), for: .setupCarriedRows) }
    }

    /// The first launch's welcome, or the first launch of another build. If every row is already done there's nothing
    /// to show, and that counts as seen.
    func openOnFirstLaunch() {
        guard settings != nil, setupOwed else { return }
        let controller = onboarding ?? makeOnboarding()
        guard !controller.isShown else { return }
        controller.model.begin(.setup)
        if controller.model.nothingToDo { markWelcomeSeen(); return }
        controller.show(.setup, activate: isInteractive)
    }

    func continueSetup(_ rows: [SetupRow]) {
        guard settings != nil else { return }
        // Handed over now, so they aren't carried on twice.
        saveCarried(nil)
        (onboarding ?? makeOnboarding()).continueSetup(rows, activate: isInteractive)
    }

    func showWelcome() { present(.setup) }

    /// Full Disk Access gets the guide. macOS already lists Helm under the other rows once it has asked, so those open directly.
    func showGuide(_ pane: PrivacyPane) {
        if pane == .fullDiskAccess { present(.guide) } else { permissions.open(pane) }
    }

    private func present(_ mode: OnboardingModel.Mode) {
        guard settings != nil else { pendingRequest = mode; return }
        (onboarding ?? makeOnboarding()).show(mode, activate: isInteractive)
    }

    private func makeOnboarding() -> OnboardingWindowController {
        let controller = OnboardingWindowController(permissions: permissions, fileViewer: fileViewer(), mover: mover)
        // A scripted run's windows stay invisible and out of the way, this one included, from before it first shows.
        if !isInteractive { SmokeBackground.hide(controller.window) }
        if isIsolated { controller.model.isVoiceOverRunning = { [weak self] in self?.voiceOverForTesting ?? false } }
        controller.onSeen = { [weak self] in self?.markWelcomeSeen() }
        controller.onCarry = { [weak self] rows in self?.saveCarried(rows) }
        controller.onClosed = { [weak self] mode in self?.onboardingClosed(mode) }
        onboarding = controller
        return controller
    }

    /// The welcome opens by itself only until it's been seen, by this build: which build saw it is kept too.
    private func markWelcomeSeen() {
        guard let settings else { return }
        if !settings.snapshot.bool(.onboardingCompleted) { settings.set(.bool(true), for: .onboardingCompleted) }
        if let build = privacy.buildIdentity, settings.snapshot.string(.setupBuild) != build {
            settings.set(.string(build), for: .setupBuild)
        }
    }

    // MARK: The AI mode screen

    /// Shows the AI mode screen in the welcome window. When it ends connected, Done opens the panel: in `window`, whose
    /// spark opened it, or else in the window in front, as after setup or at launch.
    func showAIMode(_ model: AISetupModel, from window: BrowserWindowController?) {
        guard settings != nil else { return }
        aiIntroAfterWelcome = nil
        // The checklist makes way for the AI mode screen and counts as seen, so the windows waiting for it go ahead.
        if launchGate == .waiting { openGate() }
        let controller = onboarding ?? makeOnboarding()
        controller.showAIMode(model, activate: isInteractive) { [weak self, weak window] connected in
            guard connected, let self else { return }
            guard let target = window ?? self.frontWindow() ?? self.windows().first else { return }
            self.openAgentPanel(target)
        }
    }

    /// Once at launch, until it has been seen: straight away for someone who set Helm up before, or when the first
    /// launch's checklist closes. Never by itself in a fixture run or a scripted one.
    func showAIIntroIfNeeded(_ model: () -> AISetupModel?) {
        guard (!isIsolated && isInteractive) || opensAIIntroForTesting, let settings,
              !settings.snapshot.bool(.aiIntroSeen) else { return }
        if onboarding?.isSetupShown == true {
            aiIntroAfterWelcome = model()
            return
        }
        guard settings.snapshot.bool(.onboardingCompleted), let model = model() else { return }
        showAIMode(model, from: nil)
    }

    private func onboardingClosed(_ mode: OnboardingModel.Mode) {
        if launchGate == .waiting { openGate() }
        guard mode == .setup, let model = aiIntroAfterWelcome else { return }
        aiIntroAfterWelcome = nil
        guard let settings, !settings.snapshot.bool(.aiIntroSeen) else { return }
        showAIMode(model, from: nil)
    }

    /// Settings › General › Access.
    var settingsSection: AccessSettings {
        AccessSettings(permissions: permissions, setUp: { [weak self] in self?.showGuide(.fullDiskAccess) },
                       showWelcome: { [weak self] in self?.showWelcome() })
    }
}
#endif
